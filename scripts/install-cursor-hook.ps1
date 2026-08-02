[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$HooksPath,
    [string]$BackupDirectory,
    [switch]$StatusOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
}

if ([string]::IsNullOrWhiteSpace($HooksPath)) {
    $HooksPath = Join-Path $env:USERPROFILE '.cursor\hooks.json'
}

$HookMarker = 'AIWorkerNotifier-CursorHook.cmd'
$HookCommand = Join-Path $RepoRoot 'bin\AIWorkerNotifier-CursorHook.cmd'

function Test-IsAiWorkerNotifierStopCommand {
    param([AllowNull()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    return ($Command -like ('*{0}*' -f $HookMarker))
}

function Get-CursorHookInstallStatus {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            installed = $false
            status = 'missing'
            hooks_path = $Path
            count = 0
        }
    }
    try {
        $json = Get-Content -Raw -Encoding utf8 -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            installed = $false
            status = 'error'
            hooks_path = $Path
            count = 0
            detail = 'json_parse_failed'
        }
    }
    $stopHooks = @()
    if ($null -ne $json.hooks -and $null -ne $json.hooks.stop) {
        $stopHooks = @($json.hooks.stop)
    }
    $ours = @(
        $stopHooks | Where-Object {
            Test-IsAiWorkerNotifierStopCommand -Command ([string]$_.command)
        }
    )
    return [pscustomobject]@{
        installed = ($ours.Count -gt 0)
        status = if ($ours.Count -gt 0) { 'installed' } else { 'absent' }
        hooks_path = $Path
        count = $ours.Count
        command = if ($ours.Count -gt 0) { [string]$ours[0].command } else { $null }
    }
}

if ($StatusOnly) {
    $status = Get-CursorHookInstallStatus -Path $HooksPath
    $status | ConvertTo-Json -Compress
    exit 0
}

$hookEntry = [ordered]@{
    command = $HookCommand
    timeout = 30
}

$hooksDir = Split-Path -Parent $HooksPath
if (-not (Test-Path -LiteralPath $hooksDir)) {
    New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
}

$document = $null
$hadExisting = $false
if (Test-Path -LiteralPath $HooksPath -PathType Leaf) {
    $hadExisting = $true
    $rawExisting = Get-Content -Raw -Encoding utf8 -LiteralPath $HooksPath
    if ([string]::IsNullOrWhiteSpace($rawExisting)) {
        $document = [ordered]@{ version = 1; hooks = [ordered]@{} }
    }
    else {
        try {
            $document = $rawExisting | ConvertFrom-Json
        }
        catch {
            throw "Existing hooks.json is not valid JSON: $HooksPath"
        }
    }
}
else {
    $document = [pscustomobject]@{
        version = 1
        hooks = [pscustomobject]@{}
    }
}

if ($null -eq $document.version) {
    $document | Add-Member -NotePropertyName version -NotePropertyValue 1 -Force
}
if ($null -eq $document.hooks) {
    $document | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
}

$hooksObject = $document.hooks
$stopList = [System.Collections.Generic.List[object]]::new()
if ($null -ne $hooksObject.stop) {
    foreach ($item in @($hooksObject.stop)) {
        if (Test-IsAiWorkerNotifierStopCommand -Command ([string]$item.command)) {
            continue
        }
        $stopList.Add($item)
    }
}
$stopList.Add([pscustomobject]$hookEntry)

# Rebuild hooks hashtable preserving other events.
$hooksMap = [ordered]@{}
foreach ($prop in $hooksObject.PSObject.Properties) {
    if ($prop.Name -eq 'stop') { continue }
    $hooksMap[$prop.Name] = $prop.Value
}
$hooksMap['stop'] = @($stopList.ToArray())

$resultObject = [ordered]@{
    version = [int]$document.version
    hooks = $hooksMap
}

$jsonText = ($resultObject | ConvertTo-Json -Depth 20)
# ConvertTo-Json may use Windows newlines; normalize to LF-friendly content is fine.
$bytes = $utf8NoBom.GetBytes($jsonText + [Environment]::NewLine)

# Re-validate before replace.
$null = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)

if ($hadExisting) {
    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        $BackupDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) `
            'AIWorkerNotifier\backups\cursor-hooks'
    }
    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path $BackupDirectory ("hooks.json.bak-{0}" -f $stamp)
    Copy-Item -LiteralPath $HooksPath -Destination $backupPath -Force
}

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

$finalStatus = Get-CursorHookInstallStatus -Path $HooksPath
Write-Host ('[OK] Cursor Hook installed: {0}' -f $HooksPath)
Write-Host ('     command: {0}' -f $HookCommand)
Write-Host ('     status: {0}' -f $finalStatus.status)
Write-Host 'Cursor may need a restart or hooks.json reload before the stop hook runs.'
