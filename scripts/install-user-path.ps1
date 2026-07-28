[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'
if (-not (Test-Path -LiteralPath $bin)) { throw "bin 디렉터리를 찾을 수 없습니다: $bin" }

$current = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @()
if (-not [string]::IsNullOrWhiteSpace($current)) {
    $parts = $current.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
}

$exists = $parts | Where-Object { $_.TrimEnd('\') -ieq $bin.TrimEnd('\') }
if (-not $exists) {
    $newPath = (($parts + $bin) -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "사용자 PATH에 추가했습니다: $bin"
} else {
    Write-Host "이미 사용자 PATH에 등록되어 있습니다: $bin"
}

Write-Host '새 PowerShell과 새 Cursor CLI 세션에서 적용됩니다.'
Write-Host '확인: Get-Command ai-task-complete; Get-Command AIWorkerNotifier'
