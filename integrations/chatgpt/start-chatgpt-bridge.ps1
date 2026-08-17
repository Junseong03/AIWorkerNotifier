[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 43127
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$aiTaskComplete = Join-Path $repoRoot 'bin\ai-task-complete.internal.ps1'
$runtimeRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIWorkerNotifier'
$stateRoot = Join-Path $runtimeRoot 'state'
$disabledTabsPath = Join-Path $stateRoot 'chatgpt-disabled-tabs.json'
$completionJournalRoot = Join-Path $stateRoot 'chatgpt-completions'
$legacyTabTtlSeconds = 30
$completionJournalLimit = 500
$focusRequestTtlSeconds = 15
$tabs = @{}
$disabledTabs = @{}
$focusRequestsByTab = @{}
$focusStatusById = @{}

if (-not (Test-Path -LiteralPath $aiTaskComplete)) {
    throw "ai-task-complete 진입점을 찾을 수 없습니다: $aiTaskComplete"
}
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
New-Item -ItemType Directory -Force -Path $completionJournalRoot | Out-Null

function Limit-Text {
    param([AllowNull()][string]$Value, [int]$MaxLength)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $clean = ($Value -replace "[\r\n\t]+", ' ').Trim()
    if ($clean.Length -gt $MaxLength) { return $clean.Substring(0, $MaxLength) }
    return $clean
}

function Load-DisabledTabs {
    if (-not (Test-Path -LiteralPath $disabledTabsPath)) { return @{} }
    try {
        $raw = [IO.File]::ReadAllText($disabledTabsPath, $utf8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $items = $raw | ConvertFrom-Json
        $result = @{}
        foreach ($item in @($items)) {
            $id = Limit-Text ([string]$item) 100
            if (-not [string]::IsNullOrWhiteSpace($id)) { $result[$id] = $true }
        }
        return $result
    }
    catch {
        Write-Warning ("ChatGPT 탭 알림 제외 상태를 읽지 못했습니다: {0}" -f $_.Exception.Message)
        return @{}
    }
}

function Save-DisabledTabs {
    $ids = @($disabledTabs.Keys | Sort-Object)
    $json = if ($ids.Count -eq 0) { '[]' } else { $ids | ConvertTo-Json }
    [IO.File]::WriteAllText($disabledTabsPath, $json, $utf8)
}

function Remove-StaleLegacyTabs {
    # Chrome extension 탭은 TTL로 삭제하지 않는다.
    # 실제 Chrome tab removed / URL 이탈 이벤트가 왔을 때만 삭제한다.
    $cutoff = [DateTime]::UtcNow.AddSeconds(-1 * $legacyTabTtlSeconds)
    $disabledChanged = $false
    foreach ($id in @($tabs.Keys)) {
        if ($id -like 'chrome-*') { continue }
        if ($tabs[$id].LastSeenUtc -lt $cutoff) {
            $tabs.Remove($id)
            if ($disabledTabs.ContainsKey($id)) {
                $disabledTabs.Remove($id)
                $disabledChanged = $true
            }
        }
    }
    if ($disabledChanged) { Save-DisabledTabs }
}

function Remove-StaleFocusRequests {
    $cutoff = [DateTime]::UtcNow.AddSeconds(-1 * $focusRequestTtlSeconds)
    foreach ($requestId in @($focusStatusById.Keys)) {
        $status = $focusStatusById[$requestId]
        if ($status.CreatedAtUtc -lt $cutoff) {
            if ($status.Status -eq 'pending') {
                $status.Status = 'timeout'
                $status.Error = 'Chrome tab focus acknowledgement timed out.'
            }
        }
    }

    foreach ($tabId in @($focusRequestsByTab.Keys)) {
        $requestId = [string]$focusRequestsByTab[$tabId]
        if (-not $focusStatusById.ContainsKey($requestId) -or $focusStatusById[$requestId].Status -ne 'pending') {
            $focusRequestsByTab.Remove($tabId)
        }
    }
}

function Test-ChatGptUrl {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        return $uri.Scheme -eq 'https' -and @('chatgpt.com', 'www.chatgpt.com', 'chat.openai.com') -contains $uri.Host.ToLowerInvariant()
    }
    catch { return $false }
}

function Get-CanonicalChatGptUrl {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        $host = $uri.Host.ToLowerInvariant()
        if ($uri.Scheme -ne 'https' -or @('chatgpt.com', 'www.chatgpt.com', 'chat.openai.com') -notcontains $host) {
            return ''
        }
        if ($host -eq 'www.chatgpt.com' -or $host -eq 'chat.openai.com') { $host = 'chatgpt.com' }
        $path = $uri.AbsolutePath
        if ($path.Length -gt 1) { $path = $path.TrimEnd('/') }
        return "https://$host$path"
    }
    catch { return '' }
}

function HtmlEncode {
    param([AllowNull()][string]$Value)
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Upsert-ChromeTab {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Url,
        [Nullable[int]]$WindowId = $null,
        [Nullable[bool]]$Generating = $null
    )

    $idValue = Limit-Text $Id 100
    $titleValue = Limit-Text $Title 200
    $urlValue = Limit-Text $Url 2048

    if ([string]::IsNullOrWhiteSpace($idValue)) { return }
    if ($idValue -notlike 'chrome-*') { return }
    if (-not (Test-ChatGptUrl $urlValue)) { return }

    $generatingValue = $false
    $windowIdValue = $null
    if ($tabs.ContainsKey($idValue)) {
        $generatingValue = [bool]$tabs[$idValue].Generating
        $windowIdValue = $tabs[$idValue].WindowId
    }
    if ($null -ne $Generating) { $generatingValue = [bool]$Generating }
    if ($null -ne $WindowId) { $windowIdValue = [int]$WindowId }

    $tabs[$idValue] = [pscustomobject]@{
        TabId = $idValue
        WindowId = $windowIdValue
        Title = $titleValue
        Url = $urlValue
        Generating = $generatingValue
        LastSeenUtc = [DateTime]::UtcNow
    }
}

function Apply-ChromeTabSnapshot {
    param($SnapshotTabs)

    # Snapshot은 추가/갱신 전용이다.
    # 불완전하거나 빈 snapshot 하나가 열린 탭을 지우는 일이 없도록 여기서는 삭제하지 않는다.
    foreach ($item in @($SnapshotTabs)) {
        if ($null -eq $item) { continue }
        $windowId = $null
        if ($null -ne $item.windowId) { $windowId = [int]$item.windowId }
        Upsert-ChromeTab `
            -Id ([string]$item.tabId) `
            -WindowId $windowId `
            -Title ([string]$item.title) `
            -Url ([string]$item.url)
    }
}

function Remove-ChromeTab {
    param([string]$Id)

    $idValue = Limit-Text $Id 100
    if ([string]::IsNullOrWhiteSpace($idValue)) { return }
    if ($idValue -notlike 'chrome-*') { return }

    if ($tabs.ContainsKey($idValue)) { $tabs.Remove($idValue) }
    if ($focusRequestsByTab.ContainsKey($idValue)) {
        $requestId = [string]$focusRequestsByTab[$idValue]
        if ($focusStatusById.ContainsKey($requestId)) {
            $focusStatusById[$requestId].Status = 'failed'
            $focusStatusById[$requestId].Error = 'Chrome tab was closed before focus.'
        }
        $focusRequestsByTab.Remove($idValue)
    }
    if ($disabledTabs.ContainsKey($idValue)) {
        $disabledTabs.Remove($idValue)
        Save-DisabledTabs
    }
}

function Get-ManagementHtml {
    Remove-StaleLegacyTabs
    $rows = New-Object Collections.Generic.List[string]

    foreach ($tab in @($tabs.Values | Sort-Object Title, Url)) {
        $checked = if (-not $disabledTabs.ContainsKey($tab.TabId)) { ' checked' } else { '' }
        $state = if ($tab.Generating) { '응답 생성 중' } else { '대기 중' }
        $shortId = if ($tab.TabId.Length -gt 12) { $tab.TabId.Substring(0, 12) } else { $tab.TabId }
        $rows.Add((@"
<label class="tab-row">
  <input type="checkbox" name="tabId" value="$(HtmlEncode $tab.TabId)"$checked>
  <span class="tab-main"><strong>$(HtmlEncode $tab.Title)</strong><small>$(HtmlEncode $tab.Url)</small></span>
  <span class="state">$(HtmlEncode $state)</span>
  <code>$(HtmlEncode $shortId)</code>
</label>
"@).Trim())
    }

    $listHtml = if ($rows.Count -eq 0) {
        '<p class="empty">현재 감지된 ChatGPT 탭이 없습니다. Chrome 확장 프로그램이 설치·활성화되어 있는지 확인하세요.</p>'
    }
    else {
        $rows -join "`n"
    }

    return @"
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>AIWorkerNotifier - ChatGPT 탭</title>
<style>
body{font-family:Segoe UI,Malgun Gothic,sans-serif;max-width:980px;margin:40px auto;padding:0 20px;color:#202124;background:#f7f8fa}h1{margin-bottom:8px}.hint{color:#5f6368;margin-top:0}.panel{background:white;border:1px solid #dadce0;border-radius:12px;padding:18px}.tab-row{display:grid;grid-template-columns:28px 1fr 110px 110px;gap:12px;align-items:center;padding:14px 8px;border-bottom:1px solid #eee}.tab-row:last-child{border-bottom:0}.tab-main{min-width:0}.tab-main strong,.tab-main small{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tab-main small{color:#70757a;margin-top:4px}.state{font-size:13px;color:#5f6368}.actions{margin-top:18px;display:flex;gap:10px;align-items:center}button{border:0;border-radius:8px;padding:10px 16px;font-weight:600;cursor:pointer}button.primary{background:#1a73e8;color:white}.empty{color:#70757a;padding:12px}.privacy{font-size:13px;color:#70757a;margin-top:18px}code{font-size:12px}
</style>
</head>
<body>
<h1>ChatGPT 탭 감시</h1>
<p class="hint">새로 감지된 ChatGPT 탭은 기본적으로 알림 ON입니다. 알림을 받지 않을 탭만 체크 해제하세요. 목록은 약 5초마다 갱신됩니다.</p>
<form method="POST" action="/manage/select" class="panel">
$listHtml
<div class="actions"><button class="primary" type="submit">선택 저장</button><span>체크 해제한 탭의 완료 이벤트만 무시됩니다.</span></div>
</form>
<p class="privacy">탭 목록은 Chrome의 탭 이벤트와 snapshot으로 유지합니다. snapshot 누락만으로 열린 탭을 삭제하지 않습니다. DOM 감시는 생성 중/완료 상태만 확인하며 응답 본문과 입력 프롬프트는 읽지 않습니다.</p>
</body>
</html>
"@
}

function Write-HttpResponse {
    param(
        [IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$Body = '',
        [string]$ContentType = 'text/plain; charset=utf-8',
        [hashtable]$ExtraHeaders = @{}
    )

    $bodyBytes = $utf8.GetBytes($Body)
    $headers = New-Object Collections.Generic.List[string]
    $headers.Add("HTTP/1.1 $StatusCode $StatusText")
    $headers.Add('Connection: close')
    $headers.Add('Cache-Control: no-store')
    $headers.Add("Content-Type: $ContentType")
    $headers.Add("Content-Length: $($bodyBytes.Length)")
    foreach ($entry in $ExtraHeaders.GetEnumerator()) { $headers.Add("$($entry.Key): $($entry.Value)") }
    $headers.Add('')
    $headers.Add('')

    $headerBytes = [Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n"))
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

function Read-HttpRequest {
    param([IO.Stream]$Stream)

    $maxHeaderBytes = 32768
    $headerBytes = New-Object Collections.Generic.List[byte]

    while ($true) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'connection closed before HTTP headers completed' }
        $headerBytes.Add([byte]$value)

        if ($headerBytes.Count -gt $maxHeaderBytes) { throw 'request headers too large' }
        if ($headerBytes.Count -ge 4) {
            $n = $headerBytes.Count
            if (
                $headerBytes[$n - 4] -eq 13 -and
                $headerBytes[$n - 3] -eq 10 -and
                $headerBytes[$n - 2] -eq 13 -and
                $headerBytes[$n - 1] -eq 10
            ) { break }
        }
    }

    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    $requestLine = $lines[0]
    $headers = @{}

    for ($i = 1; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrEmpty($line)) { break }
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { continue }
        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $headers[$name] = $value
    }

    $contentLength = 0
    if ($headers.ContainsKey('Content-Length')) {
        if (-not [int]::TryParse([string]$headers['Content-Length'], [ref]$contentLength)) {
            throw 'invalid Content-Length'
        }
    }
    if ($contentLength -lt 0 -or $contentLength -gt 65536) { throw 'request body too large' }

    $bodyBytes = New-Object byte[] $contentLength
    $offset = 0
    while ($offset -lt $contentLength) {
        $count = $Stream.Read($bodyBytes, $offset, $contentLength - $offset)
        if ($count -le 0) { throw 'connection closed before HTTP body completed' }
        $offset += $count
    }

    $body = if ($contentLength -gt 0) { $utf8.GetString($bodyBytes) } else { '' }
    return [pscustomobject]@{
        RequestLine = $requestLine
        Headers = $headers
        Body = $body
    }
}

function Parse-JsonBody {
    param([string]$Body)
    try { return $Body | ConvertFrom-Json }
    catch { throw 'invalid JSON body' }
}

function Get-EventFileName {
    param([string]$EventId)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8.GetBytes($EventId)
        return (([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() + '.json')
    }
    finally {
        $sha.Dispose()
    }
}

function Write-CompletionJournal {
    param($Tab, $Data)

    $turnId = Limit-Text ([string]$Data.turnId) 80
    $detectedAt = Limit-Text ([string]$Data.detectedAtUtc) 80
    if ([string]::IsNullOrWhiteSpace($detectedAt)) { $detectedAt = [DateTime]::UtcNow.ToString('o') }
    $eventId = if ([string]::IsNullOrWhiteSpace($turnId)) {
        "{0}:{1}" -f $Tab.TabId, $detectedAt
    }
    else {
        "{0}:{1}" -f $Tab.TabId, $turnId
    }

    $windowId = $null
    if ($null -ne $Tab.WindowId) { $windowId = [int]$Tab.WindowId }
    $event = [ordered]@{
        schema = 'ai-worker-notifier/chatgpt-completion/v1'
        eventId = $eventId
        tabId = [string]$Tab.TabId
        windowId = $windowId
        title = Limit-Text ([string]$Tab.Title) 200
        url = Limit-Text ([string]$Tab.Url) 2048
        turnId = $turnId
        detectedAtUtc = $detectedAt
        detectionMode = Limit-Text ([string]$Data.detectionMode) 80
    }

    $fileName = Get-EventFileName $eventId
    $finalPath = Join-Path $completionJournalRoot $fileName
    if (Test-Path -LiteralPath $finalPath) { return }

    $tempPath = "$finalPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $json = $event | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($tempPath, $json, $utf8)
        Move-Item -LiteralPath $tempPath -Destination $finalPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }

    $oldFiles = @(Get-ChildItem -LiteralPath $completionJournalRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip $completionJournalLimit)
    foreach ($file in $oldFiles) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
}

function Queue-ChatGptCompletion {
    param(
        $Tab,
        [string]$TurnId = ''
    )

    $summaryTitle = Limit-Text ([string]$Tab.Title) 160
    $turnIdValue = Limit-Text $TurnId 80
    $dispatchId = if ([string]::IsNullOrWhiteSpace($turnIdValue)) {
        [string]$Tab.TabId
    }
    else {
        "{0}:{1}" -f $Tab.TabId, $turnIdValue
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $aiTaskComplete `
        -Task $summaryTitle `
        -Status 'RESPONSE_COMPLETE' `
        -Summary '선택한 ChatGPT 탭의 응답 생성이 완료되었습니다.' `
        -NextAction 'REVIEW_RESPONSE' `
        -AgentRole 'ChatGPT Classic' `
        -Source 'chatgpt-web-dom' `
        -Scope 'local_phase' `
        -Outcome 'success' `
        -Project 'ChatGPT' `
        -DispatchId $dispatchId
}

function Find-FocusTab {
    param([string]$TabId, [string]$Url)

    $idValue = Limit-Text $TabId 100
    if (-not [string]::IsNullOrWhiteSpace($idValue) -and $tabs.ContainsKey($idValue)) {
        return $tabs[$idValue]
    }

    $canonical = Get-CanonicalChatGptUrl $Url
    if ([string]::IsNullOrWhiteSpace($canonical)) { return $null }
    $matches = @($tabs.Values | Where-Object { (Get-CanonicalChatGptUrl ([string]$_.Url)) -eq $canonical } | Sort-Object LastSeenUtc -Descending)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Queue-FocusRequest {
    param([string]$TabId, [string]$Url)

    Remove-StaleFocusRequests
    $tab = Find-FocusTab -TabId $TabId -Url $Url
    if ($null -eq $tab) { return $null }

    $requestId = [Guid]::NewGuid().ToString()
    $status = [pscustomobject]@{
        RequestId = $requestId
        TabId = [string]$tab.TabId
        Status = 'pending'
        Error = ''
        CreatedAtUtc = [DateTime]::UtcNow
    }
    $focusStatusById[$requestId] = $status
    $focusRequestsByTab[[string]$tab.TabId] = $requestId
    return $status
}

function Complete-FocusRequest {
    param([string]$RequestId, [string]$TabId, [bool]$Success, [string]$Error)

    $idValue = Limit-Text $RequestId 100
    $tabIdValue = Limit-Text $TabId 100
    if (-not $focusStatusById.ContainsKey($idValue)) { return $false }
    $status = $focusStatusById[$idValue]
    if ([string]$status.TabId -ne $tabIdValue) { return $false }

    if ($Success) {
        $status.Status = 'focused'
        $status.Error = ''
    }
    else {
        $status.Status = 'failed'
        $status.Error = Limit-Text $Error 300
    }
    if ($focusRequestsByTab.ContainsKey($tabIdValue) -and [string]$focusRequestsByTab[$tabIdValue] -eq $idValue) {
        $focusRequestsByTab.Remove($tabIdValue)
    }
    return $true
}

$disabledTabs = Load-DisabledTabs
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "ChatGPT tab manager: http://127.0.0.1:$Port/"
Write-Host '새로 감지된 ChatGPT 탭은 기본 알림 ON이며, 체크 해제한 탭만 제외합니다.'
Write-Host 'Chrome 탭 이벤트 + 비파괴 snapshot으로 감시 목록을 유지합니다.'
Write-Host '응답 내용과 프롬프트는 수집하지 않습니다. 종료: Ctrl+C'

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $request = Read-HttpRequest $stream

            if ([string]::IsNullOrWhiteSpace($request.RequestLine) -or $request.RequestLine -notmatch '^(GET|POST)\s+(\S+)\s+HTTP/') {
                Write-HttpResponse $stream 400 'Bad Request'
                continue
            }

            $method = $Matches[1]
            $target = $Matches[2]
            $clientMarker = ''
            if ($request.Headers.ContainsKey('X-AIWorkerNotifier-Client')) {
                $clientMarker = [string]$request.Headers['X-AIWorkerNotifier-Client']
            }
            $body = [string]$request.Body

            if ($method -eq 'GET' -and ($target -eq '/' -or $target -eq '/manage')) {
                Write-HttpResponse $stream 200 'OK' (Get-ManagementHtml) 'text/html; charset=utf-8'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/manage/select') {
                $enabledTabs = @{}
                foreach ($pair in ($body -split '&')) {
                    if ($pair -match '^tabId=(.+)$') {
                        $id = [Uri]::UnescapeDataString(($Matches[1] -replace '\+', ' '))
                        if ($tabs.ContainsKey($id)) { $enabledTabs[$id] = $true }
                    }
                }

                $newDisabledTabs = @{}
                foreach ($id in @($tabs.Keys)) {
                    if (-not $enabledTabs.ContainsKey($id)) { $newDisabledTabs[$id] = $true }
                }
                $disabledTabs = $newDisabledTabs
                Save-DisabledTabs

                Write-HttpResponse $stream 303 'See Other' '' 'text/plain; charset=utf-8' @{ Location = '/' }
                continue
            }

            if ($clientMarker -eq 'flowduck-adapter') {
                if ($method -eq 'POST' -and $target -eq '/api/tabs/focus') {
                    $data = Parse-JsonBody $body
                    $status = Queue-FocusRequest -TabId ([string]$data.tabId) -Url ([string]$data.url)
                    if ($null -eq $status) {
                        Write-HttpResponse $stream 404 'Not Found' '{"code":"TAB_NOT_FOUND"}' 'application/json; charset=utf-8'
                        continue
                    }
                    $response = @{ requestId = $status.RequestId; tabId = $status.TabId; status = $status.Status } | ConvertTo-Json -Compress
                    Write-HttpResponse $stream 202 'Accepted' $response 'application/json; charset=utf-8'
                    continue
                }

                if ($method -eq 'POST' -and $target -eq '/api/tabs/focus-status') {
                    Remove-StaleFocusRequests
                    $data = Parse-JsonBody $body
                    $requestId = Limit-Text ([string]$data.requestId) 100
                    if (-not $focusStatusById.ContainsKey($requestId)) {
                        Write-HttpResponse $stream 404 'Not Found' '{"code":"FOCUS_REQUEST_NOT_FOUND"}' 'application/json; charset=utf-8'
                        continue
                    }
                    $status = $focusStatusById[$requestId]
                    $response = @{
                        requestId = $status.RequestId
                        tabId = $status.TabId
                        status = $status.Status
                        error = $status.Error
                    } | ConvertTo-Json -Compress
                    Write-HttpResponse $stream 200 'OK' $response 'application/json; charset=utf-8'
                    continue
                }

                Write-HttpResponse $stream 404 'Not Found'
                continue
            }

            if (@('chatgpt-userscript', 'chatgpt-extension') -notcontains $clientMarker) {
                Write-HttpResponse $stream 403 'Forbidden'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/snapshot') {
                $data = Parse-JsonBody $body
                Apply-ChromeTabSnapshot $data.tabs
                Write-HttpResponse $stream 204 'No Content'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/remove') {
                $data = Parse-JsonBody $body
                Remove-ChromeTab ([string]$data.tabId)
                Write-HttpResponse $stream 204 'No Content'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/heartbeat') {
                Remove-StaleFocusRequests
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100
                $title = Limit-Text ([string]$data.title) 200
                $url = Limit-Text ([string]$data.url) 2048
                $windowId = $null
                if ($null -ne $data.windowId) { $windowId = [int]$data.windowId }

                if ([string]::IsNullOrWhiteSpace($id) -or -not (Test-ChatGptUrl $url)) {
                    Write-HttpResponse $stream 400 'Bad Request'
                    continue
                }

                if ($id -like 'chrome-*') {
                    Upsert-ChromeTab -Id $id -WindowId $windowId -Title $title -Url $url -Generating ([bool]$data.generating)
                }
                else {
                    $tabs[$id] = [pscustomobject]@{
                        TabId = $id
                        WindowId = $windowId
                        Title = $title
                        Url = $url
                        Generating = ([bool]$data.generating)
                        LastSeenUtc = [DateTime]::UtcNow
                    }
                }

                $focusRequestId = ''
                if ($focusRequestsByTab.ContainsKey($id)) { $focusRequestId = [string]$focusRequestsByTab[$id] }
                $response = @{
                    selected = (-not $disabledTabs.ContainsKey($id))
                    focusRequestId = $focusRequestId
                } | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'OK' $response 'application/json; charset=utf-8'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/focus-ack') {
                $data = Parse-JsonBody $body
                $accepted = Complete-FocusRequest `
                    -RequestId ([string]$data.requestId) `
                    -TabId ([string]$data.tabId) `
                    -Success ([bool]$data.success) `
                    -Error ([string]$data.error)
                if (-not $accepted) {
                    Write-HttpResponse $stream 404 'Not Found'
                    continue
                }
                Write-HttpResponse $stream 204 'No Content'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/completed') {
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100
                $windowId = $null
                if ($null -ne $data.windowId) { $windowId = [int]$data.windowId }
                Upsert-ChromeTab `
                    -Id $id `
                    -WindowId $windowId `
                    -Title ([string]$data.title) `
                    -Url ([string]$data.url)

                if (-not $tabs.ContainsKey($id) -or $disabledTabs.ContainsKey($id)) {
                    Write-HttpResponse $stream 204 'No Content'
                    continue
                }

                $tab = $tabs[$id]
                Write-CompletionJournal -Tab $tab -Data $data
                Queue-ChatGptCompletion -Tab $tab -TurnId (Limit-Text ([string]$data.turnId) 80)
                Write-HttpResponse $stream 204 'No Content'
                Write-Host ("[{0}] 활성 탭 완료 알림 큐 등록: {1}" -f (Get-Date -Format 'HH:mm:ss'), $tab.Title)
                continue
            }

            Write-HttpResponse $stream 404 'Not Found'
        }
        catch {
            try { Write-HttpResponse $stream 500 'Internal Server Error' } catch { }
            Write-Warning ("Bridge request failed: {0}" -f $_.Exception.Message)
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}
