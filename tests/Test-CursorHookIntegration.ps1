[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $PSScriptRoot
$failures = 0

$filesToParse = @(
    (Join-Path $root 'integrations\cursor\notify-agent-stop.ps1'),
    (Join-Path $root 'scripts\install-cursor-hook.ps1'),
    (Join-Path $root 'scripts\uninstall-cursor-hook.ps1'),
    (Join-Path $root 'scripts\set-cursor-hook-mode.ps1'),
    (Join-Path $root 'scripts\manage-setup.ps1')
)

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if ($Condition) {
        Write-Host ("PASS {0}" -f $Label)
    }
    else {
        Write-Host ("FAIL {0}" -f $Label)
        $script:failures++
    }
}

function New-TempRoot {
    $path = Join-Path $env:TEMP ('aiwn-cursor-hook-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Invoke-HookAdapter {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$ResultPath,
        [string]$ArgsPath,
        [string]$CommandPath,
        [string]$AiTaskCompletePath,
        [switch]$DryRun
    )
    $scriptPath = Join-Path $root 'integrations\cursor\notify-agent-stop.ps1'
    $tmpIn = Join-Path $StateRoot ('stdin-{0}.json' -f [Guid]::NewGuid().ToString('N'))
    $tmpOut = Join-Path $StateRoot ('stdout-{0}.txt' -f [Guid]::NewGuid().ToString('N'))
    $tmpErr = Join-Path $StateRoot ('stderr-{0}.txt' -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmpIn, $Json, $utf8)

    $argParts = New-Object System.Collections.Generic.List[string]
    [void]$argParts.Add('-NoProfile')
    [void]$argParts.Add('-ExecutionPolicy')
    [void]$argParts.Add('Bypass')
    [void]$argParts.Add('-File')
    [void]$argParts.Add(('"{0}"' -f $scriptPath))
    [void]$argParts.Add('-RepoRoot')
    [void]$argParts.Add(('"{0}"' -f $root))
    [void]$argParts.Add('-StateRoot')
    [void]$argParts.Add(('"{0}"' -f $StateRoot))
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [void]$argParts.Add('-ResultPath')
        [void]$argParts.Add(('"{0}"' -f $ResultPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($ArgsPath)) {
        [void]$argParts.Add('-ArgsPath')
        [void]$argParts.Add(('"{0}"' -f $ArgsPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($CommandPath)) {
        [void]$argParts.Add('-CommandPath')
        [void]$argParts.Add(('"{0}"' -f $CommandPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($AiTaskCompletePath)) {
        [void]$argParts.Add('-AiTaskCompletePath')
        [void]$argParts.Add(('"{0}"' -f $AiTaskCompletePath))
    }
    if ($DryRun) { [void]$argParts.Add('-DryRun') }

    $cmdLine = 'type "{0}" | powershell.exe {1} > "{2}" 2> "{3}"' -f `
        $tmpIn, ($argParts -join ' '), $tmpOut, $tmpErr
    cmd.exe /c $cmdLine | Out-Null
    $exitCode = $LASTEXITCODE
    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $tmpOut) {
        $stdout = Get-Content -Raw -Encoding utf8 -LiteralPath $tmpOut
    }
    if (Test-Path -LiteralPath $tmpErr) {
        $stderr = Get-Content -Raw -Encoding utf8 -LiteralPath $tmpErr
    }
    if ($null -eq $stdout) { $stdout = '' }
    if ($null -eq $stderr) { $stderr = '' }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        StdOut = [string]$stdout
        StdErr = [string]$stderr
    }
}

function Invoke-CursorHookCmd {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [Parameter(Mandatory = $true)][string]$ErrPath,
        [System.Text.Encoding]$Encoding = $null,
        [string[]]$HookArgs = @()
    )
    if ($null -eq $Encoding) {
        $Encoding = $utf8
    }
    $tmpIn = Join-Path $WorkDir ('entrypoint-stdin-{0}.json' -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmpIn, $Json, $Encoding)
    return Invoke-CursorHookCmdFromFile `
        -InputPath $tmpIn -OutPath $OutPath -ErrPath $ErrPath -HookArgs $HookArgs
}

function Invoke-CursorHookCmdFromFile {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [Parameter(Mandatory = $true)][string]$ErrPath,
        [string[]]$HookArgs = @()
    )
    $hookCmd = Join-Path $root 'bin\AIWorkerNotifier-CursorHook.cmd'
    $extra = ''
    if ($HookArgs -and $HookArgs.Count -gt 0) {
        $extra = ' ' + ($HookArgs -join ' ')
    }
    $cmdLine = 'type "{0}" | "{1}"{2} > "{3}" 2> "{4}"' -f `
        $InputPath, $hookCmd, $extra, $OutPath, $ErrPath
    cmd.exe /c $cmdLine | Out-Null
    return [int]$LASTEXITCODE
}

function Wait-NewSentHistory {
    param(
        [Parameter(Mandatory = $true)][string]$HistoryDir,
        [Parameter(Mandatory = $true)][object[]]$BeforeFiles,
        [int]$TimeoutSeconds = 8
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $beforeNames = @($BeforeFiles | ForEach-Object { $_.Name })
    do {
        Start-Sleep -Milliseconds 250
        $after = @(
            Get-ChildItem -LiteralPath $HistoryDir -Filter '*-sent.json' -File -ErrorAction SilentlyContinue
        )
        $newSent = @(
            $after | Where-Object { $beforeNames -notcontains $_.Name }
        )
        if ($newSent.Count -ge 1) { return ,$newSent }
    } while ([DateTime]::UtcNow -lt $deadline)
    return ,@()
}

# Parser
foreach ($file in $filesToParse) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file, [ref]$tokens, [ref]$errors
    )
    Assert-True (-not ($errors -and $errors.Count -gt 0)) ("parser $($file.Replace($root + '\',''))")
}

# Sample hooks.json parse
$sampleHooks = @{
    version = 1
    hooks = @{
        stop = @(
            @{ command = 'C:\dev\SW\AIWorkerNotifier\bin\AIWorkerNotifier-CursorHook.cmd'; timeout = 30 }
        )
    }
} | ConvertTo-Json -Depth 8
$null = $sampleHooks | ConvertFrom-Json
Assert-True $true 'sample hooks.json parses'

$fixture = New-TempRoot
$hooksPath = Join-Path $fixture 'user\.cursor\hooks.json'
$backupDir = Join-Path $fixture 'backups'
$stateRoot = Join-Path $fixture 'state-root'
New-Item -ItemType Directory -Force -Path (Split-Path $hooksPath) | Out-Null
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

# Seed foreign hooks
$foreign = [ordered]@{
    version = 1
    hooks = [ordered]@{
        beforeSubmitPrompt = @(
            [ordered]@{ command = 'foreign-before.cmd' }
        )
        stop = @(
            [ordered]@{ command = 'foreign-stop.cmd'; timeout = 10 }
        )
    }
}
[IO.File]::WriteAllText(
    $hooksPath,
    (($foreign | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    $utf8
)

# Install
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\install-cursor-hook.ps1') `
    -RepoRoot $root -HooksPath $hooksPath -BackupDirectory $backupDir
Assert-True ($LASTEXITCODE -eq 0) 'install exit 0'
$afterInstall = Get-Content -Raw -Encoding utf8 -LiteralPath $hooksPath | ConvertFrom-Json
Assert-True (@($afterInstall.hooks.beforeSubmitPrompt).Count -eq 1) 'preserves beforeSubmitPrompt'
Assert-True (@($afterInstall.hooks.stop).Count -eq 2) 'keeps foreign stop + ours'
$oursInstall = @(
    @($afterInstall.hooks.stop) | Where-Object {
        $_.command -like '*AIWorkerNotifier-CursorHook.cmd*'
    }
)
Assert-True ($oursInstall.Count -eq 1) 'install adds our stop hook'
$backupFiles = @(
    Get-ChildItem -LiteralPath $backupDir -File -ErrorAction SilentlyContinue
)
Assert-True ($backupFiles.Count -ge 1) 'install created backup'

# Install idempotency
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\install-cursor-hook.ps1') `
    -RepoRoot $root -HooksPath $hooksPath -BackupDirectory $backupDir
$afterSecond = Get-Content -Raw -Encoding utf8 -LiteralPath $hooksPath | ConvertFrom-Json
Assert-True (@($afterSecond.hooks.stop).Count -eq 2) 'install idempotent stop count'
$oursSecond = @(
    @($afterSecond.hooks.stop) | Where-Object {
        $_.command -like '*AIWorkerNotifier-CursorHook.cmd*'
    }
)
Assert-True ($oursSecond.Count -eq 1) 'install idempotent single ours'

# Mode always/off
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\set-cursor-hook-mode.ps1') `
    -Mode always -StateRoot $stateRoot | Out-Null
$modeAlways = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\set-cursor-hook-mode.ps1') `
    -Get -StateRoot $stateRoot
Assert-True (([string]$modeAlways).Trim() -eq 'always') 'mode always'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\set-cursor-hook-mode.ps1') `
    -Mode off -StateRoot $stateRoot | Out-Null
$modeOff = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\set-cursor-hook-mode.ps1') `
    -Get -StateRoot $stateRoot
Assert-True (([string]$modeOff).Trim() -eq 'off') 'mode off'

function New-StopJson {
    param(
        [string]$Status,
        [string]$GenerationId,
        [switch]$OmitLoopCount
    )
    $obj = [ordered]@{
        conversation_id = 'conv-test'
        generation_id = $GenerationId
        hook_event_name = 'stop'
        cursor_version = '3.13.25'
        status = $Status
    }
    if (-not $OmitLoopCount) {
        $obj['loop_count'] = 0
    }
    return ($obj | ConvertTo-Json -Compress)
}

# Mapping matrix via DryRun + ArgsPath
$mapCases = @(
    @{ Status = 'completed'; ExpectStatus = 'COMPLETE'; ExpectOutcome = 'success'; ExpectSeverity = 'info' },
    @{ Status = 'aborted'; ExpectStatus = 'CANCELLED'; ExpectOutcome = 'cancelled'; ExpectSeverity = 'warning' },
    @{ Status = 'error'; ExpectStatus = 'FAIL'; ExpectOutcome = 'failure'; ExpectSeverity = 'error' },
    @{ Status = 'weird'; ExpectStatus = 'BLOCKED'; ExpectOutcome = 'blocked'; ExpectSeverity = 'warning' }
)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\set-cursor-hook-mode.ps1') `
    -Mode always -StateRoot $stateRoot | Out-Null

foreach ($case in $mapCases) {
    $gen = 'gen-map-' + $case.Status + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = Join-Path $stateRoot ("result-{0}.json" -f $gen)
    $argsPath = Join-Path $stateRoot ("args-{0}.txt" -f $gen)
    $run = Invoke-HookAdapter -Json (New-StopJson -Status $case.Status -GenerationId $gen) `
        -StateRoot $stateRoot -ResultPath $resultPath -ArgsPath $argsPath -DryRun
    Assert-True ($run.ExitCode -eq 0) ("map $($case.Status) exit 0")
    Assert-True ($run.StdOut.Trim() -eq '{}') ("map $($case.Status) stdout {}")
    Assert-True ($run.StdOut -notmatch 'followup_message') ("map $($case.Status) no followup")
    $argText = Get-Content -Raw -Encoding utf8 -LiteralPath $argsPath
    Assert-True ($argText -match [regex]::Escape('-Status ' + $case.ExpectStatus)) ("map $($case.Status) Status")
    Assert-True ($argText -match [regex]::Escape('-Outcome ' + $case.ExpectOutcome)) ("map $($case.Status) Outcome")
    Assert-True ($argText -match [regex]::Escape('-Severity ' + $case.ExpectSeverity)) ("map $($case.Status) Severity")
    Assert-True ($argText -match '-AgentRole LOCAL_COORDINATOR') ("map $($case.Status) AgentRole")
    Assert-True ($argText -match '-Source cursor-gui') ("map $($case.Status) Source")
    Assert-True ($argText -match '-Scope local_phase') ("map $($case.Status) Scope")
    Assert-True ($argText -match '-NextAction REVIEW_CURSOR_RESPONSE') ("map $($case.Status) NextAction")
    Assert-True ($argText -notmatch '(?i)webhook|token|authorization') ("map $($case.Status) no secrets")
    Assert-True ($run.StdErr -notmatch '(?i)webhook|authorization') ("map $($case.Status) stderr clean")
}

# off mode
$offGen = 'gen-off-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$offResult = Join-Path $stateRoot 'off-result.json'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\set-cursor-hook-mode.ps1') `
    -Mode off -StateRoot $stateRoot | Out-Null
$offRun = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $offGen) `
    -StateRoot $stateRoot -ResultPath $offResult -DryRun
Assert-True ($offRun.ExitCode -eq 0) 'off mode exit 0'
Assert-True ($offRun.StdErr -match 'NOTIFY_RESULT=NOTIFY_FILTERED') 'off mode filtered'
Assert-True ($offRun.StdOut.Trim() -eq '{}') 'off mode stdout {}'

# duplicate suppression
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\set-cursor-hook-mode.ps1') `
    -Mode always -StateRoot $stateRoot | Out-Null
$dupGen = 'gen-dup-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$r1 = Join-Path $stateRoot 'dup1.json'
$r2 = Join-Path $stateRoot 'dup2.json'
$d1 = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $dupGen) `
    -StateRoot $stateRoot -ResultPath $r1 -DryRun
$d2 = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $dupGen) `
    -StateRoot $stateRoot -ResultPath $r2 -DryRun
$j1 = Get-Content -Raw -Encoding utf8 -LiteralPath $r1 | ConvertFrom-Json
$j2 = Get-Content -Raw -Encoding utf8 -LiteralPath $r2 | ConvertFrom-Json
Assert-True ($j1.result -eq 'NOTIFY_SENT') 'dup first sent'
Assert-True ($j2.result -eq 'NOTIFY_SKIPPED_DUPLICATE') 'dup second skipped'
Assert-True ($d1.ExitCode -eq 0 -and $d2.ExitCode -eq 0) 'dup exits 0'

# missing notifier command still exits 0
$missGen = 'gen-miss-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$missResult = Join-Path $stateRoot 'miss.json'
$missRun = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $missGen) `
    -StateRoot $stateRoot -ResultPath $missResult `
    -AiTaskCompletePath (Join-Path $stateRoot 'does-not-exist.cmd')
$missJson = Get-Content -Raw -Encoding utf8 -LiteralPath $missResult | ConvertFrom-Json
Assert-True ($missRun.ExitCode -eq 0) 'missing command exit 0'
Assert-True ($missJson.result -eq 'NOTIFY_COMMAND_NOT_FOUND') 'missing command classified'
Assert-True ($missRun.StdOut.Trim() -eq '{}') 'missing command stdout {}'

# Real .cmd invocation via cmd.exe (fake queue success)
$fakeBin = Join-Path $stateRoot 'fake-bin'
New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
$fakeCmd = Join-Path $fakeBin 'ai-task-complete.cmd'
$fakeLog = Join-Path $fakeBin 'args-log.txt'
$fakeCmdBody = @"
@echo off
setlocal
> "$fakeLog" echo ARGS:%*
echo notification event queued: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
exit /b 0
"@
[IO.File]::WriteAllText($fakeCmd, $fakeCmdBody, $utf8)
$fakeGen = 'gen-fakecmd-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$fakeResult = Join-Path $stateRoot 'fake-cmd-result.json'
$fakeCmdLog = Join-Path $stateRoot 'fake-cmd-line.txt'
$fakeRun = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $fakeGen) `
    -StateRoot $stateRoot -ResultPath $fakeResult -CommandPath $fakeCmdLog `
    -AiTaskCompletePath $fakeCmd
$fakeJson = Get-Content -Raw -Encoding utf8 -LiteralPath $fakeResult | ConvertFrom-Json
Assert-True ($fakeRun.ExitCode -eq 0) 'fake cmd exit 0'
Assert-True ($fakeJson.result -eq 'NOTIFY_SENT') 'fake cmd NOTIFY_SENT'
Assert-True ($fakeRun.StdOut.Trim() -eq '{}') 'fake cmd stdout {}'
Assert-True ([string]::IsNullOrWhiteSpace($fakeRun.StdErr.Trim())) 'fake cmd success stderr empty'
Assert-True (Test-Path -LiteralPath $fakeLog -PathType Leaf) 'fake cmd received args'
$fakeArgText = Get-Content -Raw -Encoding utf8 -LiteralPath $fakeLog
Assert-True ($fakeArgText -match '-Source cursor-gui') 'fake cmd Source arg'
Assert-True ($fakeArgText -match '-Status COMPLETE') 'fake cmd Status arg'
$cmdLineText = Get-Content -Raw -Encoding utf8 -LiteralPath $fakeCmdLog
Assert-True ($cmdLineText -match '/d /s /c ""') 'cmd line uses classic double-quote form'
Assert-True ($cmdLineText -notmatch '\\"') 'cmd line has no C-style backslash quotes'

# Failure then retry same DispatchId (no permanent marker on failure)
$failBin = Join-Path $stateRoot 'fail-bin'
New-Item -ItemType Directory -Force -Path $failBin | Out-Null
$failCmd = Join-Path $failBin 'ai-task-complete.cmd'
[IO.File]::WriteAllText(
    $failCmd,
    "@echo off`r`necho boom`r`nexit /b 2`r`n",
    $utf8
)
$retryGen = 'gen-retry-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$failResult = Join-Path $stateRoot 'fail-result.json'
$failRun = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $retryGen) `
    -StateRoot $stateRoot -ResultPath $failResult -AiTaskCompletePath $failCmd
$failJson = Get-Content -Raw -Encoding utf8 -LiteralPath $failResult | ConvertFrom-Json
Assert-True ($failRun.ExitCode -eq 0) 'failure keeps hook exit 0'
Assert-True ($failRun.StdOut.Trim() -eq '{}') 'failure stdout {}'
Assert-True ($failJson.result -eq 'NOTIFY_CALLED_BUT_FAILED') 'failure classified'
Assert-True ($failRun.StdErr -match 'NOTIFY_RESULT=NOTIFY_CALLED_BUT_FAILED') `
    'failure writes stderr warning'
# Replace failing cmd with success and retry same generation id
[IO.File]::WriteAllText(
    $failCmd,
    "@echo off`r`necho notification event queued: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb`r`nexit /b 0`r`n",
    $utf8
)
$retryResult = Join-Path $stateRoot 'retry-result.json'
$retryRun = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $retryGen) `
    -StateRoot $stateRoot -ResultPath $retryResult -AiTaskCompletePath $failCmd
$retryJson = Get-Content -Raw -Encoding utf8 -LiteralPath $retryResult | ConvertFrom-Json
Assert-True ($retryJson.result -eq 'NOTIFY_SENT') 'retry after failure succeeds'
Assert-True ([string]::IsNullOrWhiteSpace($retryRun.StdErr.Trim())) 'retry success stderr empty'

# Live ai-task-complete.cmd through hook adapter (completed payload)
$liveGen = 'gen-live-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$liveResult = Join-Path $stateRoot 'live-result.json'
$historyDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) `
    'AIWorkerNotifier\history'
if (-not (Test-Path -LiteralPath $historyDir)) {
    New-Item -ItemType Directory -Force -Path $historyDir | Out-Null
}
$beforeHistory = @(
    Get-ChildItem -LiteralPath $historyDir -Filter '*-sent.json' -File -ErrorAction SilentlyContinue
)
$liveRun = Invoke-HookAdapter `
    -Json (New-StopJson -Status 'completed' -GenerationId $liveGen -OmitLoopCount) `
    -StateRoot $stateRoot -ResultPath $liveResult `
    -AiTaskCompletePath (Join-Path $root 'bin\ai-task-complete.cmd')
$liveJson = Get-Content -Raw -Encoding utf8 -LiteralPath $liveResult | ConvertFrom-Json
Assert-True ($liveRun.ExitCode -eq 0) 'live cmd exit 0'
Assert-True ($liveRun.StdOut.Trim() -eq '{}') 'live cmd stdout {}'
Assert-True ($liveJson.result -eq 'NOTIFY_SENT') 'live cmd NOTIFY_SENT'
Assert-True ([string]::IsNullOrWhiteSpace($liveRun.StdErr.Trim())) 'live success stderr empty'
$newSent = @(Wait-NewSentHistory -HistoryDir $historyDir -BeforeFiles $beforeHistory)
Assert-True ($newSent.Count -ge 1) 'live history created new sent json'

# Actual bin\AIWorkerNotifier-CursorHook.cmd entrypoint (no loop_count)
$entryGen = 'gen-entry-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$entryOut = Join-Path $stateRoot 'entry-out.txt'
$entryErr = Join-Path $stateRoot 'entry-err.txt'
$beforeEntryHistory = @(
    Get-ChildItem -LiteralPath $historyDir -Filter '*-sent.json' -File -ErrorAction SilentlyContinue
)
$entryExit = Invoke-CursorHookCmd `
    -Json (New-StopJson -Status 'completed' -GenerationId $entryGen -OmitLoopCount) `
    -WorkDir $stateRoot -OutPath $entryOut -ErrPath $entryErr
$entryStdout = [string](Get-Content -Raw -Encoding utf8 -LiteralPath $entryOut)
$entryStderr = ''
if (Test-Path -LiteralPath $entryErr) {
    $entryStderr = [string](Get-Content -Raw -Encoding utf8 -LiteralPath $entryErr)
}
Assert-True ($entryExit -eq 0) 'entrypoint exit 0'
Assert-True ($entryStdout.Trim() -eq '{}') 'entrypoint stdout {}'
Assert-True ([string]::IsNullOrWhiteSpace($entryStderr)) 'entrypoint success stderr empty'
$entryNewSent = @(Wait-NewSentHistory -HistoryDir $historyDir -BeforeFiles $beforeEntryHistory)
Assert-True ($entryNewSent.Count -ge 1) 'entrypoint created new sent json'
# duplicate via entrypoint
$entryOut2 = Join-Path $stateRoot 'entry-out2.txt'
$entryErr2 = Join-Path $stateRoot 'entry-err2.txt'
$entryExit2 = Invoke-CursorHookCmd `
    -Json (New-StopJson -Status 'completed' -GenerationId $entryGen -OmitLoopCount) `
    -WorkDir $stateRoot -OutPath $entryOut2 -ErrPath $entryErr2
$entryStderr2 = Get-Content -Raw -Encoding utf8 -LiteralPath $entryErr2
Assert-True ($entryExit2 -eq 0) 'entrypoint duplicate exit 0'
Assert-True ((Get-Content -Raw -Encoding utf8 -LiteralPath $entryOut2).Trim() -eq '{}') `
    'entrypoint duplicate stdout {}'
Assert-True ($entryStderr2 -match 'NOTIFY_RESULT=NOTIFY_SKIPPED_DUPLICATE') `
    'entrypoint duplicate skipped'

# Entrypoint encoding matrix via fake queue (fixture isolation)
$encBin = Join-Path $stateRoot 'enc-bin'
New-Item -ItemType Directory -Force -Path $encBin | Out-Null
$encFakeCmd = Join-Path $encBin 'ai-task-complete.cmd'
$encFakeLog = Join-Path $encBin 'args-log.txt'
$encFakeBody = @"
@echo off
setlocal
>> "$encFakeLog" echo ARGS:%*
echo notification event queued: cccccccc-cccc-cccc-cccc-cccccccccccc
exit /b 0
"@
[IO.File]::WriteAllText($encFakeCmd, $encFakeBody, $utf8)
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$utf16Le = [System.Text.UnicodeEncoding]::new($false, $true)

function New-CursorLikeStopJson {
    param([string]$GenerationId, [switch]$OmitLoopCount)
    $obj = [ordered]@{
        conversation_id = 'conv-cursor-like'
        generation_id = $GenerationId
        model = 'composer'
        status = 'completed'
        hook_event_name = 'stop'
        cursor_version = '3.13.25'
        workspace_roots = @('C:\dev\SW\AIWorkerNotifier')
        transcript_path = 'C:\Users\fixture\AppData\Roaming\Cursor\User\globalStorage\transcripts\fake.jsonl'
    }
    if (-not $OmitLoopCount) {
        $obj['loop_count'] = 1
    }
    return ($obj | ConvertTo-Json -Compress)
}

function Invoke-EntrypointEncodingCase {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$GenerationId,
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding,
        [switch]$ExpectEmptyStdin
    )
    $outPath = Join-Path $stateRoot ("enc-{0}-out.txt" -f $Label)
    $errPath = Join-Path $stateRoot ("enc-{0}-err.txt" -f $Label)
    $resultPath = Join-Path $stateRoot ("enc-{0}-result.json" -f $Label)
    if (Test-Path -LiteralPath $encFakeLog) {
        Remove-Item -LiteralPath $encFakeLog -Force
    }
    $hookArgs = @(
        '-RepoRoot', ('"{0}"' -f $root),
        '-StateRoot', ('"{0}"' -f $stateRoot),
        '-AiTaskCompletePath', ('"{0}"' -f $encFakeCmd),
        '-ResultPath', ('"{0}"' -f $resultPath)
    )
    if ($ExpectEmptyStdin) {
        $emptyPath = Join-Path $stateRoot ("enc-{0}-empty.txt" -f $Label)
        [IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
        $exitCode = Invoke-CursorHookCmdFromFile `
            -InputPath $emptyPath -OutPath $outPath -ErrPath $errPath -HookArgs $hookArgs
    }
    else {
        $exitCode = Invoke-CursorHookCmd `
            -Json $Json -WorkDir $stateRoot -OutPath $outPath -ErrPath $errPath `
            -Encoding $Encoding -HookArgs $hookArgs
    }
    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $outPath) {
        $rawOut = Get-Content -Raw -Encoding utf8 -LiteralPath $outPath -ErrorAction SilentlyContinue
        if ($null -ne $rawOut) { $stdout = [string]$rawOut }
    }
    if (Test-Path -LiteralPath $errPath) {
        $rawErr = Get-Content -Raw -Encoding utf8 -LiteralPath $errPath -ErrorAction SilentlyContinue
        if ($null -ne $rawErr) { $stderr = [string]$rawErr }
    }
    return [pscustomobject]@{
        Label = $Label
        ExitCode = [int]$exitCode
        StdOut = [string]$stdout
        StdErr = [string]$stderr
        ResultPath = $resultPath
        FakeLog = $encFakeLog
    }
}

$encCases = @(
    @{
        Label = 'utf8-nobom'
        Gen = 'enc-utf8-nobom-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Encoding = $utf8
        JsonBuilder = { param($g) New-StopJson -Status 'completed' -GenerationId $g }
        ExpectSent = $true
    },
    @{
        Label = 'utf8-bom'
        Gen = 'enc-utf8-bom-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Encoding = $utf8Bom
        JsonBuilder = { param($g) New-StopJson -Status 'completed' -GenerationId $g }
        ExpectSent = $true
    },
    @{
        Label = 'utf16le-bom'
        Gen = 'enc-utf16le-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Encoding = $utf16Le
        JsonBuilder = { param($g) New-StopJson -Status 'completed' -GenerationId $g }
        ExpectSent = $true
    },
    @{
        Label = 'loop-present'
        Gen = 'enc-loop-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Encoding = $utf8Bom
        JsonBuilder = { param($g) New-StopJson -Status 'completed' -GenerationId $g }
        ExpectSent = $true
    },
    @{
        Label = 'loop-absent'
        Gen = 'enc-noloop-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Encoding = $utf8Bom
        JsonBuilder = { param($g) New-StopJson -Status 'completed' -GenerationId $g -OmitLoopCount }
        ExpectSent = $true
    },
    @{
        Label = 'cursor-like'
        Gen = 'enc-cursorlike-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Encoding = $utf8Bom
        JsonBuilder = { param($g) New-CursorLikeStopJson -GenerationId $g }
        ExpectSent = $true
    }
)

foreach ($enc in $encCases) {
    $json = & $enc.JsonBuilder $enc.Gen
    $run = Invoke-EntrypointEncodingCase `
        -Label $enc.Label -GenerationId $enc.Gen -Json $json -Encoding $enc.Encoding
    Assert-True ($run.ExitCode -eq 0) ("enc $($enc.Label) exit 0")
    Assert-True (([string]$run.StdOut).Trim() -eq '{}') ("enc $($enc.Label) stdout {}")
    if ($enc.ExpectSent) {
        Assert-True ([string]::IsNullOrWhiteSpace(([string]$run.StdErr).Trim())) `
            ("enc $($enc.Label) success stderr empty")
        Assert-True (Test-Path -LiteralPath $run.ResultPath -PathType Leaf) `
            ("enc $($enc.Label) result file")
        if (Test-Path -LiteralPath $run.ResultPath -PathType Leaf) {
            $encJson = Get-Content -Raw -Encoding utf8 -LiteralPath $run.ResultPath | ConvertFrom-Json
            Assert-True ($encJson.result -eq 'NOTIFY_SENT') ("enc $($enc.Label) NOTIFY_SENT")
        }
        Assert-True (Test-Path -LiteralPath $run.FakeLog -PathType Leaf) `
            ("enc $($enc.Label) fake queue args")
        if (Test-Path -LiteralPath $run.FakeLog -PathType Leaf) {
            $encArgs = Get-Content -Raw -Encoding utf8 -LiteralPath $run.FakeLog
            Assert-True ($encArgs -match '-Source cursor-gui') ("enc $($enc.Label) Source arg")
            Assert-True ($encArgs -match [regex]::Escape($enc.Gen)) ("enc $($enc.Label) DispatchId arg")
        }
    }
}

# Empty stdin through entrypoint
$emptyRun = Invoke-EntrypointEncodingCase `
    -Label 'empty' -GenerationId 'enc-empty' -Json '{}' -Encoding $utf8 -ExpectEmptyStdin
Assert-True ($emptyRun.ExitCode -eq 0) 'enc empty exit 0'
Assert-True ($emptyRun.StdOut.Trim() -eq '{}') 'enc empty stdout {}'
Assert-True (Test-Path -LiteralPath $emptyRun.ResultPath -PathType Leaf) 'enc empty result file'
$emptyJson = Get-Content -Raw -Encoding utf8 -LiteralPath $emptyRun.ResultPath | ConvertFrom-Json
Assert-True ($emptyJson.result -eq 'NOTIFY_FILTERED') 'enc empty filtered'
Assert-True ($emptyRun.StdErr -match 'NOTIFY_RESULT=NOTIFY_FILTERED') 'enc empty stderr filtered'

# Entrypoint UTF-8 BOM live queue + independent history artifact
$bomLiveGen = 'enc-bom-live-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$bomLiveOut = Join-Path $stateRoot 'bom-live-out.txt'
$bomLiveErr = Join-Path $stateRoot 'bom-live-err.txt'
$bomLiveResult = Join-Path $stateRoot 'bom-live-result.json'
$beforeBomHistory = @(
    Get-ChildItem -LiteralPath $historyDir -Filter '*-sent.json' -File -ErrorAction SilentlyContinue
)
$bomLiveExit = Invoke-CursorHookCmd `
    -Json (New-StopJson -Status 'completed' -GenerationId $bomLiveGen) `
    -WorkDir $stateRoot -OutPath $bomLiveOut -ErrPath $bomLiveErr `
    -Encoding $utf8Bom `
    -HookArgs @(
        '-RepoRoot', ('"{0}"' -f $root),
        '-StateRoot', ('"{0}"' -f $stateRoot),
        '-ResultPath', ('"{0}"' -f $bomLiveResult)
    )
$bomLiveStdout = [string](Get-Content -Raw -Encoding utf8 -LiteralPath $bomLiveOut)
$bomLiveStderr = ''
if (Test-Path -LiteralPath $bomLiveErr) {
    $bomLiveStderr = [string](Get-Content -Raw -Encoding utf8 -LiteralPath $bomLiveErr)
}
Assert-True ($bomLiveExit -eq 0) 'utf8-bom live entrypoint exit 0'
Assert-True ($bomLiveStdout.Trim() -eq '{}') 'utf8-bom live entrypoint stdout {}'
Assert-True ([string]::IsNullOrWhiteSpace($bomLiveStderr)) 'utf8-bom live entrypoint stderr empty'
Assert-True (Test-Path -LiteralPath $bomLiveResult -PathType Leaf) 'utf8-bom live result file'
$bomLiveJson = Get-Content -Raw -Encoding utf8 -LiteralPath $bomLiveResult | ConvertFrom-Json
Assert-True ($bomLiveJson.result -eq 'NOTIFY_SENT') 'utf8-bom live NOTIFY_SENT'
$bomLiveNewSent = @(Wait-NewSentHistory -HistoryDir $historyDir -BeforeFiles $beforeBomHistory)
Assert-True ($bomLiveNewSent.Count -ge 1) 'utf8-bom live created new sent json'
$bomLiveMatched = @(
    $bomLiveNewSent | Where-Object {
        $content = Get-Content -Raw -Encoding utf8 -LiteralPath $_.FullName
        $content -match [regex]::Escape($bomLiveGen)
    }
)
Assert-True ($bomLiveMatched.Count -ge 1) 'utf8-bom live sent.json contains generation_id'

# Uninstall preserves foreign hooks
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\uninstall-cursor-hook.ps1') `
    -HooksPath $hooksPath
$afterUninstall = Get-Content -Raw -Encoding utf8 -LiteralPath $hooksPath | ConvertFrom-Json
Assert-True (@($afterUninstall.hooks.beforeSubmitPrompt).Count -eq 1) 'uninstall keeps beforeSubmitPrompt'
Assert-True (@($afterUninstall.hooks.stop).Count -eq 1) 'uninstall keeps foreign stop'
Assert-True (([string]@($afterUninstall.hooks.stop)[0].command) -eq 'foreign-stop.cmd') `
    'uninstall keeps only foreign stop'
$oursRemaining = 0
foreach ($stopItem in @($afterUninstall.hooks.stop)) {
    if ([string]$stopItem.command -like '*AIWorkerNotifier-CursorHook.cmd*') {
        $oursRemaining++
    }
}
Assert-True ($oursRemaining -eq 0) 'uninstall removes ours'

# Uninstall idempotent
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\uninstall-cursor-hook.ps1') `
    -HooksPath $hooksPath
Assert-True ($LASTEXITCODE -eq 0) 'uninstall idempotent'

# No temp leftovers under fixture hooks dir
$tmpLeft = @(
    Get-ChildItem -LiteralPath (Split-Path $hooksPath) -Filter 'hooks.json.*.tmp' -ErrorAction SilentlyContinue
)
Assert-True ($tmpLeft.Count -eq 0) 'no temp hooks.json leftovers'

# Cleanup fixture
Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -gt 0) {
    Write-Host ("FAILED checks: {0}" -f $failures)
    exit 1
}
Write-Host 'HARNESS_VERIFIED cursor hook integration'
exit 0
