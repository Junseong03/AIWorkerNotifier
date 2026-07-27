Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# AI Worker Notifier setup menu
#
# This file intentionally uses ASCII-only user-facing text.
# It avoids code-page and UTF-8 parsing problems in Windows PowerShell 5.1
# and cmd.exe.
# ---------------------------------------------------------------------------

$ScriptDirectory = $PSScriptRoot
$ApplicationRoot = Split-Path -Parent $ScriptDirectory
$BinDirectory = Join-Path $ApplicationRoot 'bin'

$CliCommandFile = Join-Path $BinDirectory 'ai-task-complete.cmd'
$NotifierCommandFile = Join-Path $BinDirectory 'AIWorkerNotifier.cmd'

$RuntimeRoot = Join-Path $env:LOCALAPPDATA 'AIWorkerNotifier'
$StateDirectory = Join-Path $RuntimeRoot 'state'
$WebhookFile = Join-Path $StateDirectory 'discord-webhook.dpapi'
$MentionRoleFile = Join-Path $StateDirectory 'discord-mention-role.id'
$PayloadHelperPath = Join-Path $BinDirectory 'DiscordPayload.ps1'

. $PayloadHelperPath

function Pause-Setup {
    Write-Host
    [void](Read-Host 'Press Enter to continue')
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
        throw "The bin directory does not exist: $BinDirectory"
    }

    if (-not (Test-Path -LiteralPath $CliCommandFile -PathType Leaf)) {
        throw "Required command was not found: $CliCommandFile"
    }

    if (-not (Test-Path -LiteralPath $NotifierCommandFile -PathType Leaf)) {
        throw "Required command was not found: $NotifierCommandFile"
    }

    if (Test-BinPathRegistered) {
        Write-Host
        Write-Host '[INFO] The command directory is already registered.'
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
    Write-Host '[OK] Registered the command directory in the user PATH.'
    Write-Host "     $BinDirectory"
    Write-Host
    Write-Host 'Open a new PowerShell or Cursor CLI session before testing.'
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
        Write-Host '[INFO] The command directory is not registered in the user PATH.'
        return
    }

    $newPath = $remainingEntries -join ';'

    [Environment]::SetEnvironmentVariable(
        'Path',
        $newPath,
        [EnvironmentVariableTarget]::User
    )

    Write-Host
    Write-Host '[OK] Removed the command directory from the user PATH.'
    Write-Host "     $BinDirectory"
    Write-Host
    Write-Host 'Program files and runtime data were not deleted.'
    Write-Host 'Open a new PowerShell or Cursor CLI session to apply the change.'
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
    Write-Host 'The Webhook URL will not be displayed while typing.'
    Write-Host 'It will be encrypted with Windows DPAPI for the current user.'
    Write-Host

    $secureValue = Read-Host 'Discord Webhook URL' -AsSecureString

    if ($secureValue.Length -eq 0) {
        Write-Host
        Write-Host '[CANCELLED] No value was entered.'
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
            throw 'The value is not a valid Discord Webhook URL.'
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
        Write-Host '[OK] Discord Webhook was encrypted and saved.'
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
        Write-Host '[INFO] No stored Discord Webhook was found.'
        return
    }

    Write-Host
    Write-Host 'This removes only the locally encrypted Webhook credential.'
    Write-Host 'It does not delete the Webhook from Discord.'
    Write-Host

    $confirmation = Read-Host 'Type REMOVE to continue'

    if ($confirmation -cne 'REMOVE') {
        Write-Host
        Write-Host '[CANCELLED] The stored Webhook was not removed.'
        return
    }

    Remove-Item -LiteralPath $WebhookFile -Force

    Write-Host
    Write-Host '[OK] Removed the locally stored Webhook credential.'
}
function Set-DiscordMentionRole {
    Write-Host
    Write-Host 'Enter the Discord role snowflake (digits only).'
    Write-Host 'Do not paste a Webhook URL, role name, or <@&...> markup.'
    Write-Host 'The value is stored in the local runtime state directory.'
    Write-Host

    $rawValue = Read-Host 'Discord mention role ID'

    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        Write-Host
        Write-Host '[CANCELLED] No value was entered.'
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
    Write-Host '[OK] Discord mention role ID was saved.'
    Write-Host "     $MentionRoleFile"
    Write-Host '     (numeric ID only; value is not printed)'
}

function Remove-DiscordMentionRole {
    if (-not (Test-Path -LiteralPath $MentionRoleFile -PathType Leaf)) {
        Write-Host
        Write-Host '[INFO] No stored Discord mention role was found.'
        return
    }

    Write-Host
    Write-Host 'This removes only the locally stored role ID.'
    Write-Host 'It does not delete the role from Discord.'
    Write-Host

    $confirmation = Read-Host 'Type REMOVE to continue'
    if ($confirmation -cne 'REMOVE') {
        Write-Host
        Write-Host '[CANCELLED] The stored mention role was not removed.'
        return
    }

    Remove-Item -LiteralPath $MentionRoleFile -Force
    Write-Host
    Write-Host '[OK] Removed the locally stored mention role ID.'
}

function Get-MentionRoleStatus {
    $roleId = Get-DiscordMentionRoleId -Path $MentionRoleFile
    if ($null -ne $roleId) { return 'CONFIGURED' }
    if (Test-Path -LiteralPath $MentionRoleFile -PathType Leaf) { return 'INVALID' }
    return 'NOT CONFIGURED'
}

function Show-SetupStatus {
    $pathStatus = if (Test-BinPathRegistered) { 'REGISTERED' } else { 'NOT REGISTERED' }
    $webhookStatus = if (Test-Path -LiteralPath $WebhookFile -PathType Leaf) { 'CONFIGURED' } else { 'NOT CONFIGURED' }
    $mentionStatus = Get-MentionRoleStatus
    $cliStatus = if (Test-Path -LiteralPath $CliCommandFile -PathType Leaf) { 'FOUND' } else { 'MISSING' }
    $notifierStatus = if (Test-Path -LiteralPath $NotifierCommandFile -PathType Leaf) { 'FOUND' } else { 'MISSING' }

    Write-Host
    Write-Host 'Current status'
    Write-Host '--------------'
    Write-Host "Application root : $ApplicationRoot"
    Write-Host "Command directory: $BinDirectory"
    Write-Host "User PATH        : $pathStatus"
    Write-Host "Webhook          : $webhookStatus"
    Write-Host "Mention role     : $mentionStatus"
    Write-Host "CLI command      : $cliStatus"
    Write-Host "Notifier command : $notifierStatus"
    Write-Host "Runtime root     : $RuntimeRoot"
}

function Show-Menu {
    $pathStatus = if (Test-BinPathRegistered) { 'REGISTERED' } else { 'NOT REGISTERED' }
    $webhookStatus = if (Test-Path -LiteralPath $WebhookFile -PathType Leaf) { 'CONFIGURED' } else { 'NOT CONFIGURED' }
    $mentionStatus = Get-MentionRoleStatus

    Clear-Host
    Write-Host '============================================================'
    Write-Host '                 AI Worker Notifier Setup'
    Write-Host '============================================================'
    Write-Host
    Write-Host "Application: $ApplicationRoot"
    Write-Host "PATH       : $pathStatus"
    Write-Host "Webhook    : $webhookStatus"
    Write-Host "Mention    : $mentionStatus"
    Write-Host
    Write-Host '  1. Register commands in the current user PATH'
    Write-Host '  2. Remove commands from the current user PATH'
    Write-Host '  3. Configure or replace the Discord Webhook'
    Write-Host '  4. Remove the stored Discord Webhook'
    Write-Host '  5. Configure Discord mention role'
    Write-Host '  6. Remove Discord mention role'
    Write-Host '  7. Show detailed setup status'
    Write-Host '  8. Exit'
    Write-Host
    Write-Host 'PATH changes apply to newly opened terminal sessions.'
    Write-Host 'Removing PATH does not delete program files or runtime data.'
    Write-Host
}

while ($true) {
    Show-Menu
    $selection = Read-Host 'Select an option [1-8]'

    try {
        switch ($selection) {
            '1' { Add-BinPath; Pause-Setup }
            '2' {
                Write-Host
                $confirmation = Read-Host 'Remove the command directory from user PATH? [Y/N]'
                if ($confirmation -match '^[Yy]$') { Remove-BinPath }
                else { Write-Host; Write-Host '[CANCELLED] PATH was not changed.' }
                Pause-Setup
            }
            '3' { Set-DiscordWebhook; Pause-Setup }
            '4' { Remove-DiscordWebhook; Pause-Setup }
            '5' { Set-DiscordMentionRole; Pause-Setup }
            '6' { Remove-DiscordMentionRole; Pause-Setup }
            '7' { Show-SetupStatus; Pause-Setup }
            '8' { Write-Host; Write-Host 'Setup closed.'; exit 0 }
            default {
                Write-Host
                Write-Host '[ERROR] Enter a number from 1 to 8.'
                Pause-Setup
            }
        }
    }
    catch {
        Write-Host
        Write-Host '[ERROR] The requested operation failed.'
        Write-Host "        $($_.Exception.Message)"
        Pause-Setup
    }
}
