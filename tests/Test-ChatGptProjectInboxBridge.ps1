[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$bridgePath = Join-Path $repoRoot 'integrations\chatgpt\start-chatgpt-bridge.ps1'
$bridgeImplementationPath = Join-Path $repoRoot 'integrations\chatgpt\start-chatgpt-bridge.impl.ps1'
$backgroundPath = Join-Path $repoRoot 'integrations\chatgpt\chrome-extension\background.js'
$contentPath = Join-Path $repoRoot 'integrations\chatgpt\chrome-extension\content.js'
$manifestPath = Join-Path $repoRoot 'integrations\chatgpt\chrome-extension\manifest.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Assert-Contains {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-NotContains {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -match $Pattern) { throw $Message }
}

function Assert-LiteralContains {
    param([string]$Text, [string]$Value, [string]$Message)
    if (-not $Text.Contains($Value)) { throw $Message }
}

function Assert-LiteralNotContains {
    param([string]$Text, [string]$Value, [string]$Message)
    if ($Text.Contains($Value)) { throw $Message }
}

function Read-And-AssertPowerShellUtf8 {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label was not found: $Path"
    }

    $source = [IO.File]::ReadAllText($Path, $utf8)
    $parseTokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput(
        $source,
        [ref]$parseTokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -gt 0) {
        $messages = @(
            $parseErrors | ForEach-Object {
                "line $($_.Extent.StartLineNumber), column $($_.Extent.StartColumnNumber): $($_.Message)"
            }
        ) -join '; '
        throw "$Label PowerShell parse failed: $messages"
    }
    return $source
}

$launcher = Read-And-AssertPowerShellUtf8 $bridgePath 'ChatGPT bridge launcher'
$bridge = Read-And-AssertPowerShellUtf8 $bridgeImplementationPath 'ChatGPT bridge implementation'
$background = [IO.File]::ReadAllText($backgroundPath, $utf8)
$content = [IO.File]::ReadAllText($contentPath, $utf8)
$manifest = [IO.File]::ReadAllText($manifestPath, $utf8) | ConvertFrom-Json

Assert-Contains $launcher "start-chatgpt-bridge\.impl\.ps1" 'Bridge launcher must load the UTF-8 implementation file.'
Assert-Contains $launcher "ReadAllText" 'Bridge launcher must explicitly read the implementation source.'
Assert-Contains $launcher "UTF8Encoding" 'Bridge launcher must explicitly decode the implementation as UTF-8.'
Assert-Contains $launcher "ScriptBlock\]::Create" 'Bridge launcher must parse the decoded implementation in memory.'
Assert-LiteralContains $launcher '. $scriptBlock -Port $Port' 'Bridge launcher must dot-source the implementation so script-scope state remains shared.'
Assert-LiteralNotContains $launcher '& $scriptBlock -Port $Port' 'Bridge launcher must not invoke the implementation in a child scope.'

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
Assert-Contains $bridge "INVALID_TARGET_URL" 'Bridge must distinguish an invalid current-session URL from a missing tab.'
Assert-Contains $bridge "focusDebugEntries" 'Bridge must retain bounded browser-control diagnostics.'
Assert-Contains $bridge "최근 browser-control 진단" 'Bridge management page must surface browser-control diagnostics.'
Assert-Contains $bridge "focus request tab=" 'Bridge must log the incoming focus-or-open contract.'
Assert-Contains $bridge "focus ACK received" 'Bridge must log extension acknowledgements.'
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
Assert-Contains $background "\[AIWorkerNotifier\]\[browser-control\]" 'Chrome background must emit browser-control diagnostics.'
Assert-Contains $background "socket-focus-action-received" 'Chrome background must log pushed focus-or-open receipt.'
Assert-Contains $background "watcher-injected" 'Chrome background must report content watcher reinjection.'
Assert-NotContains $background "FOCUS_POLL_INTERVAL_MS" 'Focus delivery must not depend on a service-worker setInterval polling loop.'
Assert-NotContains $background "pollFocusRequests" 'Focus delivery must not depend on a service-worker polling function.'

Assert-Contains $content "WATCHER_VERSION = '0\.1\.15'" 'Content watcher version must track the extension reload-recovery revision.'
Assert-Contains $content "extensionRuntimeAvailable" 'Content watcher must detect an invalidated extension runtime before sendMessage.'
Assert-Contains $content "stopping stale watcher" 'Content watcher must stop itself when an old extension context is invalidated.'
Assert-LiteralNotContains $content 'if (existing?.version === WATCHER_VERSION && existing?.active === true) return;' 'Reinjection must replace an old watcher even when the page-global version marker matches.'

if ([string]$manifest.version -ne '0.1.15') {
    throw "Expected ChatGPT watcher extension version 0.1.15, got $($manifest.version)"
}
if ([string]$manifest.minimum_chrome_version -ne '116') {
    throw 'Expected minimum Chrome version 116 for WebSocket service-worker lifetime support.'
}
if (@($manifest.permissions) -notcontains 'tabs') {
    throw 'Chrome extension tabs permission is required for exact existing-tab discovery.'
}

Write-Host 'PASS: ChatGPT Project Inbox bridge contract'
