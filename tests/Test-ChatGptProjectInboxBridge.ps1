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

function Assert-NotContains {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -match $Pattern) { throw $Message }
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
Assert-Contains $bridge "OpenIfMissing" 'Bridge must support focus-or-open requests without trusting a stale tab cache.'
Assert-Contains $bridge "/api/extension/socket" 'Bridge must expose the localhost extension WebSocket control channel.'
Assert-Contains $bridge "ai-worker-notifier-chatgpt-v1" 'Bridge WebSocket subprotocol is missing.'
Assert-Contains $bridge "101 Switching Protocols" 'Bridge WebSocket handshake is missing.'
Assert-Contains $bridge "Send-FocusSocketPayload" 'Bridge must push browser actions to the connected extension.'
Assert-Contains $bridge "type = 'focus-or-open'" 'Bridge must push typed focus-or-open actions.'
Assert-Contains $bridge "EXTENSION_CHANNEL_UNAVAILABLE" 'Bridge must fail fast when the browser control channel is unavailable.'
Assert-Contains $bridge "focusSocketKeepAliveSeconds = 20" 'Bridge WebSocket keepalive must remain inside the MV3 idle window.'
Assert-Contains $bridge "completionJournalLimit = 500" 'Completion journal retention must remain bounded.'

Assert-Contains $background "windowId" 'Chrome extension must report window identity.'
Assert-Contains $background "FOCUS_ACK_URL" 'Chrome extension focus acknowledgement is missing.'
Assert-Contains $background "new WebSocket" 'Chrome extension must keep an event-driven localhost control channel.'
Assert-Contains $background "FOCUS_SOCKET_PROTOCOL" 'Chrome extension WebSocket protocol guard is missing.'
Assert-Contains $background "focus-or-open" 'Chrome extension must handle pushed focus-or-open actions.'
Assert-Contains $background "canonicalChatGptUrl" 'Chrome extension must canonicalize actual tab URLs before deciding whether to create a tab.'
Assert-Contains $background "chrome\.tabs\.query\(\{\}\)" 'Chrome extension must query actual open tabs before focus-or-open.'
Assert-Contains $background "matchingTargetTabs" 'Chrome extension must resolve exact canonical URL matches before creation.'
Assert-Contains $background "chrome\.tabs\.create" 'Chrome extension must create a tab only when no exact existing match is present.'
Assert-Contains $background "chrome\.tabs\.update" 'Chrome extension must activate the resolved tab.'
Assert-Contains $background "chrome\.windows\.update" 'Chrome extension must foreground the resolved Chrome window.'
Assert-Contains $background "lastAccessed" 'When duplicate matching tabs already exist, the extension must have a deterministic recent-tab preference.'
Assert-Contains $background "enqueueBrowserFocusAction" 'Browser focus-or-open actions must be serialized.'
Assert-Contains $background "browserActionChain" 'Serialized browser action chain is missing.'
Assert-Contains $background "queuedFocusRequestIds" 'Duplicate delivery of the same focus request must be suppressed.'
Assert-Contains $background "focusRequestsInFlight" 'Duplicate focus execution must be guarded while an acknowledgement is in flight.'
Assert-NotContains $background "FOCUS_POLL_INTERVAL_MS" 'Focus delivery must not depend on a service-worker setInterval polling loop.'
Assert-NotContains $background "pollFocusRequests" 'Focus delivery must not depend on a service-worker polling function.'

if ([string]$manifest.version -ne '0.1.14') {
    throw "Expected ChatGPT watcher extension version 0.1.14, got $($manifest.version)"
}
if ([string]$manifest.minimum_chrome_version -ne '116') {
    throw "Expected minimum Chrome version 116 for WebSocket service-worker lifetime support."
}
if (@($manifest.permissions) -notcontains 'tabs') {
    throw 'Chrome extension tabs permission is required for exact existing-tab discovery.'
}

Write-Host 'PASS: ChatGPT Project Inbox bridge contract'