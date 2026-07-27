# Shared Discord payload helpers for AI Worker Notifier.
# Dot-source only. Does not send network requests or print secrets.

Set-StrictMode -Version Latest

function Test-DiscordSnowflakeId {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmed = $Value.Trim()
    # Discord snowflake: digits only. Reject names, <@...>, URLs.
    return [regex]::IsMatch($trimmed, '^[0-9]{5,32}$')
}

function Test-DiscordMentionRoleId {
    param(
        [AllowNull()]
        [string]$Value
    )

    return Test-DiscordSnowflakeId -Value $Value
}

function ConvertTo-DiscordSnowflakeId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [ValidateSet('role', 'user')]
        [string]$Kind = 'role'
    )

    $trimmed = $Value.Trim()

    if ($Kind -eq 'role' -and $trimmed -match '^<@&([0-9]{5,32})>$') {
        throw '숫자 역할 ID만 입력하세요. <@&...> 형식은 넣지 마세요.'
    }

    if ($Kind -eq 'user' -and $trimmed -match '^<@!?([0-9]{5,32})>$') {
        throw '숫자 사용자 ID만 입력하세요. <@...> 형식은 넣지 마세요.'
    }

    if ($trimmed -match '(?i)discord\.com|webhook|https?://') {
        throw 'Webhook URL이나 Discord 링크는 ID가 아닙니다.'
    }

    if ($trimmed -match '[^0-9]') {
        throw 'ID는 숫자만 사용할 수 있습니다.'
    }

    if (-not (Test-DiscordSnowflakeId -Value $trimmed)) {
        throw 'ID는 5~32자리 Discord snowflake여야 합니다.'
    }

    return $trimmed
}

function ConvertTo-DiscordMentionRoleId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return ConvertTo-DiscordSnowflakeId -Value $Value -Kind role
}

function Get-DiscordMentionRoleId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        if (-not (Test-DiscordSnowflakeId -Value $raw)) {
            return $null
        }

        return $raw
    }
    catch {
        return $null
    }
}

function New-DiscordWebhookPayloadObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [AllowNull()]
        [string]$RoleId,

        [AllowNull()]
        [string]$UserId,

        [switch]$MentionEveryone,

        [string]$Username = 'AI Worker Notifier'
    )

    $hasRole = -not [string]::IsNullOrWhiteSpace($RoleId)
    $hasUser = -not [string]::IsNullOrWhiteSpace($UserId)
    $mentionKinds = @($MentionEveryone.IsPresent, $hasRole, $hasUser) | Where-Object { $_ }

    if (@($mentionKinds).Count -gt 1) {
        throw '멘션 종류는 한 번에 하나만 지정할 수 있습니다.'
    }

    $payload = [ordered]@{
        content  = $Message
        username = $Username
    }

    if ($MentionEveryone) {
        $payload['content'] = "@everyone`n`n$Message"
        $payload['allowed_mentions'] = [ordered]@{
            parse = , 'everyone'
        }
        return $payload
    }

    if ($hasUser) {
        $userSnowflake = ConvertTo-DiscordSnowflakeId -Value $UserId -Kind user
        $payload['content'] = "<@$userSnowflake>`n`n$Message"
        $payload['allowed_mentions'] = [ordered]@{
            parse = @()
            users = , ([string]$userSnowflake)
        }
        return $payload
    }

    if ($hasRole) {
        $roleSnowflake = ConvertTo-DiscordSnowflakeId -Value $RoleId -Kind role
        $payload['content'] = "<@&$roleSnowflake>`n`n$Message"
        # Unary comma keeps a single-element array under Windows PowerShell 5.1.
        $payload['allowed_mentions'] = [ordered]@{
            parse = @()
            roles = , ([string]$roleSnowflake)
        }
        return $payload
    }

    return $payload
}

function ConvertTo-Utf8JsonBytes {
    param(
        [Parameter(Mandatory = $true)]
        $PayloadObject
    )

    # ConvertTo-Json on the whole object collapses empty/single arrays on PS 5.1.
    # Escape strings with ConvertTo-Json, then assemble array literals manually.
    $contentJson = [string]$PayloadObject.content | ConvertTo-Json -Compress
    $usernameJson = [string]$PayloadObject.username | ConvertTo-Json -Compress

    $hasAllowedMentions = $false
    if (
        $PayloadObject -is [System.Collections.IDictionary] -and
        $PayloadObject.Contains('allowed_mentions')
    ) {
        $hasAllowedMentions = $true
    }
    elseif ($null -ne $PayloadObject['allowed_mentions']) {
        $hasAllowedMentions = $true
    }

    if (-not $hasAllowedMentions) {
        $json = "{{`"content`":{0},`"username`":{1}}}" -f $contentJson, $usernameJson
        return , [Text.Encoding]::UTF8.GetBytes($json)
    }

    $allowed = $PayloadObject['allowed_mentions']
    $parseValues = @($allowed.parse)
    if ($parseValues.Count -eq 0) {
        $parseJson = '[]'
    }
    else {
        $parseItems = foreach ($item in $parseValues) {
            ([string]$item | ConvertTo-Json -Compress)
        }
        $parseJson = '[' + ($parseItems -join ',') + ']'
    }

    $mentionParts = New-Object System.Collections.Generic.List[string]
    $mentionParts.Add(('"parse":{0}' -f $parseJson))

    $hasRoles = (
        $allowed -is [System.Collections.IDictionary] -and
        $allowed.Contains('roles')
    )
    $hasUsers = (
        $allowed -is [System.Collections.IDictionary] -and
        $allowed.Contains('users')
    )

    if ($hasRoles) {
        $roleValues = @($allowed.roles)
        if ($roleValues.Count -ne 1) {
            throw 'allowed_mentions.roles must contain exactly one role ID.'
        }

        $roleJson = ([string]$roleValues[0] | ConvertTo-Json -Compress)
        $mentionParts.Add(('"roles":[{0}]' -f $roleJson))
    }

    if ($hasUsers) {
        $userValues = @($allowed.users)
        if ($userValues.Count -ne 1) {
            throw 'allowed_mentions.users must contain exactly one user ID.'
        }

        $userJson = ([string]$userValues[0] | ConvertTo-Json -Compress)
        $mentionParts.Add(('"users":[{0}]' -f $userJson))
    }

    $allowedJson = '{' + ($mentionParts -join ',') + '}'
    $json = "{{`"content`":{0},`"username`":{1},`"allowed_mentions`":{2}}}" -f `
        $contentJson, $usernameJson, $allowedJson

    # Unary comma prevents PowerShell from unrolling byte[] into Object[].
    return , [Text.Encoding]::UTF8.GetBytes($json)
}

function ConvertFrom-Utf8JsonBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $json = [Text.Encoding]::UTF8.GetString($Bytes)
    return ($json | ConvertFrom-Json)
}
