[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$payloadHelper = Join-Path $root 'bin\DiscordPayload.ps1'
$cliInternal = Join-Path $root 'bin\ai-task-complete.internal.ps1'
$notifierInternal = Join-Path $root 'bin\AIWorkerNotifier.internal.ps1'
. $payloadHelper

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------
foreach ($file in @(
    $payloadHelper,
    $cliInternal,
    $notifierInternal,
    (Join-Path $root 'scripts\manage-setup.ps1')
)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors -and $errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Host $_ }
        throw "PowerShell parse failed: $file"
    }
}
Write-Host 'PASS: PowerShell parser'

# ---------------------------------------------------------------------------
# Role ID validation
# ---------------------------------------------------------------------------
Assert-True (Test-DiscordMentionRoleId '123456789012345678') 'valid role rejected'
Assert-True (-not (Test-DiscordMentionRoleId 'role-name')) 'role name accepted'
Assert-True (-not (Test-DiscordMentionRoleId '<@&123456789012345678>')) 'markup accepted'
Assert-True (-not (Test-DiscordMentionRoleId 'https://discord.com/api/webhooks/1/abc')) 'webhook accepted'

$rejected = $false
try { [void](ConvertTo-DiscordMentionRoleId -Value '<@&123456789012345678>') } catch { $rejected = $true }
Assert-True $rejected 'markup convert not rejected'

$rejected = $false
try { [void](ConvertTo-DiscordMentionRoleId -Value 'AI-Worker-Notify') } catch { $rejected = $true }
Assert-True $rejected 'role name convert not rejected'
Write-Host 'PASS: role ID validation'

# ---------------------------------------------------------------------------
# Payload without role ID (legacy behavior)
# ---------------------------------------------------------------------------
$korean = '원본 워크플로 문서 라우터와 지연 로드 구조를 반영'
$message = "✅ AI Worker 상태`n`nSummary: $korean @everyone @here <@&999> <@111>"
$plain = New-DiscordWebhookPayloadObject -Message $message -RoleId $null
Assert-True ($plain.content -eq $message) 'plain content changed'
Assert-True (-not ($plain.Keys -contains 'allowed_mentions')) 'allowed_mentions unexpectedly present'
Assert-True ($plain.content -notmatch '^<@&') 'plain content started with mention'
$plainJson = [Text.Encoding]::UTF8.GetString((ConvertTo-Utf8JsonBytes -PayloadObject $plain))
Assert-True ($plainJson -notmatch 'allowed_mentions') 'plain JSON includes allowed_mentions'
$plainBytes = ConvertTo-Utf8JsonBytes -PayloadObject $plain
Assert-True ($plainBytes -is [byte[]]) 'ConvertTo-Utf8JsonBytes must return byte[] (not Object[])'
Write-Host 'PASS: payload without role ID'

# ---------------------------------------------------------------------------
# Payload with role ID
# ---------------------------------------------------------------------------
$roleId = '123456789012345678'
$withRole = New-DiscordWebhookPayloadObject -Message $message -RoleId $roleId
Assert-True ($withRole.content.StartsWith("<@&$roleId>")) 'content missing role mention prefix'
Assert-True ($withRole.content.Contains($korean)) 'korean summary lost in content'
Assert-True (@($withRole.allowed_mentions.parse).Count -eq 0) 'parse must be empty'
$roles = @($withRole.allowed_mentions.roles)
Assert-True ($roles.Count -eq 1 -and $roles[0] -eq $roleId) 'roles must contain only configured ID'
$withJson = [Text.Encoding]::UTF8.GetString((ConvertTo-Utf8JsonBytes -PayloadObject $withRole))
Assert-True ($withJson -match '"parse"\s*:\s*\[\s*\]') 'JSON parse must be []'
Assert-True ($withJson -match ('"roles"\s*:\s*\[\s*"' + [regex]::Escape($roleId) + '"\s*\]')) 'JSON roles must be single-id array'
Write-Host 'PASS: payload with role ID + allowed_mentions'

# ---------------------------------------------------------------------------
# Payload with user mention / @everyone
# ---------------------------------------------------------------------------
$userId = '987654321098765432'
$withUser = New-DiscordWebhookPayloadObject -Message $message -UserId $userId
Assert-True ($withUser.content.StartsWith("<@$userId>")) 'content missing user mention prefix'
Assert-True (@($withUser.allowed_mentions.parse).Count -eq 0) 'user parse must be empty'
$users = @($withUser.allowed_mentions.users)
Assert-True ($users.Count -eq 1 -and $users[0] -eq $userId) 'users must contain only configured ID'
$userJson = [Text.Encoding]::UTF8.GetString((ConvertTo-Utf8JsonBytes -PayloadObject $withUser))
Assert-True ($userJson -match ('"users"\s*:\s*\[\s*"' + [regex]::Escape($userId) + '"\s*\]')) 'JSON users must be single-id array'
Assert-True ($userJson -notmatch '"roles"') 'user payload must not include roles'

$withEveryone = New-DiscordWebhookPayloadObject -Message $message -MentionEveryone
Assert-True ($withEveryone.content.StartsWith('@everyone')) 'content missing @everyone prefix'
Assert-True (@($withEveryone.allowed_mentions.parse)[0] -eq 'everyone') 'parse must include everyone'
$everyoneJson = [Text.Encoding]::UTF8.GetString((ConvertTo-Utf8JsonBytes -PayloadObject $withEveryone))
Assert-True ($everyoneJson -match '"parse"\s*:\s*\[\s*"everyone"\s*\]') 'JSON parse must be ["everyone"]'
Assert-True ($everyoneJson -notmatch '"roles"') 'everyone payload must not include roles'
Assert-True ($everyoneJson -notmatch '"users"') 'everyone payload must not include users'
Write-Host 'PASS: user + @everyone mentions'

# ---------------------------------------------------------------------------
# UTF-8 JSON round-trip (PowerShell -> JSON bytes -> object)
# ---------------------------------------------------------------------------
$bytes = ConvertTo-Utf8JsonBytes -PayloadObject $withRole
$roundTrip = ConvertFrom-Utf8JsonBytes -Bytes $bytes
Assert-True ($roundTrip.content -match [regex]::Escape($korean)) 'korean lost after UTF-8 JSON round-trip'
Assert-True ($roundTrip.content -match [regex]::Escape("<@&$roleId>")) 'mention lost after round-trip'
Assert-True (@($roundTrip.allowed_mentions.parse).Count -eq 0) 'parse not empty after round-trip'
Assert-True (@($roundTrip.allowed_mentions.roles)[0].ToString() -eq $roleId) 'role id lost after round-trip'
# @everyone remains as text in content but is not enabled via parse
Assert-True ($roundTrip.content -match '@everyone') 'summary @everyone text should remain as text'
Write-Host 'PASS: UTF-8 JSON round-trip'

# ---------------------------------------------------------------------------
# Event creation smoke (uses .internal.ps1; no live Discord)
# ---------------------------------------------------------------------------
$runtime = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIWorkerNotifier'
$inbox = Join-Path $runtime 'inbox'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null

& $cliInternal `
    -Task 'UNIT-SMOKE' `
    -Status 'LOCAL_IMPLEMENTED' `
    -Summary '한글 이벤트 생성 시험' `
    -NextAction 'DRY_RUN_PROCESS' `
    -Tests '1 passed' `
    -AgentRole 'TEST' `
    -Source 'test-script' `
    -Scope 'task' `
    -DispatchId ('unit-smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))

$file = Get-ChildItem -LiteralPath $inbox -Filter '*.json' -File |
    Sort-Object CreationTimeUtc -Descending |
    Select-Object -First 1
if ($null -eq $file) { throw '이벤트 파일이 생성되지 않았습니다.' }

$eventJson = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false))
$event = $eventJson | ConvertFrom-Json
Assert-True ($event.schemaVersion -eq 1) 'schemaVersion 불일치'
Assert-True ($event.task -eq 'UNIT-SMOKE') 'task 불일치'
Assert-True ($event.summary -eq '한글 이벤트 생성 시험') 'UTF-8 summary 불일치'
if (Get-ChildItem -LiteralPath $inbox -Filter '*.tmp' -File -ErrorAction SilentlyContinue) {
    throw 'tmp 파일이 남았습니다.'
}

& $notifierInternal -DryRun -Once -Backlog
Write-Host 'PASS: event creation + dry-run processing'

Write-Host 'PASS: all AIWorkerNotifier tests'
