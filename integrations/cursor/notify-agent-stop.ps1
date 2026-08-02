[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$StateRoot,
    [string]$AiTaskCompletePath,
    [string]$ResultPath,
    [string]$ArgsPath,
    [string]$CommandPath,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Write-EmptyHookResponse {
    [Console]::Out.Write('{}')
    [Console]::Out.Flush()
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Write-NotifyResultRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Detail = '',
        [switch]$WriteStderr
    )
    if ($WriteStderr) {
        [Console]::Error.WriteLine(('NOTIFY_RESULT={0}' -f $Result))
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $dir = Split-Path -Parent $ResultPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $payload = [ordered]@{
            result = $Result
            detail = $Detail
        }
        [IO.File]::WriteAllText(
            $ResultPath,
            (($payload | ConvertTo-Json -Compress) + [Environment]::NewLine),
            $utf8
        )
    }
}

function Read-StdinUtf8 {
    # Detect BOM so UTF-8/UTF-16 temp files from Cursor are decoded correctly.
    # Also strip a leading U+FEFF defensively if a decoder left it in the text.
    $stdin = [Console]::OpenStandardInput()
    $reader = New-Object System.IO.StreamReader(
        $stdin,
        $utf8,
        $true,
        1024,
        $true
    )
    try {
        $text = $reader.ReadToEnd()
        if (-not [string]::IsNullOrEmpty($text) -and [int][char]$text[0] -eq 0xFEFF) {
            $text = $text.Substring(1)
        }
        return $text
    }
    finally {
        $reader.Dispose()
    }
}

function Limit-NotifyText {
    param([AllowNull()][string]$Text, [int]$MaxLength)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength)
}

function Get-IntegrationSettingsPath {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Join-Path $Root 'state\integration-settings.json')
}

function Get-CursorHookNotifyMode {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Get-IntegrationSettingsPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return 'always'
    }
    try {
        $json = Get-Content -Raw -Encoding utf8 -LiteralPath $path | ConvertFrom-Json
        $mode = [string](Get-JsonPropertyValue -Object $json -Name 'cursorHookNotifyMode')
        if ([string]::IsNullOrWhiteSpace($mode)) { return 'always' }
        return $mode.Trim().ToLowerInvariant()
    }
    catch {
        return 'always'
    }
}

function Get-DedupeMarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DispatchId
    )
    $safe = ($DispatchId -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'unknown' }
    $dir = Join-Path $Root 'state\cursor-hook-dedupe'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return (Join-Path $dir ($safe + '.sent'))
}

function Test-HookEventDuplicate {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DispatchId
    )
    $marker = Get-DedupeMarkerPath -Root $Root -DispatchId $DispatchId
    return (Test-Path -LiteralPath $marker -PathType Leaf)
}

function Write-HookEventDuplicateMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DispatchId
    )
    $marker = Get-DedupeMarkerPath -Root $Root -DispatchId $DispatchId
    [IO.File]::WriteAllText(
        $marker,
        ([DateTimeOffset]::UtcNow.ToString('o') + [Environment]::NewLine),
        $utf8
    )
}

function Resolve-StopMapping {
    param([AllowNull()][string]$StopStatus)
    $normalized = if ([string]::IsNullOrWhiteSpace($StopStatus)) {
        'missing'
    }
    else {
        $StopStatus.Trim().ToLowerInvariant()
    }

    switch ($normalized) {
        'completed' {
            return [pscustomobject]@{
                Status = 'COMPLETE'
                Outcome = 'success'
                Severity = 'info'
            }
        }
        'aborted' {
            return [pscustomobject]@{
                Status = 'CANCELLED'
                Outcome = 'cancelled'
                Severity = 'warning'
            }
        }
        'error' {
            return [pscustomobject]@{
                Status = 'FAIL'
                Outcome = 'failure'
                Severity = 'error'
            }
        }
        default {
            return [pscustomobject]@{
                Status = 'BLOCKED'
                Outcome = 'blocked'
                Severity = 'warning'
            }
        }
    }
}

function ConvertTo-CmdQuotedArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"&<>|^()]') {
        return $Value
    }
    return ('"' + ($Value -replace '"', '""') + '"')
}

function Invoke-CmdBatchFile {
    param(
        [Parameter(Mandatory = $true)][string]$BatchPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$CommandLogPath
    )

    $batchFull = [IO.Path]::GetFullPath($BatchPath)
    $quotedArgs = @(
        foreach ($arg in $Arguments) {
            ConvertTo-CmdQuotedArgument -Value $arg
        }
    )
    # Classic cmd.exe contract:
    #   cmd.exe /d /s /c ""C:\path\file.cmd" arg1 "arg 2""
    # Build with real quotes. Do not use C-style \" escapes in PowerShell strings.
    $argumentString =
        '/d /s /c ""' + $batchFull + '" ' + ($quotedArgs -join ' ') + '"'

    if (-not [string]::IsNullOrWhiteSpace($CommandLogPath)) {
        $dir = Split-Path -Parent $CommandLogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $sanitized = $argumentString
        $sanitized = [regex]::Replace($sanitized, '[A-Za-z]:\\[^\s"]+', '<path>')
        [IO.File]::WriteAllText(
            $CommandLogPath,
            ($sanitized + [Environment]::NewLine),
            $utf8
        )
    }

    $comSpec = $env:ComSpec
    if ([string]::IsNullOrWhiteSpace($comSpec)) {
        $comSpec = 'cmd.exe'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $comSpec
    $psi.Arguments = $argumentString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.WorkingDirectory = (Split-Path -Parent $batchFull)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{
        ExitCode = [int]$proc.ExitCode
        StdOut = [string]$stdout
        StdErr = [string]$stderr
        ArgumentString = $argumentString
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }
    else {
        $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    }

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
        $StateRoot = Join-Path $localAppData 'AIWorkerNotifier'
    }

    foreach ($dirName in @('state', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $StateRoot $dirName) | Out-Null
    }

    $raw = Read-StdinUtf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-NotifyResultRecord -Result 'NOTIFY_FILTERED' -Detail 'empty_stdin' -WriteStderr
        Write-EmptyHookResponse
        exit 0
    }

    $payload = $raw | ConvertFrom-Json
    $eventName = [string](Get-JsonPropertyValue -Object $payload -Name 'hook_event_name')
    if (-not [string]::IsNullOrWhiteSpace($eventName) -and $eventName -ne 'stop') {
        Write-NotifyResultRecord -Result 'NOTIFY_FILTERED' -Detail 'non_stop_event' -WriteStderr
        Write-EmptyHookResponse
        exit 0
    }

    $mode = Get-CursorHookNotifyMode -Root $StateRoot
    if ($mode -eq 'off') {
        Write-NotifyResultRecord -Result 'NOTIFY_FILTERED' -Detail 'mode=off' -WriteStderr
        Write-EmptyHookResponse
        exit 0
    }

    $generationId = [string](Get-JsonPropertyValue -Object $payload -Name 'generation_id')
    $conversationId = [string](Get-JsonPropertyValue -Object $payload -Name 'conversation_id')
    $loopCount = 0
    $loopRaw = Get-JsonPropertyValue -Object $payload -Name 'loop_count'
    if ($null -ne $loopRaw -and [string]$loopRaw -ne '') {
        try { $loopCount = [int]$loopRaw } catch { $loopCount = 0 }
    }

    $dispatchId = $null
    if (-not [string]::IsNullOrWhiteSpace($generationId)) {
        $dispatchId = $generationId
    }
    elseif (-not [string]::IsNullOrWhiteSpace($conversationId)) {
        $dispatchId = '{0}-loop-{1}' -f $conversationId, $loopCount
    }
    else {
        $dispatchId = 'cursor-stop-{0:yyyyMMddHHmmss}' -f (Get-Date)
    }
    $dispatchId = Limit-NotifyText $dispatchId 120

    if (Test-HookEventDuplicate -Root $StateRoot -DispatchId $dispatchId) {
        Write-NotifyResultRecord -Result 'NOTIFY_SKIPPED_DUPLICATE' -WriteStderr
        Write-EmptyHookResponse
        exit 0
    }

    $stopStatus = [string](Get-JsonPropertyValue -Object $payload -Name 'status')
    $mapping = Resolve-StopMapping -StopStatus $stopStatus
    $statusLabel = if ([string]::IsNullOrWhiteSpace($stopStatus)) { 'unknown' } else { $stopStatus }
    $summary = Limit-NotifyText ('Cursor GUI agent stop ({0})' -f $statusLabel) 300

    $argumentList = @(
        '-Task', 'CURSOR-GUI-STOP',
        '-Status', $mapping.Status,
        '-Summary', $summary,
        '-NextAction', 'REVIEW_CURSOR_RESPONSE',
        '-AgentRole', 'LOCAL_COORDINATOR',
        '-Source', 'cursor-gui',
        '-Scope', 'local_phase',
        '-Outcome', $mapping.Outcome,
        '-Severity', $mapping.Severity,
        '-DispatchId', $dispatchId
    )

    if (-not [string]::IsNullOrWhiteSpace($ArgsPath)) {
        $argsDir = Split-Path -Parent $ArgsPath
        if ($argsDir -and -not (Test-Path -LiteralPath $argsDir)) {
            New-Item -ItemType Directory -Force -Path $argsDir | Out-Null
        }
        [IO.File]::WriteAllText(
            $ArgsPath,
            (($argumentList -join ' ') + [Environment]::NewLine),
            $utf8
        )
    }

    if ($DryRun) {
        Write-HookEventDuplicateMarker -Root $StateRoot -DispatchId $dispatchId
        Write-NotifyResultRecord -Result 'NOTIFY_SENT' -Detail 'dry_run'
        Write-EmptyHookResponse
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($AiTaskCompletePath)) {
        $AiTaskCompletePath = Join-Path $RepoRoot 'bin\ai-task-complete.cmd'
    }
    if (-not (Test-Path -LiteralPath $AiTaskCompletePath -PathType Leaf)) {
        Write-NotifyResultRecord -Result 'NOTIFY_COMMAND_NOT_FOUND' -WriteStderr
        Write-EmptyHookResponse
        exit 0
    }

    $invoke = Invoke-CmdBatchFile `
        -BatchPath $AiTaskCompletePath `
        -Arguments $argumentList `
        -CommandLogPath $CommandPath
    $exitCode = [int]$invoke.ExitCode
    $outputText = [string]$invoke.StdOut
    $stderrText = [string]$invoke.StdErr
    $combinedText = ($outputText + [Environment]::NewLine + $stderrText)
    $normalizedStderr = $stderrText -replace '\s+', ''
    $hasArgumentError = $normalizedStderr -match
        '(?i)MissingMandatoryParameter|ParameterBindingException'
    $hasQueueSuccess = $combinedText -match
        '(?i)notification\s+event\s+queued\s*:\s*[0-9a-f-]{8,}|queue\s+success'

    if ($exitCode -ne 0) {
        if ($hasArgumentError) {
            Write-NotifyResultRecord -Result 'NOTIFY_ARGUMENT_ERROR' `
                -Detail ("exit=$exitCode") -WriteStderr
        }
        else {
            Write-NotifyResultRecord -Result 'NOTIFY_CALLED_BUT_FAILED' `
                -Detail ("exit=$exitCode") -WriteStderr
        }
        Write-EmptyHookResponse
        exit 0
    }
    if ($hasQueueSuccess) {
        Write-HookEventDuplicateMarker -Root $StateRoot -DispatchId $dispatchId
        Write-NotifyResultRecord -Result 'NOTIFY_SENT'
        Write-EmptyHookResponse
        exit 0
    }

    Write-NotifyResultRecord -Result 'NOTIFY_CALLED_BUT_FAILED' `
        -Detail 'no_queue_success' -WriteStderr
    Write-EmptyHookResponse
    exit 0
}
catch {
    try {
        $exDetail = 'exception:' + $_.Exception.Message
        if ($exDetail.Length -gt 180) {
            $exDetail = $exDetail.Substring(0, 180)
        }
        $exDetail = [regex]::Replace($exDetail, '[A-Za-z]:\\[^\s;]+', '<path>')
        Write-NotifyResultRecord -Result 'NOTIFY_CALLED_BUT_FAILED' `
            -Detail $exDetail -WriteStderr
    }
    catch { }
    try {
        Write-EmptyHookResponse
    }
    catch { }
    exit 0
}
