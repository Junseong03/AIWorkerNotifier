[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$chatGptRoot = Join-Path $repoRoot 'integrations\chatgpt'
$launcherPath = Join-Path $chatGptRoot 'start-chatgpt-bridge.ps1'
$packagePath = Join-Path $chatGptRoot 'chatgpt_bridge'
$backgroundPath = Join-Path $chatGptRoot 'chrome-extension\background.js'
$contentPath = Join-Path $chatGptRoot 'chrome-extension\content.js'
$manifestPath = Join-Path $chatGptRoot 'chrome-extension\manifest.json'
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

function Read-Utf8 {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label was not found: $Path"
    }
    return [IO.File]::ReadAllText($Path, $utf8)
}

function Read-And-AssertPowerShellUtf8 {
    param([string]$Path, [string]$Label)
    $source = Read-Utf8 $Path $Label
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

function Resolve-BridgePython {
    $configured = [string]$env:AI_WORKER_NOTIFIER_PYTHON
    if (-not [string]::IsNullOrWhiteSpace($configured) -and (Test-Path -LiteralPath $configured -PathType Leaf)) {
        return [pscustomobject]@{ Exe = (Resolve-Path -LiteralPath $configured).Path; Prefix = @() }
    }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($null -ne $py) {
        return [pscustomobject]@{ Exe = $py.Source; Prefix = @('-3') }
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        return [pscustomobject]@{ Exe = $python.Source; Prefix = @() }
    }
    throw 'Python 3.10+ is required for the ChatGPT bridge contract test.'
}

$launcher = Read-And-AssertPowerShellUtf8 $launcherPath 'ChatGPT bridge launcher'
Assert-LiteralContains $launcher '-m chatgpt_bridge.main' 'Bridge launcher must delegate to the Python module.'
Assert-LiteralContains $launcher '--parent-pid $PID' 'Bridge launcher must tie the Python child lifetime to the launcher.'
Assert-Contains $launcher 'AI_WORKER_NOTIFIER_PYTHON' 'Bridge launcher must support an explicit Python path.'
Assert-LiteralNotContains $launcher 'start-chatgpt-bridge.impl.ps1' 'Legacy PowerShell bridge implementation must not be loaded.'

$pythonFiles = @(
    'common.py',
    'models.py',
    'tabs.py',
    'focus.py',
    'persistence.py',
    'state.py',
    'server.py',
    'main.py',
    '__init__.py'
)
$pythonSource = ''
foreach ($name in $pythonFiles) {
    $pythonSource += "`n" + (Read-Utf8 (Join-Path $packagePath $name) "Python bridge $name")
}

Assert-Contains $pythonSource 'ai-worker-notifier/chatgpt-bridge-status/v1' 'Python bridge identity status schema is missing.'
Assert-Contains $pythonSource 'ai-worker-notifier/chatgpt-completion/v1' 'Bridge completion journal schema is missing.'
Assert-Contains $pythonSource 'flowduck-adapter' 'Bridge must expose the FlowDuck adapter client boundary.'
Assert-Contains $pythonSource '/api/bridge/status' 'Bridge status endpoint is missing.'
Assert-Contains $pythonSource '/api/tabs/focus' 'Bridge focus request endpoint is missing.'
Assert-Contains $pythonSource '/api/tabs/focus-status' 'Bridge focus status endpoint is missing.'
Assert-Contains $pythonSource '/api/tabs/focus-ack' 'Bridge focus acknowledgement endpoint is missing.'
Assert-Contains $pythonSource '/api/extension/socket' 'Bridge WebSocket endpoint is missing.'
Assert-Contains $pythonSource 'ai-worker-notifier-chatgpt-v1' 'Bridge WebSocket subprotocol is missing.'
Assert-Contains $pythonSource 'openIfMissing' 'Bridge must carry the focus-or-open contract.'
Assert-Contains $pythonSource 'EXTENSION_CHANNEL_UNAVAILABLE' 'Bridge must fail fast when the browser channel is unavailable.'
Assert-Contains $pythonSource 'INVALID_TARGET_URL' 'Bridge must distinguish invalid target URLs.'
Assert-LiteralContains $pythonSource 'class="panel diag"' 'Bridge management page must surface browser-control diagnostics.'
Assert-Contains $pythonSource 'chatgpt-bridge\.log' 'Bridge must persist bounded diagnostics.'
Assert-Contains $pythonSource 'COMPLETION_JOURNAL_LIMIT = 500' 'Completion journal retention must remain bounded.'
Assert-Contains $pythonSource 'FOCUS_KEEPALIVE_SECONDS = 20' 'WebSocket keepalive must remain inside the MV3 idle window.'
Assert-Contains $pythonSource '127\.0\.0\.1' 'Bridge must bind/probe loopback only.'

$python = Resolve-BridgePython
Push-Location $chatGptRoot
try {
    & $python.Exe @($python.Prefix) -B -m chatgpt_bridge.main --self-test
    if ($LASTEXITCODE -ne 0) {
        throw "Python ChatGPT bridge self-test failed with exit $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$background = Read-Utf8 $backgroundPath 'Chrome extension background'
$content = Read-Utf8 $contentPath 'Chrome extension content watcher'
$manifest = (Read-Utf8 $manifestPath 'Chrome extension manifest') | ConvertFrom-Json

Assert-Contains $background 'windowId' 'Chrome extension must report window identity.'
Assert-Contains $background 'FOCUS_ACK_URL' 'Chrome extension focus acknowledgement is missing.'
Assert-Contains $background 'new WebSocket' 'Chrome extension must keep an event-driven localhost control channel.'
Assert-Contains $background 'FOCUS_SOCKET_PROTOCOL' 'Chrome extension WebSocket protocol guard is missing.'
Assert-Contains $background 'focus-or-open' 'Chrome extension must handle pushed focus-or-open actions.'
Assert-Contains $background 'canonicalChatGptUrl' 'Chrome extension must canonicalize actual tab URLs.'
Assert-Contains $background 'chrome\.tabs\.query\(\{\}\)' 'Chrome extension must query actual tabs before focus-or-open.'
Assert-Contains $background 'matchingTargetTabs' 'Chrome extension must resolve exact canonical URL matches before creation.'
Assert-Contains $background 'chrome\.tabs\.create' 'Chrome extension must create a tab only after no exact match.'
Assert-Contains $background 'chrome\.tabs\.update' 'Chrome extension must activate the resolved tab.'
Assert-Contains $background 'chrome\.windows\.update' 'Chrome extension must foreground the resolved Chrome window.'
Assert-Contains $background 'lastAccessed' 'Duplicate existing matches need a deterministic recent-tab preference.'
Assert-Contains $background 'enqueueBrowserFocusAction' 'Browser focus-or-open actions must be serialized.'
Assert-Contains $background 'browserActionChain' 'Serialized browser action chain is missing.'
Assert-Contains $background 'queuedFocusRequestIds' 'Duplicate focus delivery must be suppressed.'
Assert-Contains $background 'focusRequestsInFlight' 'Duplicate focus execution must be guarded.'
Assert-Contains $background '\[AIWorkerNotifier\]\[browser-control\]' 'Chrome background must emit browser-control diagnostics.'
Assert-Contains $background 'socket-focus-action-received' 'Chrome background must log pushed focus-or-open receipt.'
Assert-Contains $background 'watcher-injected' 'Chrome background must report content watcher reinjection.'
Assert-NotContains $background 'FOCUS_POLL_INTERVAL_MS' 'Focus delivery must not depend on service-worker interval polling.'
Assert-NotContains $background 'pollFocusRequests' 'Focus delivery must not depend on a service-worker polling function.'

Assert-Contains $content "WATCHER_VERSION = '0\.1\.15'" 'Content watcher version must track reload recovery.'
Assert-Contains $content 'extensionRuntimeAvailable' 'Content watcher must detect an invalidated extension runtime.'
Assert-Contains $content 'stopping stale watcher' 'Content watcher must stop after extension context invalidation.'
Assert-LiteralNotContains $content 'if (existing?.version === WATCHER_VERSION && existing?.active === true) return;' 'Reinjection must replace stale page-global watcher state.'

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
