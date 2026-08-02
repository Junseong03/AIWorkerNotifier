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
    param([string]$Status, [string]$GenerationId)
    return (@{
        conversation_id = 'conv-test'
        generation_id = $GenerationId
        hook_event_name = 'stop'
        cursor_version = '3.13.25'
        status = $Status
        loop_count = 0
    } | ConvertTo-Json -Compress)
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
$fakeRun = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $fakeGen) `
    -StateRoot $stateRoot -ResultPath $fakeResult -AiTaskCompletePath $fakeCmd
$fakeJson = Get-Content -Raw -Encoding utf8 -LiteralPath $fakeResult | ConvertFrom-Json
Assert-True ($fakeRun.ExitCode -eq 0) 'fake cmd exit 0'
Assert-True ($fakeJson.result -eq 'NOTIFY_SENT') 'fake cmd NOTIFY_SENT'
Assert-True ($fakeRun.StdOut.Trim() -eq '{}') 'fake cmd stdout {}'
Assert-True (Test-Path -LiteralPath $fakeLog -PathType Leaf) 'fake cmd received args'
$fakeArgText = Get-Content -Raw -Encoding utf8 -LiteralPath $fakeLog
Assert-True ($fakeArgText -match '-Source cursor-gui') 'fake cmd Source arg'
Assert-True ($fakeArgText -match '-Status COMPLETE') 'fake cmd Status arg'

# Live ai-task-complete.cmd through hook adapter (completed payload)
$liveGen = 'gen-live-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$liveResult = Join-Path $stateRoot 'live-result.json'
$historyDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) `
    'AIWorkerNotifier\history'
$beforeHistory = @(
    Get-ChildItem -LiteralPath $historyDir -Filter '*-sent.json' -File -ErrorAction SilentlyContinue
)
$liveRun = Invoke-HookAdapter -Json (New-StopJson -Status 'completed' -GenerationId $liveGen) `
    -StateRoot $stateRoot -ResultPath $liveResult `
    -AiTaskCompletePath (Join-Path $root 'bin\ai-task-complete.cmd')
$liveJson = Get-Content -Raw -Encoding utf8 -LiteralPath $liveResult | ConvertFrom-Json
Assert-True ($liveRun.ExitCode -eq 0) 'live cmd exit 0'
Assert-True ($liveRun.StdOut.Trim() -eq '{}') 'live cmd stdout {}'
Assert-True ($liveJson.result -eq 'NOTIFY_SENT') 'live cmd NOTIFY_SENT'
Start-Sleep -Milliseconds 800
$afterHistory = @(
    Get-ChildItem -LiteralPath $historyDir -Filter '*-sent.json' -File -ErrorAction SilentlyContinue
)
$newSent = @(
    $afterHistory | Where-Object {
        $beforeNames = @($beforeHistory | ForEach-Object { $_.Name })
        $beforeNames -notcontains $_.Name
    }
)
Assert-True ($newSent.Count -ge 1 -or $liveJson.result -eq 'NOTIFY_SENT') `
    'live history sent json or queue success'

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
