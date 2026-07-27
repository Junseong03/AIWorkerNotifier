[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$DryRun,
    [switch]$Backlog,
    [int]$PollIntervalSeconds = 2,
    [int]$StartupGraceMinutes = 3,
    [int]$RequestTimeoutSeconds = 8,
    [int]$MaxSendAttempts = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$script:RuntimeRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIWorkerNotifier'
$script:StartedAtUtc = [DateTime]::UtcNow
$script:LogPath = Join-Path $script:RuntimeRoot 'logs\notifier.log'
$script:SentIndexPath = Join-Path $script:RuntimeRoot 'state\sent-index.json'
$script:WebhookPath = Join-Path $script:RuntimeRoot 'state\discord-webhook.dpapi'
$script:MentionRolePath = Join-Path $script:RuntimeRoot 'state\discord-mention-role.id'
$script:PayloadHelperPath = Join-Path $PSScriptRoot 'DiscordPayload.ps1'

. $script:PayloadHelperPath

function Ensure-RuntimeDirectories {
    foreach ($dirName in @('inbox', 'processing', 'failed', 'history', 'state', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:RuntimeRoot $dirName) | Out-Null
    }
}

function Write-NotifierLog {
    param([string]$Level, [string]$Message)
    $line = "{0} [{1}] {2}" -f ([DateTime]::UtcNow.ToString('o')), $Level.ToUpperInvariant(), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Limit-Text {
    param([AllowNull()][string]$Value, [int]$MaxLength)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $clean = ($Value -replace "[\r\n\t]+", ' ').Trim()
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength) }
    return $clean
}

function Sanitize-Text {
    param([AllowNull()][string]$Value, [int]$MaxLength)
    $text = Limit-Text $Value $MaxLength
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }

    $patterns = @(
        '(?i)Authorization\s*:',
        '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+',
        '(?i)(token|secret|pepper|password|private\s+key)\s*[:=]\s*\S+',
        '(?i)https://[^\s/]+/api/webhooks/\S+',
        '(?i)[A-Za-z]:\\[^\s]+'
    )

    foreach ($pattern in $patterns) {
        $text = [regex]::Replace($text, $pattern, '[REDACTED]')
    }
    return Limit-Text $text $MaxLength
}

function Get-WebhookUrl {
    $envWebhook = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_WEBHOOK_URL', 'Process')
    if ([string]::IsNullOrWhiteSpace($envWebhook)) {
        $envWebhook = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_WEBHOOK_URL', 'User')
    }
    if (-not [string]::IsNullOrWhiteSpace($envWebhook)) { return $envWebhook.Trim() }

    if (-not (Test-Path -LiteralPath $script:WebhookPath)) {
        throw 'Discord Webhook이 설정되지 않았습니다. scripts\set-discord-webhook.ps1을 실행하세요.'
    }

    $encrypted = (Get-Content -LiteralPath $script:WebhookPath -Raw).Trim()
    $secure = ConvertTo-SecureString $encrypted
    $credential = [System.Management.Automation.PSCredential]::new('webhook', $secure)
    return $credential.GetNetworkCredential().Password
}

function Load-SentIndex {
    if (-not (Test-Path -LiteralPath $script:SentIndexPath)) { return @{} }
    try {
        $raw = [System.IO.File]::ReadAllText($script:SentIndexPath, [System.Text.UTF8Encoding]::new($false))
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $parsed = $raw | ConvertFrom-Json
        $result = @{}
        if ($null -ne $parsed) {
            foreach ($property in $parsed.PSObject.Properties) {
                $result[[string]$property.Name] = [string]$property.Value
            }
        }
        return $result
    } catch {
        Write-NotifierLog 'warning' ("sent index read failed: {0}" -f $_.Exception.Message)
    }
    return @{}
}

function Save-SentIndex {
    param([hashtable]$Index)
    $cutoff = [DateTime]::UtcNow.AddDays(-30)
    $kept = @{}
    $rows = foreach ($entry in $Index.GetEnumerator()) {
        $timestamp = [DateTime]::MinValue
        if ([DateTime]::TryParse([string]$entry.Value, [ref]$timestamp) -and $timestamp -ge $cutoff) {
            [pscustomobject]@{ Key = [string]$entry.Key; Value = $timestamp.ToString('o'); Time = $timestamp }
        }
    }
    foreach ($row in ($rows | Sort-Object Time -Descending | Select-Object -First 500)) {
        $kept[$row.Key] = $row.Value
    }
    $json = $kept | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($script:SentIndexPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Move-EventFile {
    param([string]$Path, [string]$DirectoryName, [string]$Suffix = '')
    $targetDir = Join-Path $script:RuntimeRoot $DirectoryName
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if (-not [string]::IsNullOrWhiteSpace($Suffix)) { $base = "$base-$Suffix" }
    $target = Join-Path $targetDir ("{0}.json" -f $base)
    Move-Item -LiteralPath $Path -Destination $target -Force
    return $target
}

function Validate-Event {
    param($Event)
    foreach ($required in @('schemaVersion', 'eventId', 'completionKey', 'createdAtUtc', 'project', 'task', 'workflowStatus', 'summary', 'nextAction')) {
        if ($null -eq $Event.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$Event.$required)) {
            throw "required field missing: $required"
        }
    }
    if ([int]$Event.schemaVersion -ne 1) { throw 'unsupported schemaVersion' }
}

function Get-DiscordMessage {
    param($Event)
    $outcome = ([string]$Event.outcome).ToLowerInvariant()
    $icon = switch ($outcome) {
        'needs_input' { '⚠️' }
        'blocked' { '⚠️' }
        'failure' { '❌' }
        'cancelled' { '⏹️' }
        default { '✅' }
    }

    $project = Sanitize-Text ([string]$Event.project) 120
    $task = Sanitize-Text ([string]$Event.task) 160
    $status = Sanitize-Text ([string]$Event.workflowStatus) 120
    $summary = Sanitize-Text ([string]$Event.summary) 300
    $next = Sanitize-Text ([string]$Event.nextAction) 120
    $branch = Sanitize-Text ([string]$Event.branch) 120
    $head = Sanitize-Text ([string]$Event.head) 40
    $tests = Sanitize-Text ([string]$Event.tests) 120
    $role = Sanitize-Text ([string]$Event.agentRole) 80

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$icon AI Worker 상태")
    $lines.Add('')
    $lines.Add("Project: $project")
    $lines.Add("Task: $task")
    $lines.Add("Status: $status")
    $lines.Add("Summary: $summary")
    if (-not [string]::IsNullOrWhiteSpace($branch)) { $lines.Add("Branch: $branch") }
    if (-not [string]::IsNullOrWhiteSpace($head)) { $lines.Add("HEAD: $head") }
    if (-not [string]::IsNullOrWhiteSpace($tests)) { $lines.Add("Tests: $tests") }
    if (-not [string]::IsNullOrWhiteSpace($role)) { $lines.Add("Role: $role") }
    $lines.Add("Next: $next")
    return ($lines -join "`n")
}

function Send-DiscordEvent {
    param($Event)
    $message = Get-DiscordMessage $Event
    if ($DryRun) {
        Write-NotifierLog 'info' ("dry-run event {0}: {1}" -f $Event.eventId, ($message -replace "`n", ' | '))
        return
    }

    $webhook = Get-WebhookUrl
    $roleId = Get-DiscordMentionRoleId -Path $script:MentionRolePath
    $payloadObject = New-DiscordWebhookPayloadObject -Message $message -RoleId $roleId
    $payloadBytes = [byte[]](ConvertTo-Utf8JsonBytes -PayloadObject $payloadObject)
    $lastError = $null

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    for ($attempt = 1; $attempt -le [Math]::Max(1, $MaxSendAttempts); $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Method Post `
                -Uri $webhook `
                -ContentType 'application/json; charset=utf-8' `
                -Body $payloadBytes `
                -TimeoutSec $RequestTimeoutSeconds `
                -UseBasicParsing

            $statusCode = [int]$response.StatusCode
            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                return
            }

            throw "Unexpected Discord HTTP status: $statusCode"
        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            }
            if ($statusCode -eq 204) {
                return
            }

            $lastError = $_
            if ($attempt -lt $MaxSendAttempts) { Start-Sleep -Seconds 2 }
        }
    }
    # Webhook URL이 예외 문자열에 포함될 가능성을 피하기 위해 상세 URI를 기록하지 않는다.
    throw ("Discord send failed after {0} attempt(s)." -f $MaxSendAttempts)
}

function Cleanup-Runtime {
    $history = Join-Path $script:RuntimeRoot 'history'
    $failed = Join-Path $script:RuntimeRoot 'failed'
    $logs = Join-Path $script:RuntimeRoot 'logs'

    Get-ChildItem -LiteralPath $history -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $failedCutoff = [DateTime]::UtcNow.AddHours(-24)
    Get-ChildItem -LiteralPath $failed -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTimeUtc -lt $failedCutoff |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $failed -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $logCutoff = [DateTime]::UtcNow.AddDays(-7)
    Get-ChildItem -LiteralPath $logs -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTimeUtc -lt $logCutoff |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $allFiles = Get-ChildItem -LiteralPath $script:RuntimeRoot -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc
    $maxBytes = 25MB
    $total = ($allFiles | Measure-Object Length -Sum).Sum
    foreach ($file in $allFiles) {
        if ($total -le $maxBytes) { break }
        if ($file.FullName -eq $script:WebhookPath) { continue }
        if ($file.FullName -eq $script:MentionRolePath) { continue }
        $length = $file.Length
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        $total -= $length
    }
}

function Process-OneEvent {
    param([System.IO.FileInfo]$InboxFile, [hashtable]$SentIndex)
    $processing = Move-EventFile -Path $InboxFile.FullName -DirectoryName 'processing'
    try {
        $eventJson = [System.IO.File]::ReadAllText($processing, [System.Text.UTF8Encoding]::new($false))
        $event = $eventJson | ConvertFrom-Json
        Validate-Event $event

        $createdAt = [DateTime]::Parse([string]$event.createdAtUtc).ToUniversalTime()
        if (-not $Backlog -and $createdAt -lt $script:StartedAtUtc.AddMinutes(-1 * [Math]::Max(0, $StartupGraceMinutes))) {
            Move-EventFile -Path $processing -DirectoryName 'history' -Suffix 'stale' | Out-Null
            Write-NotifierLog 'info' ("stale event skipped: {0}" -f $event.eventId)
            return
        }

        $key = [string]$event.completionKey
        if ($SentIndex.ContainsKey($key)) {
            Move-EventFile -Path $processing -DirectoryName 'history' -Suffix 'duplicate' | Out-Null
            Write-NotifierLog 'info' ("duplicate event skipped: {0}" -f $event.eventId)
            return
        }

        Send-DiscordEvent $event
        $SentIndex[$key] = [DateTime]::UtcNow.ToString('o')
        Save-SentIndex $SentIndex
        Move-EventFile -Path $processing -DirectoryName 'history' -Suffix 'sent' | Out-Null
        Write-NotifierLog 'info' ("event sent: {0}" -f $event.eventId)
    } catch {
        try { Move-EventFile -Path $processing -DirectoryName 'failed' -Suffix 'failed' | Out-Null } catch { }
        Write-NotifierLog 'error' ("event failed: {0}" -f $_.Exception.Message)
    }
}

Ensure-RuntimeDirectories
Cleanup-Runtime
$sentIndex = Load-SentIndex
Write-NotifierLog 'info' ("notifier started; mode={0}; dryRun={1}" -f ($(if ($Backlog) { 'backlog' } else { 'live-only' })), $DryRun.IsPresent)

try {
    do {
        $files = Get-ChildItem -LiteralPath (Join-Path $script:RuntimeRoot 'inbox') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc
        foreach ($file in $files) {
            Process-OneEvent -InboxFile $file -SentIndex $sentIndex
        }
        Cleanup-Runtime
        if (-not $Once) { Start-Sleep -Seconds ([Math]::Max(1, $PollIntervalSeconds)) }
    } while (-not $Once)
} finally {
    Write-NotifierLog 'info' 'notifier stopped'
}
