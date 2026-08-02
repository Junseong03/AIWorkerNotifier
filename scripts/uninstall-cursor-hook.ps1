[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$HooksPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$HookMarker = 'AIWorkerNotifier-CursorHook.cmd'

if ([string]::IsNullOrWhiteSpace($HooksPath)) {
    $HooksPath = Join-Path $env:USERPROFILE '.cursor\hooks.json'
}

function Test-IsAiWorkerNotifierStopCommand {
    param([AllowNull()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    return ($Command -like ('*{0}*' -f $HookMarker))
}

if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) {
    Write-Host '[INFO] hooks.json이 없습니다. 제거할 Cursor Hook이 없습니다.'
    Write-Host ("       {0}" -f $HooksPath)
    exit 0
}

$raw = Get-Content -Raw -Encoding utf8 -LiteralPath $HooksPath
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host '[INFO] hooks.json이 비어 있습니다.'
    exit 0
}

try {
    $document = $raw | ConvertFrom-Json
}
catch {
    throw "Existing hooks.json is not valid JSON: $HooksPath"
}

if ($null -eq $document.hooks -or $null -eq $document.hooks.stop) {
    Write-Host '[INFO] stop Hook이 없습니다. 제거할 항목이 없습니다.'
    exit 0
}

$keptStop = [System.Collections.Generic.List[object]]::new()
$removed = 0
foreach ($item in @($document.hooks.stop)) {
    if (Test-IsAiWorkerNotifierStopCommand -Command ([string]$item.command)) {
        $removed++
        continue
    }
    $keptStop.Add($item)
}

if ($removed -eq 0) {
    Write-Host '[INFO] AIWorkerNotifier Cursor Hook 항목이 없습니다.'
    exit 0
}

$hooksMap = [ordered]@{}
foreach ($prop in $document.hooks.PSObject.Properties) {
    if ($prop.Name -eq 'stop') { continue }
    $hooksMap[$prop.Name] = $prop.Value
}
if ($keptStop.Count -gt 0) {
    $hooksMap['stop'] = @($keptStop.ToArray())
}

$version = 1
if ($null -ne $document.version) {
    $version = [int]$document.version
}

$resultObject = [ordered]@{
    version = $version
    hooks = $hooksMap
}

$jsonText = ($resultObject | ConvertTo-Json -Depth 20)
$bytes = $utf8NoBom.GetBytes($jsonText + [Environment]::NewLine)
$null = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)

$hooksDir = Split-Path -Parent $HooksPath
$tempPath = Join-Path $hooksDir ('hooks.json.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllBytes($tempPath, $bytes)
    $null = (Get-Content -Raw -Encoding utf8 -LiteralPath $tempPath | ConvertFrom-Json)
    Move-Item -LiteralPath $tempPath -Destination $HooksPath -Force
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ('[OK] AIWorkerNotifier Cursor Hook 항목 {0}개를 제거했습니다.' -f $removed)
Write-Host ("     {0}" -f $HooksPath)
