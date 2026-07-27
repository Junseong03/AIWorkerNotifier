# Shared Discord payload helpers for AI Worker Notifier.
# Dot-source only. Does not send network requests or print secrets.

Set-StrictMode -Version Latest

function Test-DiscordMentionRoleId {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmed = $Value.Trim()
    # Discord snowflake: digits only. Reject names, <@&...>, URLs.
    return [regex]::IsMatch($trimmed, '^[0-9]{5,32}$')
}

function ConvertTo-DiscordMentionRoleId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ($trimmed -match '^<@&([0-9]{5,32})>$') {
        throw 'Store the numeric role ID only. Do not paste <@&...> mention markup.'
    }

    if ($trimmed -match '(?i)discord\.com|webhook|https?://') {
        throw 'A Webhook URL or Discord URL is not a role ID.'
    }

    if ($trimmed -match '[^0-9]') {
        throw 'Role ID must be digits only.'
    }

    if (-not (Test-DiscordMentionRoleId -Value $trimmed)) {
        throw 'Role ID must be a Discord snowflake of 5-32 digits.'
    }

    return $trimmed
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

        if (-not (Test-DiscordMentionRoleId -Value $raw)) {
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

        [string]$Username = 'AI Worker Notifier'
    )

    $payload = [ordered]@{
        content  = $Message
        username = $Username
    }

    if (-not [string]::IsNullOrWhiteSpace($RoleId)) {
        if (-not (Test-DiscordMentionRoleId -Value $RoleId)) {
            throw 'Configured mention role ID is invalid.'
        }

        $payload['content'] = "<@&$RoleId>`n`n$Message"
        # Unary comma keeps a single-element array under Windows PowerShell 5.1.
        $payload['allowed_mentions'] = [ordered]@{
            parse = @()
            roles = , ([string]$RoleId)
        }
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

    if (
        $null -ne $PayloadObject['allowed_mentions'] -or
        (
            $PayloadObject -is [System.Collections.IDictionary] -and
            $PayloadObject.Contains('allowed_mentions')
        )
    ) {
        $roleValues = @($PayloadObject.allowed_mentions.roles)
        if ($roleValues.Count -ne 1) {
            throw 'allowed_mentions.roles must contain exactly one role ID.'
        }

        $roleJson = ([string]$roleValues[0] | ConvertTo-Json -Compress)
        $json = "{{`"content`":{0},`"username`":{1},`"allowed_mentions`":{{`"parse`":[],`"roles`":[{2}]}}}}" -f `
            $contentJson, $usernameJson, $roleJson
    }
    else {
        $json = "{{`"content`":{0},`"username`":{1}}}" -f $contentJson, $usernameJson
    }

    return [Text.Encoding]::UTF8.GetBytes($json)
}

function ConvertFrom-Utf8JsonBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $json = [Text.Encoding]::UTF8.GetString($Bytes)
    return ($json | ConvertFrom-Json)
}
