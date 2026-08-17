[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$bridgePath = Join-Path $repoRoot 'integrations\chatgpt\start-chatgpt-bridge.ps1'
$backgroundPath = Join-Path $repoRoot 'integrations\chatgpt\chrome-extension\background.js'
$manifestPath = Join-Path $repoRoot 'integrations\chatgpt\chrome-extension\manifest.json'

function Assert-Contains {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}

$parseTokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $bridgePath,
    [ref]$parseTokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "ChatGPT bridge PowerShell parse failed: $messages"
}

$bridge = [IO.File]::ReadAllText($bridgePath)
$background = [IO.File]::ReadAllText($backgroundPath)
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

Assert-Contains $bridge "chatgpt-completions" 'Bridge must persist a bounded ChatGPT completion journal.'
Assert-Contains $bridge "ai-worker-notifier/chatgpt-completion/v1" 'Bridge completion journal schema is missing.'
Assert-Contains $bridge "flowduck-adapter" 'Bridge must expose the dedicated FlowDuck adapter client boundary.'
Assert-Contains $bridge "/api/tabs/focus'" 'Bridge focus request endpoint is missing.'
Assert-Contains $bridge "/api/tabs/focus-status'" 'Bridge focus status endpoint is missing.'
Assert-Contains $bridge "/api/tabs/focus-ack'" 'Bridge focus acknowledgement endpoint is missing.'
Assert-Contains $bridge "completionJournalLimit = 500" 'Completion journal retention must remain bounded.'

Assert-Contains $background "windowId" 'Chrome extension must report window identity.'
Assert-Contains $background "FOCUS_ACK_URL" 'Chrome extension focus acknowledgement is missing.'
Assert-Contains $background "chrome\.tabs\.update" 'Chrome extension must activate the existing tab.'
Assert-Contains $background "chrome\.windows\.update" 'Chrome extension must foreground the existing Chrome window.'

if ([string]$manifest.version -ne '0.1.11') {
    throw "Expected ChatGPT watcher extension version 0.1.11, got $($manifest.version)"
}
if (@($manifest.permissions) -notcontains 'tabs') {
    throw 'Chrome extension tabs permission is required for existing-tab focus.'
}

Write-Host 'PASS: ChatGPT Project Inbox bridge contract'
