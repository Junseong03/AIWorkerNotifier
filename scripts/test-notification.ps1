[CmdletBinding()]
param(
    [string]$Status = 'AUDIT_COMPLETE',
    [string]$NextAction = 'VERIFY_DISCORD_MOBILE_NOTIFICATION'
)

$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $root 'bin\ai-task-complete.ps1') `
    -Task 'AI-WORKER-NOTIFIER-TEST' `
    -Status $Status `
    -Summary 'AI Worker Notifier 수동 테스트 이벤트' `
    -NextAction $NextAction `
    -Tests 'manual test' `
    -AgentRole 'USER' `
    -Source 'manual-powershell' `
    -Scope 'task'
