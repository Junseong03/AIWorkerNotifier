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

if (-not (Test-Path -LiteralPath $aiTaskComplete)) {
    throw "ai-task-complete 진입점을 찾을 수 없습니다: $aiTaskComplete"
}

$allowedOrigins = @(
    'https://chatgpt.com',
    'https://chat.openai.com'
)

function Write-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$Origin = '',
        [string]$Body = ''
    )

    $bodyBytes = $utf8.GetBytes($Body)
    $headers = New-Object System.Collections.Generic.List[string]
    $headers.Add("HTTP/1.1 $StatusCode $StatusText")
    $headers.Add('Connection: close')
    $headers.Add('Cache-Control: no-store')
    $headers.Add('Content-Type: text/plain; charset=utf-8')
    $headers.Add("Content-Length: $($bodyBytes.Length)")
    if (-not [string]::IsNullOrWhiteSpace($Origin)) {
        $headers.Add("Access-Control-Allow-Origin: $Origin")
        $headers.Add('Vary: Origin')
        $headers.Add('Access-Control-Allow-Methods: POST, OPTIONS')
        $headers.Add('Access-Control-Allow-Headers: Content-Type')
    }
    $headers.Add('')
    $headers.Add('')

    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n"))
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Queue-ChatGptCompletion {
    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $aiTaskComplete `
        -Task 'ChatGPT Classic' `
        -Status 'RESPONSE_COMPLETE' `
        -Summary 'ChatGPT 응답 생성이 완료되었습니다.' `
        -NextAction 'REVIEW_RESPONSE' `
        -AgentRole 'ChatGPT Classic' `
        -Source 'chatgpt-web-dom' `
        -Scope 'local_phase' `
        -Outcome 'success' `
        -Project 'ChatGPT'
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "ChatGPT completion bridge listening on http://127.0.0.1:$Port/"
Write-Host 'DOM의 응답 내용은 수집하지 않습니다. 생성 중 -> 완료 상태 전이만 받습니다.'
Write-Host '종료: Ctrl+C'

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) {
                Write-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request'
                continue
            }

            $origin = ''
            $contentLength = 0
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line.Length -eq 0) { break }

                $separator = $line.IndexOf(':')
                if ($separator -le 0) { continue }
                $name = $line.Substring(0, $separator).Trim()
                $value = $line.Substring($separator + 1).Trim()
                if ($name -ieq 'Origin') { $origin = $value }
                if ($name -ieq 'Content-Length') {
                    $parsedLength = 0
                    if ([int]::TryParse($value, [ref]$parsedLength)) { $contentLength = $parsedLength }
                }
            }

            $originAllowed = $allowedOrigins -contains $origin
            if (-not $originAllowed) {
                Write-HttpResponse -Stream $stream -StatusCode 403 -StatusText 'Forbidden'
                continue
            }

            if ($requestLine -match '^OPTIONS\s+/ai-worker-notifier/chatgpt/completed\s+HTTP/') {
                Write-HttpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -Origin $origin
                continue
            }

            if ($requestLine -notmatch '^POST\s+/ai-worker-notifier/chatgpt/completed\s+HTTP/') {
                Write-HttpResponse -Stream $stream -StatusCode 404 -StatusText 'Not Found' -Origin $origin
                continue
            }

            if ($contentLength -lt 0 -or $contentLength -gt 1024) {
                Write-HttpResponse -Stream $stream -StatusCode 413 -StatusText 'Payload Too Large' -Origin $origin
                continue
            }

            if ($contentLength -gt 0) {
                $buffer = New-Object char[] $contentLength
                $read = 0
                while ($read -lt $contentLength) {
                    $count = $reader.Read($buffer, $read, $contentLength - $read)
                    if ($count -le 0) { break }
                    $read += $count
                }
                # 본문은 이벤트 종류 확인용이며 ChatGPT 응답 내용은 받지 않는다.
                $body = New-Object string($buffer, 0, $read)
                if ($body.Trim() -ne 'response-complete') {
                    Write-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -Origin $origin
                    continue
                }
            } else {
                Write-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -Origin $origin
                continue
            }

            try {
                Queue-ChatGptCompletion
                Write-HttpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -Origin $origin
                Write-Host ("[{0}] ChatGPT response completion queued." -f (Get-Date -Format 'HH:mm:ss'))
            } catch {
                Write-Warning ("ChatGPT completion event queue failed: {0}" -f $_.Exception.Message)
                Write-HttpResponse -Stream $stream -StatusCode 500 -StatusText 'Internal Server Error' -Origin $origin
            }
        } catch {
            Write-Warning ("Bridge request failed: {0}" -f $_.Exception.Message)
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
