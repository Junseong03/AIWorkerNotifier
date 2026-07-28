[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$stateDir = Join-Path $localAppData 'AIWorkerNotifier\state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$target = Join-Path $stateDir 'discord-webhook.dpapi'

$secure = Read-Host 'Discord Webhook URL을 입력하세요. 화면에는 표시되지 않습니다' -AsSecureString
$encrypted = ConvertFrom-SecureString $secure
[System.IO.File]::WriteAllText($target, $encrypted, [System.Text.UTF8Encoding]::new($false))
Write-Host "현재 Windows 사용자 범위 DPAPI로 저장했습니다: $target"
Write-Host 'Webhook URL은 저장소나 채팅에 붙이지 마세요.'
