[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$StateRoot,
    [string]$AiTaskCompletePath,
    [string]$ResultPath,
    [string]$ArgsPath,
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

function Write-NotifyResultLine {
    param(
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Detail = ''
    )
    [Console]::Error.WriteLine(('NOTIFY_RESULT={0}' -f $Result))
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
    $stdin = [Console]::OpenStandardInput()
    $reader = New-Object System.IO.StreamReader($stdin, $utf8, $false, 1024, $true)
    try {
        return $reader.ReadToEnd()
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
        $mode = [string]$json.cursorHookNotifyMode
        if ([string]::IsNullOrWhiteSpace($mode)) { return 'always' }
        return $mode.Trim().ToLowerInvariant()
    }
    catch {
        return 'always'
    }
}

function Test-HookEventDuplicate {
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
    $marker = Join-Path $dir ($safe + '.sent')
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        return $true
    }
    [IO.File]::WriteAllText(
        $marker,
        ([DateTimeOffset]::UtcNow.ToString('o') + [Environment]::NewLine),
        $utf8
    )
    return $false
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
        Write-NotifyResultLine -Result 'NOTIFY_FILTERED' -Detail 'empty_stdin'
        Write-EmptyHookResponse
        exit 0
    }

    $payload = $raw | ConvertFrom-Json
    $eventName = [string]$payload.hook_event_name
    if (-not [string]::IsNullOrWhiteSpace($eventName) -and $eventName -ne 'stop') {
        Write-NotifyResultLine -Result 'NOTIFY_FILTERED' -Detail 'non_stop_event'
        Write-EmptyHookResponse
        exit 0
    }

    $mode = Get-CursorHookNotifyMode -Root $StateRoot
    if ($mode -eq 'off') {
        Write-NotifyResultLine -Result 'NOTIFY_FILTERED' -Detail 'mode=off'
        Write-EmptyHookResponse
        exit 0
    }

    $generationId = [string]$payload.generation_id
    $conversationId = [string]$payload.conversation_id
    $loopCount = 0
    if ($null -ne $payload.loop_count) {
        try { $loopCount = [int]$payload.loop_count } catch { $loopCount = 0 }
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
        Write-NotifyResultLine -Result 'NOTIFY_SKIPPED_DUPLICATE'
        Write-EmptyHookResponse
        exit 0
    }

    $mapping = Resolve-StopMapping -StopStatus ([string]$payload.status)
    $summary = Limit-NotifyText ('Cursor GUI agent stop ({0})' -f $(
            if ([string]::IsNullOrWhiteSpace([string]$payload.status)) { 'unknown' }
            else { [string]$payload.status }
        )) 300

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
        Write-NotifyResultLine -Result 'NOTIFY_SENT' -Detail 'dry_run'
        Write-EmptyHookResponse
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($AiTaskCompletePath)) {
        $AiTaskCompletePath = Join-Path $RepoRoot 'bin\ai-task-complete.cmd'
    }
    if (-not (Test-Path -LiteralPath $AiTaskCompletePath -PathType Leaf)) {
        Write-NotifyResultLine -Result 'NOTIFY_COMMAND_NOT_FOUND'
        Write-EmptyHookResponse
        exit 0
    }

    # PowerShell call-operator (&) against .cmd is unreliable for exit codes and
    # merged 2>&1 streams under Cursor's hook host. Always launch through cmd.exe.
    function ConvertTo-CmdQuotedArgument {
        param([AllowNull()][string]$Value)
        if ($null -eq $Value) { return '""' }
        if ($Value -notmatch '[\s"&<>|^()]') {
            return $Value
        }
        return ('"{0}"' -f ($Value -replace '"', '""'))
    }

    function Invoke-CmdBatchFile {
        param(
            [Parameter(Mandatory = $true)][string]$BatchPath,
            [Parameter(Mandatory = $true)][string[]]$Arguments
        )

        $batchFull = [IO.Path]::GetFullPath($BatchPath)
        $quotedBatch = ConvertTo-CmdQuotedArgument -Value $batchFull
        $quotedArgs = @(
            foreach ($arg in $Arguments) {
                ConvertTo-CmdQuotedArgument -Value $arg
            }
        )
        # /d disables AutoRun; /s keeps the outer quote stripping contract stable.
        $argumentString = '/d /s /c "{0} {1}"' -f $quotedBatch, ($quotedArgs -join ' ')

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
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
        }
    }

    $invoke = Invoke-CmdBatchFile -BatchPath $AiTaskCompletePath -Arguments $argumentList
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
            Write-NotifyResultLine -Result 'NOTIFY_ARGUMENT_ERROR' -Detail ("exit=$exitCode")
        }
        else {
            Write-NotifyResultLine -Result 'NOTIFY_CALLED_BUT_FAILED' -Detail ("exit=$exitCode")
        }
        Write-EmptyHookResponse
        exit 0
    }
    if ($hasQueueSuccess) {
        Write-NotifyResultLine -Result 'NOTIFY_SENT'
        Write-EmptyHookResponse
        exit 0
    }

    Write-NotifyResultLine -Result 'NOTIFY_CALLED_BUT_FAILED' -Detail 'no_queue_success'
    Write-EmptyHookResponse
    exit 0
}
catch {
    try {
        Write-NotifyResultLine -Result 'NOTIFY_CALLED_BUT_FAILED' -Detail 'exception'
    }
    catch { }
    try {
        Write-EmptyHookResponse
    }
    catch { }
    exit 0
}
