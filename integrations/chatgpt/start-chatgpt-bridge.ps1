[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 43127
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pythonExe = $null
$pythonPrefixArgs = @()
$configured = [string]$env:AI_WORKER_NOTIFIER_PYTHON

if (-not [string]::IsNullOrWhiteSpace($configured) -and (Test-Path -LiteralPath $configured -PathType Leaf)) {
    $pythonExe = (Resolve-Path -LiteralPath $configured).Path
}
elseif ($null -ne (Get-Command py.exe -ErrorAction SilentlyContinue)) {
    $pythonExe = (Get-Command py.exe).Source
    $pythonPrefixArgs = @('-3')
}
elseif ($null -ne (Get-Command python.exe -ErrorAction SilentlyContinue)) {
    $pythonExe = (Get-Command python.exe).Source
}
else {
    throw 'Python 3.10+ was not found. Set AI_WORKER_NOTIFIER_PYTHON or install Python.'
}

Push-Location $PSScriptRoot
try {
    & $pythonExe @pythonPrefixArgs -m chatgpt_bridge.main --port $Port
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($null -eq $exitCode) { $exitCode = 1 }
exit $exitCode
