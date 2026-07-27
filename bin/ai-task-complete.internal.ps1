[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$Status,

    [Parameter(Mandatory = $true)]
    [string]$Summary,

    [Parameter(Mandatory = $true)]
    [string]$NextAction,

    [string]$Tests = '',

    [string]$AgentRole = '',

    [string]$Source = 'cursor-cli',

    [ValidateSet('info', 'warning', 'error')]
    [string]$Severity = 'info',

    [ValidateSet('worker_process', 'local_phase', 'task', 'main_audit')]
    [string]$Scope = 'local_phase',

    [ValidateSet('success', 'needs_input', 'blocked', 'failure', 'cancelled')]
    [string]$Outcome = '',

    [string]$Project = '',

    [string]$DispatchId = '',

    [Alias('product-commit')]
    [string]$ProductCommit = '',

    [Alias('workflow-commit')]
    [string]$WorkflowCommit = ''
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

function Infer-Outcome {
    param([string]$WorkflowStatus)
    $normalized = $WorkflowStatus.ToUpperInvariant()
    if ($normalized -match 'INPUT_REQUIRED|VERIFY_ON_DEVICE|WAIT_FOR_USER|USER_DECISION') { return 'needs_input' }
    if ($normalized -match 'CONTRACT_DRIFT|BLOCKED|PENDING') { return 'blocked' }
    if ($normalized -match 'FAIL|ERROR') { return 'failure' }
    if ($normalized -match 'CANCEL') { return 'cancelled' }
    return 'success'
}

try {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'LOCALAPPDATA 경로를 확인할 수 없습니다.'
    }

    $runtimeRoot = Join-Path $localAppData 'AIWorkerNotifier'
    $inbox = Join-Path $runtimeRoot 'inbox'
    foreach ($dirName in @('inbox', 'processing', 'failed', 'history', 'state', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $runtimeRoot $dirName) | Out-Null
    }

    $repoRoot = Get-GitValue -Arguments @('rev-parse', '--show-toplevel')
    $branch = Get-GitValue -Arguments @('branch', '--show-current')
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = Get-GitValue -Arguments @('rev-parse', '--short', 'HEAD')
    }
    $head = Get-GitValue -Arguments @('rev-parse', '--short=12', 'HEAD')

    if ([string]::IsNullOrWhiteSpace($Project)) {
        if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
            $Project = Split-Path -Leaf $repoRoot
        } else {
            $Project = Split-Path -Leaf (Get-Location).Path
        }
    }

    if ([string]::IsNullOrWhiteSpace($Outcome)) {
        $Outcome = Infer-Outcome -WorkflowStatus $Status
    }

    if ([string]::IsNullOrWhiteSpace($DispatchId)) {
        $DispatchId = [Environment]::GetEnvironmentVariable('AI_TASK_DISPATCH_ID', 'Process')
    }

    $eventId = [Guid]::NewGuid().ToString()
    $createdAtUtc = [DateTime]::UtcNow.ToString('o')

    $completionParts = @(
        (Limit-Text $Project 120).ToLowerInvariant(),
        (Limit-Text $Task 160).ToLowerInvariant(),
        $Scope.ToLowerInvariant(),
        (Limit-Text $Status 120).ToLowerInvariant(),
        (Limit-Text $DispatchId 120).ToLowerInvariant(),
        (Limit-Text $head 40).ToLowerInvariant()
    )
    $completionKey = ($completionParts -join '|')

    $event = [ordered]@{
        schemaVersion = 1
        eventId = $eventId
        completionKey = $completionKey
        createdAtUtc = $createdAtUtc
        project = Limit-Text $Project 120
        task = Limit-Text $Task 160
        workflowStatus = Limit-Text $Status 120
        outcome = $Outcome
        scope = $Scope
        summary = Limit-Text $Summary 300
        nextAction = Limit-Text $NextAction 120
        tests = Limit-Text $Tests 120
        agentRole = Limit-Text $AgentRole 80
        source = Limit-Text $Source 80
        severity = $Severity
        branch = Limit-Text $branch 120
        head = Limit-Text $head 40
        productCommit = Limit-Text $ProductCommit 40
        workflowCommit = Limit-Text $WorkflowCommit 40
        dispatchId = Limit-Text $DispatchId 120
        host = Limit-Text $env:COMPUTERNAME 80
    }

    $json = $event | ConvertTo-Json -Depth 5
    $tmpPath = Join-Path $inbox ("{0}.json.tmp" -f $eventId)
    $finalPath = Join-Path $inbox ("{0}.json" -f $eventId)

    [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmpPath -Destination $finalPath -Force

    Write-Host ("AI Worker notification event queued: {0}" -f $eventId)
} catch {
    # 알림은 작업 결과에 영향을 주지 않아야 하므로 항상 성공 코드로 종료한다.
    Write-Warning ("AI Worker notification was not queued: {0}" -f $_.Exception.Message)
}

exit 0
