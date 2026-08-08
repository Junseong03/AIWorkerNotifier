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
$chatGptExtensionManifestPath = Join-Path $applicationRoot 'integrations\chatgpt\chrome-extension\manifest.json'
$chatGptManagerUrl = 'http://127.0.0.1:43127/'

if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    throw '설정 스크립트 디렉터리를 확인할 수 없습니다.'
}
if (-not (Test-Path -LiteralPath $baseMenuPath -PathType Leaf)) {
    throw "기본 설정 메뉴를 찾지 못했습니다: $baseMenuPath"
}

# Windows PowerShell 5.1 호환: 이 파일은 UTF-8 BOM으로 저장한다.
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
function Pause-Setup {
    # 메뉴 선택 후 별도의 Enter 입력을 요구하지 않는다.
    # 작업 결과를 짧게 보여준 뒤 현재 메뉴가 자동으로 다시 그려진다.
    Start-Sleep -Milliseconds 350
}

function Get-SetupStatusColor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    switch ($Value) {
        'ON' { return 'Green' }
        '연결됨' { return 'Green' }
        '설정됨' { return 'Green' }
        '등록됨' { return 'Green' }
        '설치됨' { return 'Green' }
        'always' { return 'Green' }
        'OFF' { return 'Red' }
        '오류' { return 'Red' }
        '잘못됨' { return 'Red' }
        '스크립트 없음' { return 'Red' }
        'unknown' { return 'Red' }
        '없음' {
            if ($Name -eq 'Webhook') { return 'Red' }
            return 'Yellow'
        }
        '미등록' { return 'Yellow' }
        '미설치' { return 'Yellow' }
        'off' { return 'Yellow' }
        default { return 'Cyan' }
    }
}

function Write-SetupStatusLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Prefix,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    Write-Host $Prefix -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor (Get-SetupStatusColor -Name $Name -Value $Value)
}

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

function Switch-ChatGptBridge {
    if (Test-ChatGptBridgeRunning) {
        Stop-ChatGptBridge
        return
    }

    Start-ChatGptBridge
}

function Show-ChatGptWatchMenu {
    while ($true) {
        $watchStatus = Get-ChatGptBridgeStatusLabel
        $toggleLabel = if ($watchStatus -eq 'ON') { '감시 bridge 종료' } else { '감시 bridge 시작' }

        Clear-Host
        Write-Host '============================================================'
        Write-Host '                   ChatGPT 감시'
        Write-Host '============================================================'
        Write-Host
        Write-SetupStatusLine -Name 'ChatGPT 감시' -Prefix '상태: ' -Value $watchStatus
        Write-Host
        Write-Host ("  1. {0}" -f $toggleLabel)
        Write-Host '  2. ChatGPT 탭 관리 화면 열기'
        Write-Host '  3. Chrome 확장 프로그램 위치 열기'
        Write-Host '  4. 상태 확인'
        Write-Host '  0. 뒤로'
        Write-Host

        try {
            switch (Read-Host '번호를 고르세요') {
                '1' { Switch-ChatGptBridge; Pause-Setup }
                '2' {
                    if (-not (Test-ChatGptBridgeRunning)) { Start-ChatGptBridge }
                    Start-Process $script:ChatGptManagerUrl | Out-Null
                    Write-Host
                    Write-Host '[OK] ChatGPT 탭 관리 화면을 열었습니다.'
                    Pause-Setup
                }
                '3' {
                    if (-not (Test-Path -LiteralPath $script:ChatGptExtensionManifestPath -PathType Leaf)) {
                        throw "Chrome 확장 manifest를 찾지 못했습니다: $script:ChatGptExtensionManifestPath"
                    }
                    Start-Process explorer.exe -ArgumentList @('/select,', ('"{0}"' -f $script:ChatGptExtensionManifestPath)) | Out-Null
                    Write-Host
                    Write-Host '[INFO] Chrome 확장 프로그램 폴더를 열었습니다.'
                    Write-Host '       chrome://extensions 에서 개발자 모드를 켠 뒤'
                    Write-Host '       압축해제된 확장 프로그램 로드로 이 폴더를 한 번 등록하세요.'
                    Pause-Setup
                }
                '4' {
                    Write-Host
                    Write-SetupStatusLine -Name 'ChatGPT 감시' -Prefix 'ChatGPT 감시: ' -Value (Get-ChatGptBridgeStatusLabel)
                    Write-Host ("관리 화면: {0}" -f $script:ChatGptManagerUrl)
                    Write-Host ("Chrome 확장: {0}" -f (Split-Path -Parent $script:ChatGptExtensionManifestPath))
                    Pause-Setup
                }
                '0' { return }
                default {
                    Write-Host
                    Write-Host '[ERROR] 0~4 사이 숫자를 입력하세요.'
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
    'Write-Host ("  Webhook     {0}" -f $webhookStatus)',
    "Write-SetupStatusLine -Name 'Webhook' -Prefix '  Webhook     ' -Value `$webhookStatus"
)
$source = $source.Replace(
    'Write-Host ("  역할 멘션   {0}" -f $mentionStatus)',
    "Write-SetupStatusLine -Name '역할 멘션' -Prefix '  역할 멘션   ' -Value `$mentionStatus"
)
$source = $source.Replace(
    'Write-Host ("  명령 등록   {0}" -f $pathStatus)',
    "Write-SetupStatusLine -Name '명령 등록' -Prefix '  명령 등록   ' -Value `$pathStatus"
)
$source = $source.Replace(
    'Write-Host ("  Cursor Hook {0}" -f $cursorHookStatus)',
    "Write-SetupStatusLine -Name 'Cursor Hook' -Prefix '  Cursor Hook ' -Value `$cursorHookStatus"
)
$source = $source.Replace(
    'Write-Host ("  Hook 모드   {0}" -f $cursorHookMode)',
    "Write-SetupStatusLine -Name 'Hook 모드' -Prefix '  Hook 모드   ' -Value `$cursorHookMode`r`n    Write-SetupStatusLine -Name 'ChatGPT 감시' -Prefix '  ChatGPT 감시 ' -Value `$chatGptWatchStatus"
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
$script:ChatGptExtensionManifestPath = $chatGptExtensionManifestPath
$script:ChatGptManagerUrl = $chatGptManagerUrl

Invoke-Expression $source
