Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# AI Worker Notifier setup menu
#
# UTF-8 console encoding + Korean UI.
# Save this file as UTF-8 with BOM for Windows PowerShell 5.1.
# ---------------------------------------------------------------------------

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$ScriptDirectory = $PSScriptRoot
$ApplicationRoot = Split-Path -Parent $ScriptDirectory
$BinDirectory = Join-Path $ApplicationRoot 'bin'

$CliCommandFile = Join-Path $BinDirectory 'ai-task-complete.cmd'
$NotifierCommandFile = Join-Path $BinDirectory 'AIWorkerNotifier.cmd'
$NotifierInternalFile = Join-Path $BinDirectory 'AIWorkerNotifier.internal.ps1'

$RuntimeRoot = Join-Path $env:LOCALAPPDATA 'AIWorkerNotifier'
$StateDirectory = Join-Path $RuntimeRoot 'state'
$WebhookFile = Join-Path $StateDirectory 'discord-webhook.dpapi'
$MentionRoleFile = Join-Path $StateDirectory 'discord-mention-role.id'
$PayloadHelperPath = Join-Path $BinDirectory 'DiscordPayload.ps1'

. $PayloadHelperPath

function Pause-Setup {
    Write-Host
    [void](Read-Host '계속하려면 Enter를 누르세요')
}

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
        return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    }
    catch {
        return $Path.Trim().TrimEnd('\')
    }
}

function Get-UserPathEntries {
    $currentPath = [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )

    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        return @()
    }

    return @(
        $currentPath.Split(';') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-BinPathRegistered {
    $target = Get-NormalizedPath -Path $BinDirectory

    foreach ($entry in Get-UserPathEntries) {
        $normalizedEntry = Get-NormalizedPath -Path $entry

        if ($normalizedEntry -ieq $target) {
            return $true
        }
    }

    return $false
}

function Add-BinPath {
    if (-not (Test-Path -LiteralPath $BinDirectory -PathType Container)) {
        throw "bin 디렉터리가 없습니다: $BinDirectory"
    }

    if (-not (Test-Path -LiteralPath $CliCommandFile -PathType Leaf)) {
        throw "필요한 명령을 찾지 못했습니다: $CliCommandFile"
    }

    if (-not (Test-Path -LiteralPath $NotifierCommandFile -PathType Leaf)) {
        throw "필요한 명령을 찾지 못했습니다: $NotifierCommandFile"
    }

    if (Test-BinPathRegistered) {
        Write-Host
        Write-Host '[INFO] 명령 디렉터리가 이미 사용자 PATH에 등록되어 있습니다.'
        Write-Host "       $BinDirectory"
        return
    }

    $entries = [Collections.Generic.List[string]]::new()

    foreach ($entry in Get-UserPathEntries) {
        $entries.Add($entry)
    }

    $entries.Add($BinDirectory)

    $newPath = $entries -join ';'

    [Environment]::SetEnvironmentVariable(
        'Path',
        $newPath,
        [EnvironmentVariableTarget]::User
    )

    Write-Host
    Write-Host '[OK] 명령 디렉터리를 사용자 PATH에 등록했습니다.'
    Write-Host "     $BinDirectory"
    Write-Host
    Write-Host '적용하려면 새 PowerShell 또는 Cursor CLI 세션을 여세요.'
}

function Remove-BinPath {
    $target = Get-NormalizedPath -Path $BinDirectory
    $remainingEntries = [Collections.Generic.List[string]]::new()
    $removedCount = 0

    foreach ($entry in Get-UserPathEntries) {
        $normalizedEntry = Get-NormalizedPath -Path $entry

        if ($normalizedEntry -ieq $target) {
            $removedCount++
            continue
        }

        $remainingEntries.Add($entry)
    }

    if ($removedCount -eq 0) {
        Write-Host
        Write-Host '[INFO] 명령 디렉터리가 사용자 PATH에 등록되어 있지 않습니다.'
        return
    }

    $newPath = $remainingEntries -join ';'

    [Environment]::SetEnvironmentVariable(
        'Path',
        $newPath,
        [EnvironmentVariableTarget]::User
    )

    Write-Host
    Write-Host '[OK] 사용자 PATH에서 명령 디렉터리를 제거했습니다.'
    Write-Host "     $BinDirectory"
    Write-Host
    Write-Host '프로그램 파일과 런타임 데이터는 삭제되지 않았습니다.'
    Write-Host '적용하려면 새 PowerShell 또는 Cursor CLI 세션을 여세요.'
}

function Test-DiscordWebhookUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $uri = $null

    if (-not [Uri]::TryCreate(
        $Value,
        [UriKind]::Absolute,
        [ref]$uri
    )) {
        return $false
    }

    if ($uri.Scheme -ine 'https') {
        return $false
    }

    $validHosts = @(
        'discord.com',
        'discordapp.com'
    )

    if ($validHosts -inotcontains $uri.Host) {
        return $false
    }

    if ($uri.AbsolutePath -notmatch '^/api/webhooks/[0-9]+/[A-Za-z0-9._-]+/?$') {
        return $false
    }

    if (-not [string]::IsNullOrEmpty($uri.Query)) {
        return $false
    }

    if (-not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $false
    }

    return $true
}

function Set-DiscordWebhook {
    Write-Host
    Write-Host 'Webhook URL은 입력 중 화면에 표시되지 않습니다.'
    Write-Host '현재 Windows 사용자 범위 DPAPI로 암호화되어 저장됩니다.'
    Write-Host

    $secureValue = Read-Host 'Discord Webhook URL' -AsSecureString

    if ($secureValue.Length -eq 0) {
        Write-Host
        Write-Host '[CANCELLED] 값이 입력되지 않았습니다.'
        return
    }

    $bstr = [IntPtr]::Zero
    $plainText = $null

    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $secureValue
        )

        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $bstr
        )

        if (-not (Test-DiscordWebhookUrl -Value $plainText)) {
            throw '유효한 Discord Webhook URL이 아닙니다.'
        }

        New-Item `
            -ItemType Directory `
            -Path $StateDirectory `
            -Force |
            Out-Null

        $encryptedValue = ConvertFrom-SecureString -SecureString $secureValue

        $temporaryFile = Join-Path (
            $StateDirectory
        ) (
            'discord-webhook.{0}.tmp' -f [Guid]::NewGuid().ToString('N')
        )

        try {
            [IO.File]::WriteAllText(
                $temporaryFile,
                $encryptedValue,
                [Text.Encoding]::ASCII
            )

            Move-Item `
                -LiteralPath $temporaryFile `
                -Destination $WebhookFile `
                -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryFile) {
                Remove-Item -LiteralPath $temporaryFile -Force
            }
        }

        Write-Host
        Write-Host '[OK] Discord Webhook을 암호화하여 저장했습니다.'
        Write-Host "     $WebhookFile"
    }
    finally {
        $plainText = $null

        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Remove-DiscordWebhook {
    if (-not (Test-Path -LiteralPath $WebhookFile -PathType Leaf)) {
        Write-Host
        Write-Host '[INFO] 저장된 Discord Webhook이 없습니다.'
        return
    }

    Write-Host
    Write-Host '로컬에 암호화 저장된 Webhook 자격 증명만 제거합니다.'
    Write-Host 'Discord의 Webhook 자체는 삭제되지 않습니다.'
    Write-Host

    $confirmation = Read-Host '계속하려면 REMOVE를 입력하세요'

    if ($confirmation -cne 'REMOVE') {
        Write-Host
        Write-Host '[CANCELLED] 저장된 Webhook을 제거하지 않았습니다.'
        return
    }

    Remove-Item -LiteralPath $WebhookFile -Force

    Write-Host
    Write-Host '[OK] 로컬에 저장된 Webhook 자격 증명을 제거했습니다.'
}

function Set-DiscordMentionRole {
    Write-Host
    Write-Host 'Discord 역할 snowflake(숫자만)를 입력하세요.'
    Write-Host 'Webhook URL, 역할 이름, <@&...> 마크업은 넣지 마세요.'
    Write-Host '값은 로컬 런타임 state 디렉터리에 저장됩니다.'
    Write-Host

    $rawValue = Read-Host 'Discord mention role ID'

    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        Write-Host
        Write-Host '[CANCELLED] 값이 입력되지 않았습니다.'
        return
    }

    $roleId = ConvertTo-DiscordMentionRoleId -Value $rawValue

    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null

    $temporaryFile = Join-Path $StateDirectory (
        'discord-mention-role.{0}.tmp' -f [Guid]::NewGuid().ToString('N')
    )

    try {
        [IO.File]::WriteAllText(
            $temporaryFile,
            $roleId,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryFile -Destination $MentionRoleFile -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }

    Write-Host
    Write-Host '[OK] Discord mention role ID를 저장했습니다.'
    Write-Host "     $MentionRoleFile"
    Write-Host '     (숫자 ID만 저장되며, 값은 출력하지 않습니다)'
}

function Remove-DiscordMentionRole {
    if (-not (Test-Path -LiteralPath $MentionRoleFile -PathType Leaf)) {
        Write-Host
        Write-Host '[INFO] 저장된 Discord mention role이 없습니다.'
        return
    }

    Write-Host
    Write-Host '로컬에 저장된 역할 ID만 제거합니다.'
    Write-Host 'Discord의 역할 자체는 삭제되지 않습니다.'
    Write-Host

    $confirmation = Read-Host '계속하려면 REMOVE를 입력하세요'
    if ($confirmation -cne 'REMOVE') {
        Write-Host
        Write-Host '[CANCELLED] 저장된 mention role을 제거하지 않았습니다.'
        return
    }

    Remove-Item -LiteralPath $MentionRoleFile -Force
    Write-Host
    Write-Host '[OK] 로컬에 저장된 mention role ID를 제거했습니다.'
}

function Get-MentionRoleStatus {
    $roleId = Get-DiscordMentionRoleId -Path $MentionRoleFile
    if ($null -ne $roleId) { return '설정됨' }
    if (Test-Path -LiteralPath $MentionRoleFile -PathType Leaf) { return '잘못됨' }
    return '없음'
}

function Get-WebhookStatus {
    if (Test-Path -LiteralPath $WebhookFile -PathType Leaf) {
        return '연결됨'
    }

    $envWebhook = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_WEBHOOK_URL', 'Process')
    if ([string]::IsNullOrWhiteSpace($envWebhook)) {
        $envWebhook = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_WEBHOOK_URL', 'User')
    }

    if (-not [string]::IsNullOrWhiteSpace($envWebhook)) {
        return '연결됨'
    }

    return '없음'
}

function Get-NotificationDeliveryProcesses {
    # Use List so 0/1 items stay a real collection under StrictMode.
    $processes = [System.Collections.Generic.List[object]]::new()

    $candidates = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            (
                $_.Name -ieq 'powershell.exe' -or
                $_.Name -ieq 'pwsh.exe'
            ) -and
            $_.CommandLine -match 'AIWorkerNotifier\.internal\.ps1'
        }

    foreach ($candidate in @($candidates)) {
        if ($null -ne $candidate) {
            $processes.Add($candidate)
        }
    }

    # Unary comma prevents PowerShell from enumerating the List into the pipeline.
    return , $processes
}

function Test-NotificationDeliveryRunning {
    return (Get-NotificationDeliveryProcesses).Count -gt 0
}

function Get-NotificationDeliveryStatus {
    if (Test-NotificationDeliveryRunning) {
        return 'ON'
    }

    return 'OFF'
}

function Start-NotificationDelivery {
    if (-not (Test-Path -LiteralPath $NotifierInternalFile -PathType Leaf)) {
        throw "알림 전달 실행 파일을 찾지 못했습니다: $NotifierInternalFile"
    }

    if ((Get-WebhookStatus) -eq '없음') {
        Write-Host
        Write-Host '[WARNING] Webhook이 아직 없습니다. 메뉴 2번에서 먼저 연결하세요.'
    }

    if (Test-NotificationDeliveryRunning) {
        Write-Host
        Write-Host '[INFO] 알림 전달이 이미 ON 입니다.'
        return
    }

    Start-Process `
        -FilePath 'powershell.exe' `
        -WorkingDirectory $BinDirectory `
        -WindowStyle Hidden `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $NotifierInternalFile
        ) |
        Out-Null

    Start-Sleep -Seconds 2

    if (Test-NotificationDeliveryRunning) {
        Write-Host
        Write-Host '[OK] 알림 전달을 ON 으로 켰습니다. (백그라운드)'
    }
    else {
        throw '알림 전달을 켜지 못했습니다. 로그를 확인하세요.'
    }
}

function Stop-NotificationDelivery {
    $processes = Get-NotificationDeliveryProcesses
    if ($processes.Count -eq 0) {
        Write-Host
        Write-Host '[INFO] 알림 전달이 이미 OFF 입니다.'
        return
    }

    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 1

    if (Test-NotificationDeliveryRunning) {
        throw '알림 전달을 끄지 못했습니다. 작업 관리자에서 powershell 프로세스를 확인하세요.'
    }

    Write-Host
    Write-Host '[OK] 알림 전달을 OFF 로 껐습니다.'
}

function Switch-NotificationDelivery {
    if (Test-NotificationDeliveryRunning) {
        Stop-NotificationDelivery
        return
    }

    Start-NotificationDelivery
}

function Get-StoredWebhookUrl {
    $envWebhook = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_WEBHOOK_URL', 'Process')
    if ([string]::IsNullOrWhiteSpace($envWebhook)) {
        $envWebhook = [Environment]::GetEnvironmentVariable('AI_WORKER_NOTIFIER_WEBHOOK_URL', 'User')
    }
    if (-not [string]::IsNullOrWhiteSpace($envWebhook)) {
        return $envWebhook.Trim()
    }

    if (-not (Test-Path -LiteralPath $WebhookFile -PathType Leaf)) {
        throw 'Discord Webhook이 없습니다. 메뉴 2번에서 먼저 연결하세요.'
    }

    $encrypted = (Get-Content -LiteralPath $WebhookFile -Raw).Trim()
    $secure = ConvertTo-SecureString $encrypted
    $credential = [System.Management.Automation.PSCredential]::new('webhook', $secure)
    return $credential.GetNetworkCredential().Password
}

function Send-DiscordWebhookPayload {
    param(
        [Parameter(Mandatory = $true)]
        $PayloadObject
    )

    $webhook = Get-StoredWebhookUrl
    $payloadBytes = [byte[]](ConvertTo-Utf8JsonBytes -PayloadObject $PayloadObject)

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    try {
        $response = Invoke-WebRequest `
            -Method Post `
            -Uri $webhook `
            -ContentType 'application/json; charset=utf-8' `
            -Body $payloadBytes `
            -TimeoutSec 8 `
            -UseBasicParsing

        $statusCode = [int]$response.StatusCode
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw "Unexpected Discord HTTP status: $statusCode"
        }
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch { }
        }

        if ($statusCode -eq 204) {
            return
        }

        $detail = $_.Exception.Message
        $detail = [regex]::Replace(
            $detail,
            'https://discord(?:app)?\.com/api/webhooks/\S+',
            '[WEBHOOK]'
        )

        if ($statusCode) {
            throw ("Discord 전송에 실패했습니다. (HTTP {0}) {1}" -f $statusCode, $detail)
        }

        throw ("Discord 전송에 실패했습니다. {0}" -f $detail)
    }
}

function New-SetupTestMessage {
    param([Parameter(Mandatory = $true)][string]$KindLabel)

    $stamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    return @(
        'AI Worker Notifier 테스트'
        ''
        "종류: $KindLabel"
        "시각: $stamp"
        ''
        '이 메시지가 보이면 연결은 정상입니다.'
    ) -join "`n"
}

function Show-WebhookMenu {
    while ($true) {
        Clear-Host
        Write-Host '============================================================'
        Write-Host '                   Webhook 설정'
        Write-Host '============================================================'
        Write-Host
        Write-Host ("현재: {0}" -f (Get-WebhookStatus))
        Write-Host
        Write-Host '  1. 연결 / 변경'
        Write-Host '  2. 연결 해제'
        Write-Host '  0. 뒤로'
        Write-Host

        switch (Read-Host '번호를 고르세요') {
            '1' { Set-DiscordWebhook; Pause-Setup }
            '2' { Remove-DiscordWebhook; Pause-Setup }
            '0' { return }
            default {
                Write-Host
                Write-Host '[ERROR] 0~2 사이 숫자를 입력하세요.'
                Pause-Setup
            }
        }
    }
}

function Show-MentionRoleMenu {
    while ($true) {
        Clear-Host
        Write-Host '============================================================'
        Write-Host '                  역할 멘션 설정'
        Write-Host '============================================================'
        Write-Host
        Write-Host ("현재: {0}" -f (Get-MentionRoleStatus))
        Write-Host
        Write-Host '알림에 @역할을 붙일 때 사용합니다.'
        Write-Host 'Discord 역할 우클릭 → ID 복사 (개발자 모드 ON).'
        Write-Host
        Write-Host '  1. 역할 ID 저장'
        Write-Host '  2. 역할 ID 삭제'
        Write-Host '  0. 뒤로'
        Write-Host

        switch (Read-Host '번호를 고르세요') {
            '1' { Set-DiscordMentionRole; Pause-Setup }
            '2' { Remove-DiscordMentionRole; Pause-Setup }
            '0' { return }
            default {
                Write-Host
                Write-Host '[ERROR] 0~2 사이 숫자를 입력하세요.'
                Pause-Setup
            }
        }
    }
}

function Show-PathMenu {
    while ($true) {
        $pathStatus = if (Test-BinPathRegistered) { '등록됨' } else { '미등록' }

        Clear-Host
        Write-Host '============================================================'
        Write-Host '                   명령 등록'
        Write-Host '============================================================'
        Write-Host
        Write-Host ("현재: {0}" -f $pathStatus)
        Write-Host
        Write-Host '등록하면 새 터미널에서 ai-task-complete 를 바로 쓸 수 있습니다.'
        Write-Host
        Write-Host '  1. 등록'
        Write-Host '  2. 등록 해제'
        Write-Host '  0. 뒤로'
        Write-Host

        switch (Read-Host '번호를 고르세요') {
            '1' { Add-BinPath; Pause-Setup }
            '2' {
                Write-Host
                $confirmation = Read-Host '등록을 해제할까요? [Y/N]'
                if ($confirmation -match '^[Yy]$') { Remove-BinPath }
                else { Write-Host; Write-Host '[CANCELLED] 변경하지 않았습니다.' }
                Pause-Setup
            }
            '0' { return }
            default {
                Write-Host
                Write-Host '[ERROR] 0~2 사이 숫자를 입력하세요.'
                Pause-Setup
            }
        }
    }
}

function Show-NotificationTestMenu {
    while ($true) {
        Clear-Host
        Write-Host '============================================================'
        Write-Host '                   알림 테스트'
        Write-Host '============================================================'
        Write-Host
        Write-Host ("Webhook   : {0}" -f (Get-WebhookStatus))
        Write-Host ("역할 멘션 : {0}" -f (Get-MentionRoleStatus))
        Write-Host
        Write-Host 'Discord로 바로 보내 멘션이 실제로 울리는지 확인합니다.'
        Write-Host
        Write-Host '  1. 멘션 없이 보내기'
        Write-Host '  2. @역할 멘션'
        Write-Host '  3. @사용자 멘션'
        Write-Host '  4. @everyone 멘션'
        Write-Host '  0. 뒤로'
        Write-Host

        $selection = Read-Host '번호를 고르세요'

        try {
            switch ($selection) {
                '1' {
                    $payload = New-DiscordWebhookPayloadObject `
                        -Message (New-SetupTestMessage -KindLabel '멘션 없음')
                    Send-DiscordWebhookPayload -PayloadObject $payload
                    Write-Host
                    Write-Host '[OK] 멘션 없이 보냈습니다.'
                    Pause-Setup
                }
                '2' {
                    $roleId = Get-DiscordMentionRoleId -Path $MentionRoleFile
                    if ($null -eq $roleId) {
                        throw '저장된 역할 ID가 없습니다. 메뉴 3번에서 먼저 설정하세요.'
                    }

                    $payload = New-DiscordWebhookPayloadObject `
                        -Message (New-SetupTestMessage -KindLabel '@역할') `
                        -RoleId $roleId
                    Send-DiscordWebhookPayload -PayloadObject $payload
                    Write-Host
                    Write-Host '[OK] @역할 멘션 알림을 보냈습니다.'
                    Write-Host '     Discord에서 역할 알림이 울리는지 확인하세요.'
                    Pause-Setup
                }
                '3' {
                    Write-Host
                    Write-Host '멘션할 사용자 ID(숫자)를 입력하세요.'
                    Write-Host '사용자 우클릭 → ID 복사 (개발자 모드 ON).'
                    Write-Host
                    $rawUserId = Read-Host '사용자 ID'
                    if ([string]::IsNullOrWhiteSpace($rawUserId)) {
                        Write-Host
                        Write-Host '[CANCELLED] 입력하지 않았습니다.'
                        Pause-Setup
                        continue
                    }

                    $userId = ConvertTo-DiscordSnowflakeId -Value $rawUserId -Kind user
                    $payload = New-DiscordWebhookPayloadObject `
                        -Message (New-SetupTestMessage -KindLabel '@사용자') `
                        -UserId $userId
                    Send-DiscordWebhookPayload -PayloadObject $payload
                    Write-Host
                    Write-Host '[OK] @사용자 멘션 알림을 보냈습니다.'
                    Write-Host '     해당 사용자에게 알림이 가는지 확인하세요.'
                    Pause-Setup
                }
                '4' {
                    Write-Host
                    Write-Host '@everyone 은 채널/서버 설정에 따라 막힐 수 있습니다.'
                    Write-Host
                    $confirmation = Read-Host '보내겠습니까? [Y/N]'
                    if ($confirmation -notmatch '^[Yy]$') {
                        Write-Host
                        Write-Host '[CANCELLED] 보내지 않았습니다.'
                        Pause-Setup
                        continue
                    }

                    $payload = New-DiscordWebhookPayloadObject `
                        -Message (New-SetupTestMessage -KindLabel '@everyone') `
                        -MentionEveryone
                    Send-DiscordWebhookPayload -PayloadObject $payload
                    Write-Host
                    Write-Host '[OK] @everyone 멘션 알림을 보냈습니다.'
                    Pause-Setup
                }
                '0' { return }
                default {
                    Write-Host
                    Write-Host '[ERROR] 0~4 사이 숫자를 입력하세요.'
                    Pause-Setup
                }
            }
        }
        catch {
            Write-Host
            Write-Host '[ERROR] 알림 테스트에 실패했습니다.'
            Write-Host "        $($_.Exception.Message)"
            Pause-Setup
        }
    }
}

function Show-Menu {
    $pathStatus = if (Test-BinPathRegistered) { '등록됨' } else { '미등록' }
    $deliveryStatus = Get-NotificationDeliveryStatus
    $webhookStatus = Get-WebhookStatus
    $mentionStatus = Get-MentionRoleStatus

    Clear-Host
    Write-Host '============================================================'
    Write-Host '                   AI 작업 알림'
    Write-Host '============================================================'
    Write-Host
    Write-Host '  알림 전달   ' -NoNewline
    if ($deliveryStatus -eq 'ON') {
        Write-Host 'ON' -ForegroundColor Green
    }
    else {
        Write-Host 'OFF' -ForegroundColor Red
    }
    Write-Host ("  Webhook     {0}" -f $webhookStatus)
    Write-Host ("  역할 멘션   {0}" -f $mentionStatus)
    Write-Host ("  명령 등록   {0}" -f $pathStatus)
    Write-Host
    Write-Host '  1. 알림 전달 ON/OFF'
    Write-Host '  2. Webhook 설정'
    Write-Host '  3. 역할 멘션 설정'
    Write-Host '  4. 알림 테스트'
    Write-Host '  5. 명령 등록'
    Write-Host '  0. 나가기'
    Write-Host
}

while ($true) {
    Show-Menu
    $selection = Read-Host '번호를 고르세요'

    try {
        switch ($selection) {
            '1' { Switch-NotificationDelivery; Pause-Setup }
            '2' { Show-WebhookMenu }
            '3' { Show-MentionRoleMenu }
            '4' { Show-NotificationTestMenu }
            '5' { Show-PathMenu }
            '0' { Write-Host; Write-Host '종료합니다.'; exit 0 }
            default {
                Write-Host
                Write-Host '[ERROR] 0~5 사이 숫자를 입력하세요.'
                Pause-Setup
            }
        }
    }
    catch {
        Write-Host
        Write-Host '[ERROR] 요청한 작업에 실패했습니다.'
        Write-Host "        $($_.Exception.Message)"
        Pause-Setup
    }
}
