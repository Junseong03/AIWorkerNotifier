[CmdletBinding()]
param(
    [ValidateSet('always', 'off')]
    [string]$Mode,
    [string]$StateRoot,
    [switch]$Get
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $StateRoot = Join-Path $localAppData 'AIWorkerNotifier'
}

$stateDir = Join-Path $StateRoot 'state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$settingsPath = Join-Path $stateDir 'integration-settings.json'

function Read-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return [ordered]@{ cursorHookNotifyMode = 'always' }
    }
    $obj = Get-Content -Raw -Encoding utf8 -LiteralPath $settingsPath | ConvertFrom-Json
    $mode = [string]$obj.cursorHookNotifyMode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'always' }
    return [ordered]@{ cursorHookNotifyMode = $mode.Trim().ToLowerInvariant() }
}

if ($Get -or [string]::IsNullOrWhiteSpace($Mode)) {
    $current = Read-Settings
    Write-Output ($current.cursorHookNotifyMode)
    exit 0
}

$settings = Read-Settings
$settings.cursorHookNotifyMode = $Mode.ToLowerInvariant()
$json = ($settings | ConvertTo-Json -Compress)
[IO.File]::WriteAllText($settingsPath, $json + [Environment]::NewLine, $utf8NoBom)
Write-Host ('[OK] cursorHookNotifyMode={0}' -f $settings.cursorHookNotifyMode)
Write-Host ("     {0}" -f $settingsPath)
