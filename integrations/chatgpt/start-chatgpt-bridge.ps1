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
$tabTtlSeconds = 10
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
        $raw = [System.IO.File]::ReadAllText($selectionPath, $utf8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $items = $raw | ConvertFrom-Json
        $result = @{}
        foreach ($item in @($items)) {
            $id = Limit-Text ([string]$item) 100
            if (-not [string]::IsNullOrWhiteSpace($id)) { $result[$id] = $true }
        }
        return $result
    } catch {
        Write-Warning ("ChatGPT 탭 선택 상태를 읽지 못했습니다: {0}" -f $_.Exception.Message)
        return @{}
    }
}

function Save-Selections {
    $ids = @($selectedTabs.Keys | Sort-Object)
    [System.IO.File]::WriteAllText($selectionPath, ($ids | ConvertTo-Json), $utf8)
}

function Remove-StaleTabs {
    $cutoff = [DateTime]::UtcNow.AddSeconds(-1 * $tabTtlSeconds)
    foreach ($id in @($tabs.Keys)) {
        if ($tabs[$id].LastSeenUtc -lt $cutoff) { $tabs.Remove($id) }
    }
}

function Test-ChatGptUrl {
    param([string]$Url)
    try {
        $uri = [Uri]$Url
        return $uri.Scheme -eq 'https' -and @('chatgpt.com', 'chat.openai.com') -contains $uri.Host
    } catch { return $false }
}

function HtmlEncode {
    param([AllowNull()][string]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-ManagementHtml {
    Remove-StaleTabs
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($tab in @($tabs.Values | Sort-Object Title, Url)) {
        $checked = if ($selectedTabs.ContainsKey($tab.TabId)) { ' checked' } else { '' }
        $state = if ($tab.Generating) { '응답 생성 중' } else { '대기 중' }
        $shortId = if ($tab.TabId.Length -gt 8) { $tab.TabId.Substring(0, 8) } else { $tab.TabId }
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
        '<p class="empty">현재 감지된 ChatGPT 탭이 없습니다. ChatGPT 탭을 열고 userscript가 활성화되어 있는지 확인하세요.</p>'
    } else { $rows -join "`n" }

    return @"
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>AIWorkerNotifier - ChatGPT 탭</title>
<style>
body{font-family:Segoe UI,Malgun Gothic,sans-serif;max-width:980px;margin:40px auto;padding:0 20px;color:#202124;background:#f7f8fa}h1{margin-bottom:8px}.hint{color:#5f6368;margin-top:0}.panel{background:white;border:1px solid #dadce0;border-radius:12px;padding:18px}.tab-row{display:grid;grid-template-columns:28px 1fr 110px 80px;gap:12px;align-items:center;padding:14px 8px;border-bottom:1px solid #eee}.tab-row:last-child{border-bottom:0}.tab-main{min-width:0}.tab-main strong,.tab-main small{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tab-main small{color:#70757a;margin-top:4px}.state{font-size:13px;color:#5f6368}.actions{margin-top:18px;display:flex;gap:10px;align-items:center}button{border:0;border-radius:8px;padding:10px 16px;font-weight:600;cursor:pointer}button.primary{background:#1a73e8;color:white}.empty{color:#70757a;padding:12px}.privacy{font-size:13px;color:#70757a;margin-top:18px}code{font-size:12px}
</style>
</head>
<body>
<h1>ChatGPT 탭 감시</h1>
<p class="hint">열려 있는 ChatGPT 탭 중 완료 알림을 받을 탭을 선택하세요. 목록은 약 5초마다 갱신됩니다.</p>
<form method="POST" action="/manage/select" class="panel">
$listHtml
<div class="actions"><button class="primary" type="submit">선택 저장</button><span>선택되지 않은 탭의 완료 이벤트는 무시됩니다.</span></div>
</form>
<p class="privacy">AIWorkerNotifier는 탭 제목, ChatGPT URL, 생성 중 여부만 받습니다. 응답 본문과 입력한 프롬프트는 읽거나 전송하지 않습니다.</p>
</body>
</html>
"@
}

function Write-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$Body = '',
        [string]$ContentType = 'text/plain; charset=utf-8',
        [hashtable]$ExtraHeaders = @{}
    )
    $bodyBytes = $utf8.GetBytes($Body)
    $headers = New-Object System.Collections.Generic.List[string]
    $headers.Add("HTTP/1.1 $StatusCode $StatusText")
    $headers.Add('Connection: close')
    $headers.Add('Cache-Control: no-store')
    $headers.Add("Content-Type: $ContentType")
    $headers.Add("Content-Length: $($bodyBytes.Length)")
    foreach ($entry in $ExtraHeaders.GetEnumerator()) { $headers.Add("$($entry.Key): $($entry.Value)") }
    $headers.Add('')
    $headers.Add('')
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n"))
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

function Read-RequestBody {
    param([System.IO.StreamReader]$Reader, [int]$ContentLength)
    if ($ContentLength -le 0) { return '' }
    if ($ContentLength -gt 16384) { throw 'request body too large' }
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
    try { return $Body | ConvertFrom-Json } catch { throw 'invalid JSON body' }
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
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "ChatGPT tab manager: http://127.0.0.1:$Port/"
Write-Host 'ChatGPT 탭을 감지하면 위 주소에서 감시 대상을 선택할 수 있습니다.'
Write-Host '응답 내용과 프롬프트는 수집하지 않습니다. 종료: Ctrl+C'

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 2048, $true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine) -or $requestLine -notmatch '^(GET|POST)\s+(\S+)\s+HTTP/') {
                Write-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request'; continue
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
            $body = Read-RequestBody -Reader $reader -ContentLength $contentLength

            if ($method -eq 'GET' -and ($target -eq '/' -or $target -eq '/manage')) {
                Write-HttpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -Body (Get-ManagementHtml) -ContentType 'text/html; charset=utf-8'; continue
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
                Write-HttpResponse -Stream $stream -StatusCode 303 -StatusText 'See Other' -ExtraHeaders @{ Location = '/' }; continue
            }

            if ($clientMarker -ne 'chatgpt-userscript') {
                Write-HttpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden'; continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/heartbeat') {
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100
                $title = Limit-Text ([string]$data.title) 200
                $url = Limit-Text ([string]$data.url) 2048
                if ([string]::IsNullOrWhiteSpace($id) -or -not (Test-ChatGptUrl $url)) {
                    Write-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request'; continue
                }
                $isNew = -not $tabs.ContainsKey($id)
                $tabs[$id] = [pscustomobject]@{ TabId=$id; Title=$title; Url=$url; Generating=([bool]$data.generating); LastSeenUtc=[DateTime]::UtcNow }
                if ($isNew) { Write-Host ("[{0}] ChatGPT 탭 감지: {1}" -f (Get-Date -Format 'HH:mm:ss'), $title) }
                $response = @{ selected = $selectedTabs.ContainsKey($id) } | ConvertTo-Json -Compress
                Write-HttpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -Body $response -ContentType 'application/json; charset=utf-8'; continue
            }

            if ($method -eq 'POST' -and $target -eq '/api/tabs/completed') {
                $data = Parse-JsonBody $body
                $id = Limit-Text ([string]$data.tabId) 100
                if (-not $tabs.ContainsKey($id) -or -not $selectedTabs.ContainsKey($id)) {
                    Write-HttpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content'; continue
                }
                $tab = $tabs[$id]
                Queue-ChatGptCompletion -Tab $tab
                Write-HttpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content'
                Write-Host ("[{0}] 선택 탭 완료 알림 큐 등록: {1}" -f (Get-Date -Format 'HH:mm:ss'), $tab.Title)
                continue
            }

            Write-HttpResponse -Stream $stream -StatusCode 404 -StatusText 'Not Found'
        } catch {
            try { Write-HttpResponse -Stream $stream -StatusCode 500 -StatusText 'Internal Server Error' } catch { }
            Write-Warning ("Bridge request failed: {0}" -f $_.Exception.Message)
        } finally { $client.Close() }
    }
} finally { $listener.Stop() }
