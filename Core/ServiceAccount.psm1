#Requires -Version 7.0
<#
.SYNOPSIS
    Least-privilege local service account provisioning for GSM.
.DESCRIPTION
    Phase 1. Creates and configures a dedicated local Windows account under
    which game servers run, instead of the interactive admin account. Grants
    only what's needed: SeServiceLogonRight and Modify access to GSM's
    install/config/log/backup folders. Does not grant local admin rights.

    This module only provisions the account. Using that account to actually
    run a server as a Windows service is Core/Service.psm1 (Phase 2).
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force

# Folders the service account needs Modify (not Full Control) access to.
$script:GSMServiceAccountFolders = @('Config', 'Logs', 'Reports', 'Backups', 'SteamCMD')

function Test-GSMElevation {
    # Internal helper. Not exported: returns whether the current process is
    # running in an elevated (local Administrator) session.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-GSMServiceAccountPassword {
    # Internal helper. Not exported: generates a random password using
    # System.Security.Cryptography.RandomNumberGenerator (not Get-Random,
    # which is not cryptographically secure). Guarantees at least one
    # uppercase, lowercase, digit, and symbol character by construction, then
    # shuffles so the guaranteed characters aren't always in the same
    # positions.
    #
    # Returns a SecureString built directly via AppendChar rather than a
    # plain string passed through ConvertTo-SecureString -AsPlainText: this
    # avoids ever materializing the password as an immutable .NET string,
    # and the intermediate char[] buffer is explicitly zeroed once the
    # SecureString is built, so no in-memory plaintext copy outlives this
    # function.
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter()]
        [int]$Length = 32
    )

    if ($Length -lt 24) {
        throw 'Service account password length must be at least 24 characters.'
    }

    $upperChars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lowerChars = [char[]]'abcdefghijklmnopqrstuvwxyz'
    $digitChars = [char[]]'0123456789'
    $symbolChars = [char[]]'!@#%^&*-_=+'
    $allChars = $upperChars + $lowerChars + $digitChars + $symbolChars

    $passwordChars = [char[]]::new($Length)
    $passwordChars[0] = $upperChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $upperChars.Length)]
    $passwordChars[1] = $lowerChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $lowerChars.Length)]
    $passwordChars[2] = $digitChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $digitChars.Length)]
    $passwordChars[3] = $symbolChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $symbolChars.Length)]

    for ($i = 4; $i -lt $Length; $i++) {
        $passwordChars[$i] = $allChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $allChars.Length)]
    }

    for ($i = $passwordChars.Length - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $i + 1)
        $swap = $passwordChars[$i]
        $passwordChars[$i] = $passwordChars[$j]
        $passwordChars[$j] = $swap
    }

    $securePassword = [securestring]::new()
    foreach ($char in $passwordChars) {
        $securePassword.AppendChar($char)
    }
    $securePassword.MakeReadOnly()

    [Array]::Clear($passwordChars, 0, $passwordChars.Length)

    return $securePassword
}

function Get-GSMAccountSID {
    # Internal helper. Not exported: resolves a local account's SID string.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $localUser = Get-LocalUser -Name $AccountName -ErrorAction Stop
    return $localUser.SID.Value
}

function Test-GSMAccountPresence {
    # Internal helper. Not exported: one of Test-GSMServiceAccount's four
    # independently checked conditions.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    return ($null -ne (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue))
}

function Test-GSMAccountIsAdminMember {
    # Internal helper. Not exported: one of Test-GSMServiceAccount's four
    # independently checked conditions.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $members = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue

    foreach ($member in $members) {
        $memberName = ($member.Name -split '\\')[-1]
        if ($memberName -eq $AccountName) {
            return $true
        }
    }

    return $false
}

function Grant-GSMServiceLogonRight {
    # Internal helper. Not exported: grants SeServiceLogonRight to AccountName
    # via secedit export/edit/import, since no PowerShell cmdlet manages user
    # rights assignments directly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $sid = Get-GSMAccountSID -AccountName $AccountName
    $sidToken = "*$sid"

    $workDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "gsm-secedit-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

    try {
        $cfgPath = Join-Path -Path $workDirectory -ChildPath 'secedit-export.inf'
        $dbPath = Join-Path -Path $workDirectory -ChildPath 'secedit.sdb'

        & secedit.exe /export /cfg $cfgPath /areas USER_RIGHTS | Out-Null

        $lines = Get-Content -Path $cfgPath
        $updatedLines = [System.Collections.Generic.List[string]]::new()
        $foundLine = $false

        foreach ($line in $lines) {
            if ($line -match '^\s*SeServiceLogonRight\s*=\s*(.*)$') {
                $foundLine = $true
                $existingSids = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($existingSids -notcontains $sidToken) {
                    $existingSids += $sidToken
                }
                $updatedLines.Add('SeServiceLogonRight = ' + ($existingSids -join ','))
            }
            else {
                $updatedLines.Add($line)
            }
        }

        if (-not $foundLine) {
            $withInsertedRight = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $updatedLines) {
                $withInsertedRight.Add($line)
                if ($line.Trim() -eq '[Privilege Rights]') {
                    $withInsertedRight.Add("SeServiceLogonRight = $sidToken")
                }
            }
            $updatedLines = $withInsertedRight
        }

        Set-Content -Path $cfgPath -Value $updatedLines

        & secedit.exe /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS | Out-Null
    }
    finally {
        Remove-Item -Path $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-GSMServiceLogonRight {
    # Internal helper. Not exported: one of Test-GSMServiceAccount's four
    # independently checked conditions.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    try {
        $sid = Get-GSMAccountSID -AccountName $AccountName
    }
    catch {
        return $false
    }

    $cfgPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "gsm-secedit-check-$([guid]::NewGuid().ToString('N')).inf"

    try {
        & secedit.exe /export /cfg $cfgPath /areas USER_RIGHTS | Out-Null
        $lines = Get-Content -Path $cfgPath -ErrorAction Stop
        $rightLine = $lines | Where-Object { $_ -match '^\s*SeServiceLogonRight\s*=\s*(.*)$' } | Select-Object -First 1

        if (-not $rightLine) {
            return $false
        }

        $null = $rightLine -match '^\s*SeServiceLogonRight\s*=\s*(.*)$'
        $sids = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() })
        return ($sids -contains "*$sid")
    }
    catch {
        return $false
    }
    finally {
        Remove-Item -Path $cfgPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-GSMExpectedFolderPermission {
    # Internal helper. Not exported: one of Test-GSMServiceAccount's four
    # independently checked conditions.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $rootPath = Get-GSMRootPath

    foreach ($folder in $script:GSMServiceAccountFolders) {
        $folderPath = Join-Path -Path $rootPath -ChildPath $folder

        try {
            $acl = Get-Acl -Path $folderPath -ErrorAction Stop
        }
        catch {
            return $false
        }

        $hasModify = $acl.Access | Where-Object {
            ($_.IdentityReference.Value -split '\\')[-1] -eq $AccountName -and
            $_.AccessControlType -eq 'Allow' -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify) -eq [System.Security.AccessControl.FileSystemRights]::Modify
        }

        if (-not $hasModify) {
            return $false
        }
    }

    return $true
}

function New-GSMServiceAccount {
    <#
    .SYNOPSIS
        Creates (or rotates the password for) GSM's least-privilege local
        service account.
    .DESCRIPTION
        Requires an elevated session. No-ops and returns $true if the
        account already exists and Force isn't specified. Otherwise
        generates a cryptographically random password, creates the local
        account with PasswordNeverExpires and no group memberships (not
        Administrators, not any privileged group), then stores the password
        DPAPI-encrypted at Config/ServiceAccount.secure.txt. With Force on an
        existing account, rotates its password instead of creating a new
        account.
    .PARAMETER AccountName
        Name of the local account to create. Defaults to
        'GSM-ServiceAccount'.
    .PARAMETER Force
        Rotate the password even if the account already exists.
    .EXAMPLE
        New-GSMServiceAccount
    .EXAMPLE
        New-GSMServiceAccount -Force
    .NOTES
        The password is never materialized as a plaintext string: it is
        built directly as a SecureString by New-GSMServiceAccountPassword,
        and is never logged, printed, or written to any file other than the
        DPAPI-encrypted one. The encrypted file is current-user- and
        machine-scoped (no -Key), matching Config/*'s existing .gitignore
        exclusion.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount',

        [Parameter()]
        [switch]$Force
    )

    if (-not (Test-GSMElevation)) {
        throw 'New-GSMServiceAccount requires an elevated (Run as Administrator) PowerShell session.'
    }

    $accountExists = Test-GSMAccountPresence -AccountName $AccountName

    if ($accountExists -and -not $Force) {
        return $true
    }

    $securePassword = New-GSMServiceAccountPassword

    try {
        try {
            if ($accountExists) {
                Set-LocalUser -Name $AccountName -Password $securePassword -ErrorAction Stop
            }
            else {
                New-LocalUser -Name $AccountName -Password $securePassword -PasswordNeverExpires -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-GSMLog -Level Error -Message "Failed to provision local service account '$AccountName': $($_.Exception.Message)"
            throw
        }

        try {
            $encryptedPassword = $securePassword | ConvertFrom-SecureString
            $secureFilePath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Config/ServiceAccount.secure.txt'
            Set-Content -Path $secureFilePath -Value $encryptedPassword -ErrorAction Stop
        }
        catch {
            Write-GSMLog -Level Error -Message "Failed to store the encrypted password for '$AccountName': $($_.Exception.Message)"
            throw
        }
    }
    finally {
        $securePassword.Dispose()
    }

    return $true
}

function Set-GSMServiceAccountRights {
    <#
    .SYNOPSIS
        Grants GSM's service account exactly the rights it needs to run
        servers.
    .DESCRIPTION
        Grants SeServiceLogonRight (log on as a service) via secedit, and
        Modify (not Full Control) NTFS permission on Config/, Logs/,
        Reports/, Backups/, and SteamCMD/, all resolved via Get-GSMRootPath.
        Grants nothing beyond these two things: no local admin, no ownership
        changes, no permissions on folders outside this list.
    .PARAMETER AccountName
        Name of the local service account to grant rights to.
    .EXAMPLE
        Set-GSMServiceAccountRights -AccountName 'GSM-ServiceAccount'
    .NOTES
        Throws if granting the logon right or any folder's ACL fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    try {
        Grant-GSMServiceLogonRight -AccountName $AccountName
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to grant SeServiceLogonRight to '$AccountName': $($_.Exception.Message)"
        throw
    }

    $rootPath = Get-GSMRootPath

    foreach ($folder in $script:GSMServiceAccountFolders) {
        $folderPath = Join-Path -Path $rootPath -ChildPath $folder

        try {
            $acl = Get-Acl -Path $folderPath -ErrorAction Stop
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $AccountName,
                [System.Security.AccessControl.FileSystemRights]::Modify,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $folderPath -AclObject $acl -ErrorAction Stop
        }
        catch {
            Write-GSMLog -Level Error -Message "Failed to grant Modify permission on '$folderPath' to '$AccountName': $($_.Exception.Message)"
            throw
        }
    }
}

function Test-GSMServiceAccount {
    <#
    .SYNOPSIS
        Verifies GSM's service account exists and has exactly the expected
        rights.
    .DESCRIPTION
        Checks four conditions independently: the account exists, it is not
        a member of Administrators, it has SeServiceLogonRight, and it has
        the expected Modify ACL on Config/, Logs/, Reports/, Backups/, and
        SteamCMD/. Returns $true only if all four hold. Each failing
        condition is logged via Write-GSMLog with the specific reason.
    .PARAMETER AccountName
        Name of the local service account to verify.
    .EXAMPLE
        Test-GSMServiceAccount -AccountName 'GSM-ServiceAccount'
    .NOTES
        All four conditions are checked (not short-circuited), so every
        failing reason gets logged in a single call.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $isValid = $true

    if (-not (Test-GSMAccountPresence -AccountName $AccountName)) {
        Write-GSMLog -Level Error -Message "Service account '$AccountName' does not exist."
        $isValid = $false
    }

    if (Test-GSMAccountIsAdminMember -AccountName $AccountName) {
        Write-GSMLog -Level Error -Message "Service account '$AccountName' is unexpectedly a member of Administrators."
        $isValid = $false
    }

    if (-not (Test-GSMServiceLogonRight -AccountName $AccountName)) {
        Write-GSMLog -Level Error -Message "Service account '$AccountName' does not have SeServiceLogonRight."
        $isValid = $false
    }

    if (-not (Test-GSMExpectedFolderPermission -AccountName $AccountName)) {
        Write-GSMLog -Level Error -Message "Service account '$AccountName' is missing expected folder permissions."
        $isValid = $false
    }

    return $isValid
}

function Remove-GSMServiceAccount {
    <#
    .SYNOPSIS
        Removes GSM's local service account.
    .DESCRIPTION
        Removes the local account via Remove-LocalUser.
    .PARAMETER AccountName
        Name of the local service account to remove.
    .EXAMPLE
        Remove-GSMServiceAccount -AccountName 'GSM-ServiceAccount'
    .NOTES
        Removing the account leaves its SeServiceLogonRight secedit entry
        behind, referencing a SID that no longer resolves to anything. This
        orphaned entry is harmless (Windows ignores rights entries for SIDs
        that don't exist) and cleaning it up is out of scope for Phase 1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    try {
        Remove-LocalUser -Name $AccountName -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to remove service account '$AccountName': $($_.Exception.Message)"
        throw
    }
}

Export-ModuleMember -Function New-GSMServiceAccount, Set-GSMServiceAccountRights, Test-GSMServiceAccount, Remove-GSMServiceAccount
