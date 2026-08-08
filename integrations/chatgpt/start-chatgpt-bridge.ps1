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
$legacyTabTtlSeconds = 30
$tabs = @{}
$disabledTabs = @{}

if (-not (Test-Path -LiteralPath $aiTaskComplete)) {
    throw "ai-task-complete 진입점을 찾을 수 없습니다: $aiTaskComplete"
}
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

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

function Test-ChatGptUrl {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        return $uri.Scheme -eq 'https' -and @('chatgpt.com', 'chat.openai.com') -contains $uri.Host
    }
    catch { return $false }
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
        [Nullable[bool]]$Generating = $null
    )

    $idValue = Limit-Text $Id 100
    $titleValue = Limit-Text $Title 200
    $urlValue = Limit-Text $Url 2048

    if ([string]::IsNullOrWhiteSpace($idValue)) { return }
    if ($idValue -notlike 'chrome-*') { return }
    if (-not (Test-ChatGptUrl $urlValue)) { return }

    $generatingValue = $false
    if ($tabs.ContainsKey($idValue)) {
        $generatingValue = [bool]$tabs[$idValue].Generating
    }
    if ($null -ne $Generating) {
        $generatingValue = [bool]$Generating
    }

    $tabs[$idValue] = [pscustomobject]@{
        TabId = $idValue
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
        Upsert-ChromeTab `
            -Id ([string]$item.tabId) `
            -Title ([string]$item.title) `
            -Url ([string]$item.url)
    }
}

function Remove-ChromeTab {
    param([string]$Id)

    $idValue = Limit-Text $Id 100
    if ([string]::IsNullOrWhiteSpace($idValue)) { return }
    if ($idValue -notlike 'chrome-*') { return }

    if ($tabs.ContainsKey($idValue)) {
        $tabs.Remove($idValue)
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
        # 새로 감지된 탭은 기본 ON. 사용자가 명시적으로 체크 해제한 탭만 disabledTabs에 저장한다.
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
    foreach ($entry in $ExtraHeaders.GetEnumerator()) {
        $headers.Add("$($entry.Key): $($entry.Value)")
    }
    $headers.Add('')
    $headers.Add('')

    $headerBytes = [Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n"))
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

function Read-HttpRequest {
    param([IO.Stream]$Stream)

    # HTTP Content-Length는 문자 수가 아니라 바이트 수다.
    # StreamReader로 UTF-8 문자를 Content-Length개 읽으면 한국어 제목이 포함된 JSON에서
    # body 경계가 틀어질 수 있으므로, 헤더와 body를 모두 원시 바이트 기준으로 읽는다.
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
            ) {
                break
            }
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
    if ($contentLength -lt 0 -or $contentLength -gt 65536) {
        throw 'request body too large'
    }

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
                    if (-not $enabledTabs.ContainsKey($id)) {
                        $newDisabledTabs[$id] = $true
                    }
                }
                $disabledTabs = $newDisabledTabs
                Save-DisabledTabs

                Write-HttpResponse $stream 303 'See Other' '' 'text/plain; charset=utf-8' @{ Location = '/' }
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
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100
                $title = Limit-Text ([string]$data.title) 200
                $url = Limit-Text ([string]$data.url) 2048

                if ([string]::IsNullOrWhiteSpace($id) -or -not (Test-ChatGptUrl $url)) {
                    Write-HttpResponse $stream 400 'Bad Request'
                    continue
                }

                if ($id -like 'chrome-*') {
                    Upsert-ChromeTab -Id $id -Title $title -Url $url -Generating ([bool]$data.generating)
                }
                else {
                    $tabs[$id] = [pscustomobject]@{
                        TabId = $id
                        Title = $title
                        Url = $url
                        Generating = ([bool]$data.generating)
                        LastSeenUtc = [DateTime]::UtcNow
                    }
                }

                $response = @{ selected = (-not $disabledTabs.ContainsKey($id)) } | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'OK' $response 'application/json; charset=utf-8'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/completed') {
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100
                $turnId = Limit-Text ([string]$data.turnId) 80

                if (-not $tabs.ContainsKey($id) -or $disabledTabs.ContainsKey($id)) {
                    Write-HttpResponse $stream 204 'No Content'
                    continue
                }

                $tab = $tabs[$id]
                Queue-ChatGptCompletion -Tab $tab -TurnId $turnId
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
