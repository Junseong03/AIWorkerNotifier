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
$selectionPath = Join-Path $stateRoot 'chatgpt-selected-tabs.json'
$legacyTabTtlSeconds = 30
$tabs = @{}
$selectedTabs = @{}

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

function Load-Selections {
    if (-not (Test-Path -LiteralPath $selectionPath)) { return @{} }
    try {
        $raw = [IO.File]::ReadAllText($selectionPath, $utf8)
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
        Write-Warning ("ChatGPT 탭 선택 상태를 읽지 못했습니다: {0}" -f $_.Exception.Message)
        return @{}
    }
}

function Save-Selections {
    $ids = @($selectedTabs.Keys | Sort-Object)
    [IO.File]::WriteAllText($selectionPath, ($ids | ConvertTo-Json), $utf8)
}

function Remove-StaleLegacyTabs {
    # Chrome extension 탭은 heartbeat TTL로 삭제하지 않는다.
    # Chrome snapshot에 실제로 존재하지 않을 때만 제거한다.
    $cutoff = [DateTime]::UtcNow.AddSeconds(-1 * $legacyTabTtlSeconds)
    foreach ($id in @($tabs.Keys)) {
        if ($id -like 'chrome-*') { continue }
        if ($tabs[$id].LastSeenUtc -lt $cutoff) { $tabs.Remove($id) }
    }
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

function Apply-ChromeTabSnapshot {
    param($SnapshotTabs)

    $snapshotIds = @{}
    foreach ($item in @($SnapshotTabs)) {
        $id = Limit-Text ([string]$item.tabId) 100
        $title = Limit-Text ([string]$item.title) 200
        $url = Limit-Text ([string]$item.url) 2048

        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($id -notlike 'chrome-*') { continue }
        if (-not (Test-ChatGptUrl $url)) { continue }

        $snapshotIds[$id] = $true
        $generating = $false
        if ($tabs.ContainsKey($id)) {
            $generating = [bool]$tabs[$id].Generating
        }

        $tabs[$id] = [pscustomobject]@{
            TabId = $id
            Title = $title
            Url = $url
            Generating = $generating
            LastSeenUtc = [DateTime]::UtcNow
        }
    }

    $selectionChanged = $false
    foreach ($id in @($tabs.Keys)) {
        if ($id -notlike 'chrome-*') { continue }
        if ($snapshotIds.ContainsKey($id)) { continue }

        $tabs.Remove($id)
        if ($selectedTabs.ContainsKey($id)) {
            $selectedTabs.Remove($id)
            $selectionChanged = $true
        }
    }

    if ($selectionChanged) { Save-Selections }
}

function Get-ManagementHtml {
    Remove-StaleLegacyTabs
    $rows = New-Object Collections.Generic.List[string]

    foreach ($tab in @($tabs.Values | Sort-Object Title, Url)) {
        $checked = if ($selectedTabs.ContainsKey($tab.TabId)) { ' checked' } else { '' }
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
<p class="hint">Chrome이 보고한 현재 열린 ChatGPT 탭 중 완료 알림을 받을 탭을 선택하세요. 목록은 약 5초마다 갱신됩니다.</p>
<form method="POST" action="/manage/select" class="panel">
$listHtml
<div class="actions"><button class="primary" type="submit">선택 저장</button><span>선택되지 않은 탭의 완료 이벤트는 무시됩니다.</span></div>
</form>
<p class="privacy">탭 존재 여부는 Chrome의 열린 탭 목록으로 판단합니다. DOM 감시는 생성 중/완료 상태만 확인하며 응답 본문과 입력한 프롬프트는 읽거나 전송하지 않습니다.</p>
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

function Read-RequestBody {
    param([IO.StreamReader]$Reader, [int]$ContentLength)
    if ($ContentLength -le 0) { return '' }
    if ($ContentLength -gt 65536) { throw 'request body too large' }

    $buffer = New-Object char[] $ContentLength
    $read = 0
    while ($read -lt $ContentLength) {
        $count = $Reader.Read($buffer, $read, $ContentLength - $read)
        if ($count -le 0) { break }
        $read += $count
    }
    return New-Object string($buffer, 0, $read)
}

function Parse-JsonBody {
    param([string]$Body)
    try { return $Body | ConvertFrom-Json }
    catch { throw 'invalid JSON body' }
}

function Queue-ChatGptCompletion {
    param($Tab)
    $summaryTitle = Limit-Text ([string]$Tab.Title) 160
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
        -DispatchId $Tab.TabId
}

$selectedTabs = Load-Selections
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "ChatGPT tab manager: http://127.0.0.1:$Port/"
Write-Host 'Chrome 확장 프로그램의 열린 탭 snapshot을 기준으로 감시 목록을 유지합니다.'
Write-Host '응답 내용과 프롬프트는 수집하지 않습니다. 종료: Ctrl+C'

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $false, 2048, $true)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine) -or $requestLine -notmatch '^(GET|POST)\s+(\S+)\s+HTTP/') {
                Write-HttpResponse $stream 400 'Bad Request'
                continue
            }

            $method = $Matches[1]
            $target = $Matches[2]
            $contentLength = 0
            $clientMarker = ''

            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line.Length -eq 0) { break }
                $separator = $line.IndexOf(':')
                if ($separator -le 0) { continue }
                $name = $line.Substring(0, $separator).Trim()
                $value = $line.Substring($separator + 1).Trim()
                if ($name -ieq 'Content-Length') { [void][int]::TryParse($value, [ref]$contentLength) }
                if ($name -ieq 'X-AIWorkerNotifier-Client') { $clientMarker = $value }
            }

            $body = Read-RequestBody $reader $contentLength

            if ($method -eq 'GET' -and ($target -eq '/' -or $target -eq '/manage')) {
                Write-HttpResponse $stream 200 'OK' (Get-ManagementHtml) 'text/html; charset=utf-8'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/manage/select') {
                $newSelection = @{}
                foreach ($pair in ($body -split '&')) {
                    if ($pair -match '^tabId=(.+)$') {
                        $id = [Uri]::UnescapeDataString(($Matches[1] -replace '\+', ' '))
                        if ($tabs.ContainsKey($id)) { $newSelection[$id] = $true }
                    }
                }
                $selectedTabs = $newSelection
                Save-Selections
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

            if ($method -eq 'POST' -and $target -eq '/api/tabs/heartbeat') {
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100
                $title = Limit-Text ([string]$data.title) 200
                $url = Limit-Text ([string]$data.url) 2048

                if ([string]::IsNullOrWhiteSpace($id) -or -not (Test-ChatGptUrl $url)) {
                    Write-HttpResponse $stream 400 'Bad Request'
                    continue
                }

                $tabs[$id] = [pscustomobject]@{
                    TabId = $id
                    Title = $title
                    Url = $url
                    Generating = ([bool]$data.generating)
                    LastSeenUtc = [DateTime]::UtcNow
                }

                $response = @{ selected = $selectedTabs.ContainsKey($id) } | ConvertTo-Json -Compress
                Write-HttpResponse $stream 200 'OK' $response 'application/json; charset=utf-8'
                continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/completed') {
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100

                if (-not $tabs.ContainsKey($id) -or -not $selectedTabs.ContainsKey($id)) {
                    Write-HttpResponse $stream 204 'No Content'
                    continue
                }

                $tab = $tabs[$id]
                Queue-ChatGptCompletion $tab
                Write-HttpResponse $stream 204 'No Content'
                Write-Host ("[{0}] 선택 탭 완료 알림 큐 등록: {1}" -f (Get-Date -Format 'HH:mm:ss'), $tab.Title)
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
