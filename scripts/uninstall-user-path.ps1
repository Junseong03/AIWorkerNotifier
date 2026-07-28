[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'
$current = [Environment]::GetEnvironmentVariable('Path', 'User')
if ([string]::IsNullOrWhiteSpace($current)) { exit 0 }

$parts = $current.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) |
    Where-Object { $_.TrimEnd('\') -ine $bin.TrimEnd('\') }
[Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
Write-Host "사용자 PATH에서 제거했습니다: $bin"
