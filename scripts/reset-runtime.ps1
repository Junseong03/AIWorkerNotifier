[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$KeepWebhook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIWorkerNotifier'
$webhook = Join-Path $root 'state\discord-webhook.dpapi'
$backup = $null
if ($KeepWebhook -and (Test-Path -LiteralPath $webhook)) {
    $backup = Get-Content -LiteralPath $webhook -Raw
}

if ($PSCmdlet.ShouldProcess($root, 'AIWorkerNotifier runtime 삭제')) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -ne $backup) {
        $state = Join-Path $root 'state'
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        [System.IO.File]::WriteAllText($webhook, $backup, [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host "런타임을 초기화했습니다: $root"
}
