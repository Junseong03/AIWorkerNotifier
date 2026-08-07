[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$scriptDirectory = $PSScriptRoot
$applicationRoot = Split-Path -Parent $scriptDirectory
$baseMenuPath = Join-Path $scriptDirectory 'manage-setup.ps1'
$chatGptBridgePath = Join-Path $applicationRoot 'integrations\chatgpt\start-chatgpt-bridge.ps1'
$chatGptUserScriptPath = Join-Path $applicationRoot 'integrations\chatgpt\chatgpt-completion-watcher.user.js'
$chatGptManagerUrl = 'http://127.0.0.1:43127/'

if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    throw '설정 스크립트 디렉터리를 확인할 수 없습니다.'
}
if (-not (Test-Path -LiteralPath $baseMenuPath -PathType Leaf)) {
    throw "기본 설정 메뉴를 찾지 못했습니다: $baseMenuPath"
}

# 기존 설정 메뉴를 원문 그대로 읽되 Invoke-Expression 환경에서는 $PSScriptRoot가
# 비어 있으므로, 원본의 ScriptDirectory 초기화 한 줄만 현재 실제 경로로 치환한다.
$source = [System.IO.File]::ReadAllText($baseMenuPath, [System.Text.Encoding]::UTF8)
$escapedScriptDirectory = $scriptDirectory.Replace("'", "''")
$source = $source.Replace(
    '$ScriptDirectory = $PSScriptRoot',
    ("`$ScriptDirectory = '{0}'" -f $escapedScriptDirectory)
)

$marker = 'function Show-Menu {'
if (-not $source.Contains($marker)) {
    throw '설정 메뉴 확장 지점을 찾지 못했습니다. manage-setup.ps1 구조가 변경되었는지 확인하세요.'
}

$extensionFunctions = @'
function Get-ChatGptBridgeProcesses {
    $processes = [System.Collections.Generic.List[object]]::new()
    $candidates = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
            $_.CommandLine -match 'start-chatgpt-bridge\.ps1'
        }

    foreach ($candidate in @($candidates)) {
        if ($null -ne $candidate) { $processes.Add($candidate) }
    }
    return , $processes
}

function Test-ChatGptBridgeRunning {
    return (Get-ChatGptBridgeProcesses).Count -gt 0
}

function Get-ChatGptBridgeStatusLabel {
    if (Test-ChatGptBridgeRunning) { return 'ON' }
    return 'OFF'
}

function Start-ChatGptBridge {
    if (-not (Test-Path -LiteralPath $script:ChatGptBridgePath -PathType Leaf)) {
        throw "ChatGPT bridge를 찾지 못했습니다: $script:ChatGptBridgePath"
    }
    if (Test-ChatGptBridgeRunning) {
        Write-Host
        Write-Host '[INFO] ChatGPT 감시 bridge가 이미 실행 중입니다.'
        return
    }

    Start-Process `
        -FilePath 'powershell.exe' `
        -WorkingDirectory (Split-Path -Parent $script:ChatGptBridgePath) `
        -WindowStyle Hidden `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $script:ChatGptBridgePath
        ) |
        Out-Null

    Start-Sleep -Milliseconds 900
    if (-not (Test-ChatGptBridgeRunning)) {
        throw 'ChatGPT 감시 bridge를 시작하지 못했습니다.'
    }

    Write-Host
    Write-Host '[OK] ChatGPT 감시 bridge를 켰습니다.'
}

function Stop-ChatGptBridge {
    $processes = Get-ChatGptBridgeProcesses
    if ($processes.Count -eq 0) {
        Write-Host
        Write-Host '[INFO] ChatGPT 감시 bridge가 이미 꺼져 있습니다.'
        return
    }

    foreach ($process in $processes) {
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500

    if (Test-ChatGptBridgeRunning) {
        throw 'ChatGPT 감시 bridge를 종료하지 못했습니다.'
    }

    Write-Host
    Write-Host '[OK] ChatGPT 감시 bridge를 껐습니다.'
}

function Show-ChatGptWatchMenu {
    while ($true) {
        Clear-Host
        Write-Host '============================================================'
        Write-Host '                   ChatGPT 감시'
        Write-Host '============================================================'
        Write-Host
        Write-Host ("상태: {0}" -f (Get-ChatGptBridgeStatusLabel))
        Write-Host
        Write-Host '  1. 감시 bridge 시작'
        Write-Host '  2. 감시 bridge 종료'
        Write-Host '  3. ChatGPT 탭 관리 화면 열기'
        Write-Host '  4. Tampermonkey userscript 위치 열기'
        Write-Host '  5. 상태 확인'
        Write-Host '  0. 뒤로'
        Write-Host

        try {
            switch (Read-Host '번호를 고르세요') {
                '1' { Start-ChatGptBridge; Pause-Setup }
                '2' { Stop-ChatGptBridge; Pause-Setup }
                '3' {
                    if (-not (Test-ChatGptBridgeRunning)) { Start-ChatGptBridge }
                    Start-Process $script:ChatGptManagerUrl | Out-Null
                    Write-Host
                    Write-Host '[OK] ChatGPT 탭 관리 화면을 열었습니다.'
                    Pause-Setup
                }
                '4' {
                    if (-not (Test-Path -LiteralPath $script:ChatGptUserScriptPath -PathType Leaf)) {
                        throw "userscript를 찾지 못했습니다: $script:ChatGptUserScriptPath"
                    }
                    Start-Process explorer.exe -ArgumentList @('/select,', ('"{0}"' -f $script:ChatGptUserScriptPath)) | Out-Null
                    Write-Host
                    Write-Host '[INFO] userscript 파일 위치를 열었습니다.'
                    Write-Host '       Tampermonkey에 이 파일 내용을 등록하세요.'
                    Pause-Setup
                }
                '5' {
                    Write-Host
                    Write-Host ("ChatGPT 감시: {0}" -f (Get-ChatGptBridgeStatusLabel))
                    Write-Host ("관리 화면: {0}" -f $script:ChatGptManagerUrl)
                    Pause-Setup
                }
                '0' { return }
                default {
                    Write-Host
                    Write-Host '[ERROR] 0~5 사이 숫자를 입력하세요.'
                    Pause-Setup
                }
            }
        }
        catch {
            Write-Host
            Write-Host '[ERROR] ChatGPT 감시 작업에 실패했습니다.'
            Write-Host "        $($_.Exception.Message)"
            Pause-Setup
        }
    }
}

'@

$source = $source.Replace($marker, $extensionFunctions + $marker)
$source = $source.Replace(
    '$cursorHookMode = Get-CursorHookModeLabel',
    '$cursorHookMode = Get-CursorHookModeLabel' + "`r`n    `$chatGptWatchStatus = Get-ChatGptBridgeStatusLabel"
)
$source = $source.Replace(
    'Write-Host ("  Hook 모드   {0}" -f $cursorHookMode)',
    'Write-Host ("  Hook 모드   {0}" -f $cursorHookMode)' + "`r`n    Write-Host (`"  ChatGPT 감시 {0}`" -f `$chatGptWatchStatus)"
)
$source = $source.Replace(
    "Write-Host '  6. Cursor Hook'",
    "Write-Host '  6. Cursor Hook'`r`n    Write-Host '  7. ChatGPT 감시'"
)
$source = $source.Replace(
    "'6' { Show-CursorHookMenu }",
    "'6' { Show-CursorHookMenu }`r`n            '7' { Show-ChatGptWatchMenu }"
)
$source = $source.Replace(
    "'[ERROR] 0~6 사이 숫자를 입력하세요.'",
    "'[ERROR] 0~7 사이 숫자를 입력하세요.'"
)

$script:ChatGptBridgePath = $chatGptBridgePath
$script:ChatGptUserScriptPath = $chatGptUserScriptPath
$script:ChatGptManagerUrl = $chatGptManagerUrl

Invoke-Expression $source
