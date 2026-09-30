[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Message,

    [string]$Title = '',

    [string]$Project = '',

    [Alias('AgentRole')]
    [string]$Agent = '',

    [ValidateSet('info', 'warning', 'error')]
    [string]$Severity = 'info',

    [string]$Source = 'notify-cli',

    [Parameter(DontShow = $true)]
    [string]$RelayUrl = '',

    [Parameter(DontShow = $true)]
    [string]$TokenFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$defaultRelayUrl = 'https://pagebound-sync-oci.tail14a9ee.ts.net:8771'

function Get-GitProject {
    try {
        $root = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$root)) {
            return Split-Path -Leaf ([string]$root).Trim()
        }
    } catch { }

    try {
        return Split-Path -Leaf (Get-Location).Path
    } catch {
        return ''
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RelayUrl)) {
        $RelayUrl = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_RELAY_URL')
    }
    if ([string]::IsNullOrWhiteSpace($RelayUrl)) {
        $RelayUrl = $defaultRelayUrl
    }

    $token = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_RELAY_TOKEN')

    if ([string]::IsNullOrWhiteSpace($token)) {
        if ([string]::IsNullOrWhiteSpace($TokenFile)) {
            $TokenFile = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_RELAY_TOKEN_FILE')
        }
        if ([string]::IsNullOrWhiteSpace($TokenFile)) {
            $TokenFile = Join-Path $HOME '.config\ai-worker-notifier\relay-token'
        }
        if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
            throw "Relay token 파일을 찾을 수 없습니다: $TokenFile"
        }
        $token = ([IO.File]::ReadAllText($TokenFile, $utf8)).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Relay token이 비어 있습니다.'
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw 'Message는 비어 있을 수 없습니다.'
    }

    if ([string]::IsNullOrWhiteSpace($Project)) {
        $Project = Get-GitProject
    }

    $payload = [ordered]@{
        message = $Message
        title = $Title
        project = $Project
        agent = $Agent
        severity = $Severity
        source = $Source
    }

    $headers = @{
        Authorization = "Bearer $token"
    }

    $uri = $RelayUrl.TrimEnd('/') + '/api/v1/notifications'
    $body = $payload | ConvertTo-Json -Depth 4 -Compress

    $result = Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body))

    $notificationId = ''
    if ($null -ne $result -and $null -ne $result.PSObject.Properties['notificationId']) {
        $notificationId = [string]$result.notificationId
    }

    if ([string]::IsNullOrWhiteSpace($notificationId)) {
        Write-Host 'Notification delivered.'
    } else {
        Write-Host ("Notification delivered: {0}" -f $notificationId)
    }
} catch {
    # 알림 전송 실패가 호출한 Agent의 원래 작업 결과를 바꾸지 않게 한다.
    Write-Warning ("Notification was not delivered: {0}" -f $_.Exception.Message)
}

exit 0
