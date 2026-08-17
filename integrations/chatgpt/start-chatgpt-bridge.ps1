[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 43127
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementationPath = Join-Path $PSScriptRoot 'start-chatgpt-bridge.impl.ps1'
if (-not (Test-Path -LiteralPath $implementationPath)) {
    throw "ChatGPT bridge implementation was not found: $implementationPath"
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$source = [IO.File]::ReadAllText($implementationPath, $utf8)
$bridgeSourceRoot = $PSScriptRoot
$source = $source.Replace('$PSScriptRoot', '$bridgeSourceRoot')
$scriptBlock = [ScriptBlock]::Create($source)
& $scriptBlock -Port $Port
