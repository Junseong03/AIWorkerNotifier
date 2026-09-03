[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Message,

    [string]$Title = 'AI 작업 메시지',

    [string]$Project = '',

    [ValidateSet('info', 'warning', 'error')]
    [string]$Severity = 'info',

    [string]$AgentRole = '',

    [string]$Source = 'agent-cli',

    [Parameter(DontShow = $true)]
    [string]$RuntimeRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
function Limit-Text {
    param([AllowNull()][string]$Value, [int]$MaxLength)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $clean = ($Value -replace "[\r\n\t]+", ' ').Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength)
}

function Get-GitValue {
    param([string[]]$Arguments)
    try {
        $value = & git @Arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $value) {
            return (($value | Select-Object -First 1).ToString()).Trim()
        }
    } catch { }
    return ''
}

function Get-MessageOutcome {
    param([string]$Level)
    $result = switch ($Level) {
        'warning' { 'blocked' }
        'error' { 'failure' }
        default { 'success' }
    }
    return $result
}
try {
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            throw 'LOCALAPPDATA 경로를 확인할 수 없습니다.'
        }
        $RuntimeRoot = Join-Path $localAppData 'AIWorkerNotifier'
    }

    foreach ($dirName in @('inbox', 'processing', 'failed', 'history', 'state', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeRoot $dirName) | Out-Null
    }

    $repoRoot = Get-GitValue -Arguments @('rev-parse', '--show-toplevel')
    $branch = Get-GitValue -Arguments @('branch', '--show-current')
    $head = Get-GitValue -Arguments @('rev-parse', '--short=12', 'HEAD')

    if ([string]::IsNullOrWhiteSpace($Project)) {
        $Project = if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
            Split-Path -Leaf $repoRoot
        } else {
            Split-Path -Leaf (Get-Location).Path
        }
    }

    $eventId = [Guid]::NewGuid().ToString()
    $createdAtUtc = [DateTime]::UtcNow.ToString('o')
    $cleanTitle = Limit-Text $Title 120
    $cleanMessage = Limit-Text $Message 1400
    if ([string]::IsNullOrWhiteSpace($cleanTitle)) { $cleanTitle = 'AI 작업 메시지' }
    if ([string]::IsNullOrWhiteSpace($cleanMessage)) { throw 'Message는 비어 있을 수 없습니다.' }

    $event = [ordered]@{
        schemaVersion = 1
        eventId = $eventId
        completionKey = "message|$eventId"
        createdAtUtc = $createdAtUtc
        eventType = 'message'
        title = $cleanTitle
        message = $cleanMessage
        project = Limit-Text $Project 120
        task = $cleanTitle
        workflowStatus = 'MESSAGE'
        outcome = Get-MessageOutcome $Severity
        scope = 'local_phase'
        summary = $cleanMessage
        nextAction = 'CONTINUE'
        tests = ''
        agentRole = Limit-Text $AgentRole 80
        source = Limit-Text $Source 80
        severity = $Severity
        branch = Limit-Text $branch 120
        head = Limit-Text $head 40
        productCommit = ''
        workflowCommit = ''
        dispatchId = ''
        host = Limit-Text $env:COMPUTERNAME 80
    }

    $json = $event | ConvertTo-Json -Depth 5
    $inbox = Join-Path $RuntimeRoot 'inbox'
    $tmpPath = Join-Path $inbox ("{0}.json.tmp" -f $eventId)
    $finalPath = Join-Path $inbox ("{0}.json" -f $eventId)

    [System.IO.File]::WriteAllText(
        $tmpPath,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $tmpPath -Destination $finalPath -Force

    Write-Host ("AI Worker message queued: {0}" -f $eventId)
} catch {
    # 메시지 전달 실패가 원래 Agent 작업 결과를 바꾸지 않게 한다.
    Write-Warning ("AI Worker message was not queued: {0}" -f $_.Exception.Message)
}

exit 0
