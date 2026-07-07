#Requires -Version 7.0
<#
.SYNOPSIS
    Least-privilege local service account provisioning for GSM.
.DESCRIPTION
    Phase 1. Creates and configures a dedicated local Windows account under
    which game servers run, instead of the interactive admin account. Grants
    only what's needed: SeServiceLogonRight (log on as a service - reserved
    for a future Phase 1 Windows Service registration, Core/Service.psm1),
    SeBatchLogonRight (log on as a batch job - used today by
    Core/ProcessManager.psm1's Scheduled Task-based server launch), and
    Modify access to GSM's install/config/log/backup/server folders. Does not
    grant local admin rights.

    This module only provisions the account. Registering a real Windows
    Service under this account (with a service wrapper, since srcds.exe and
    similar dedicated-server executables don't speak the Service Control
    Manager protocol) is Core/Service.psm1 (Phase 2).
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force

# Folders the service account needs Modify (not Full Control) access to.
# 'Servers' holds each plugin's installed game files, which the account
# needs write access to while a server it launches is running (logs,
# addon/workshop content, save data, etc.).
$script:GSMServiceAccountFolders = @('Config', 'Logs', 'Reports', 'Backups', 'SteamCMD', 'Servers')

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
    # Internal helper. Not exported: one of Test-GSMServiceAccount's
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
    # Internal helper. Not exported: one of Test-GSMServiceAccount's
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

function Grant-GSMUserRights {
    # Internal helper. Not exported: grants one or more user-rights-assignment
    # privileges (e.g. SeServiceLogonRight, SeBatchLogonRight) to AccountName
    # in a single secedit export/edit/import round-trip, since no PowerShell
    # cmdlet manages user rights assignments directly. Granting multiple
    # rights in one round-trip (rather than one secedit export/configure
    # cycle per right) halves the number of secedit.exe invocations and the
    # number of places a partial failure could leave things inconsistent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName,

        [Parameter(Mandatory)]
        [string[]]$RightNames
    )

    $sid = Get-GSMAccountSID -AccountName $AccountName
    $sidToken = "*$sid"

    $workDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "gsm-secedit-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

    try {
        $cfgPath = Join-Path -Path $workDirectory -ChildPath 'secedit-export.inf'
        $dbPath = Join-Path -Path $workDirectory -ChildPath 'secedit.sdb'

        $exportProcess = Start-Process -FilePath 'secedit.exe' -ArgumentList @('/export', '/cfg', $cfgPath, '/areas', 'USER_RIGHTS') -Wait -NoNewWindow -PassThru -ErrorAction Stop
        if ($exportProcess.ExitCode -ne 0) {
            throw "secedit.exe /export exited with code $($exportProcess.ExitCode) while exporting user rights."
        }

        $lines = Get-Content -Path $cfgPath
        $updatedLines = [System.Collections.Generic.List[string]]::new()
        $foundRights = @{}
        foreach ($rightName in $RightNames) {
            $foundRights[$rightName] = $false
        }

        foreach ($line in $lines) {
            $matchedRight = $RightNames | Where-Object { $line -match "^\s*$([regex]::Escape($_))\s*=\s*(.*)$" } | Select-Object -First 1

            if ($matchedRight) {
                $null = $line -match "^\s*$([regex]::Escape($matchedRight))\s*=\s*(.*)$"
                $foundRights[$matchedRight] = $true
                $existingSids = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($existingSids -notcontains $sidToken) {
                    $existingSids += $sidToken
                }
                $updatedLines.Add("$matchedRight = " + ($existingSids -join ','))
            }
            else {
                $updatedLines.Add($line)
            }
        }

        $missingRightNames = @($RightNames | Where-Object { -not $foundRights[$_] })
        if ($missingRightNames.Count -gt 0) {
            $withInsertedRights = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $updatedLines) {
                $withInsertedRights.Add($line)
                if ($line.Trim() -eq '[Privilege Rights]') {
                    foreach ($missingRightName in $missingRightNames) {
                        $withInsertedRights.Add("$missingRightName = $sidToken")
                    }
                }
            }
            $updatedLines = $withInsertedRights
        }

        Set-Content -Path $cfgPath -Value $updatedLines

        $configureProcess = Start-Process -FilePath 'secedit.exe' -ArgumentList @('/configure', '/db', $dbPath, '/cfg', $cfgPath, '/areas', 'USER_RIGHTS') -Wait -NoNewWindow -PassThru -ErrorAction Stop
        if ($configureProcess.ExitCode -ne 0) {
            throw "secedit.exe /configure exited with code $($configureProcess.ExitCode) while granting $($RightNames -join ', ')."
        }
    }
    finally {
        Remove-Item -Path $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-GSMUserRight {
    # Internal helper. Not exported: one of Test-GSMServiceAccount's
    # independently checked conditions. Checks a single named user-rights
    # -assignment privilege (e.g. SeServiceLogonRight or SeBatchLogonRight).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName,

        [Parameter(Mandatory)]
        [string]$RightName
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
        $rightLine = $lines | Where-Object { $_ -match "^\s*$([regex]::Escape($RightName))\s*=\s*(.*)$" } | Select-Object -First 1

        if (-not $rightLine) {
            return $false
        }

        $null = $rightLine -match "^\s*$([regex]::Escape($RightName))\s*=\s*(.*)$"
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
    # Internal helper. Not exported: one of Test-GSMServiceAccount's
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
        Grants SeServiceLogonRight (log on as a service, reserved for a
        future real Windows Service registration) and SeBatchLogonRight (log
        on as a batch job, used today by Core/ProcessManager.psm1's
        Scheduled Task-based server launch) via secedit, and Modify (not
        Full Control) NTFS permission on Config/, Logs/, Reports/, Backups/,
        SteamCMD/, and Servers/, all resolved via Get-GSMRootPath. Grants
        nothing beyond these: no local admin, no ownership changes, no
        permissions on folders outside this list.
    .PARAMETER AccountName
        Name of the local service account to grant rights to.
    .EXAMPLE
        Set-GSMServiceAccountRights -AccountName 'GSM-ServiceAccount'
    .NOTES
        Throws if granting either user right or any folder's ACL fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName
    )

    try {
        Grant-GSMUserRights -AccountName $AccountName -RightNames @('SeServiceLogonRight', 'SeBatchLogonRight')
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to grant user rights to '$AccountName': $($_.Exception.Message)"
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
        Checks five conditions independently: the account exists, it is not
        a member of Administrators, it has SeServiceLogonRight, it has
        SeBatchLogonRight, and it has the expected Modify ACL on Config/,
        Logs/, Reports/, Backups/, SteamCMD/, and Servers/. Returns $true
        only if all five hold. Each failing condition is logged via
        Write-GSMLog with the specific reason.
    .PARAMETER AccountName
        Name of the local service account to verify.
    .EXAMPLE
        Test-GSMServiceAccount -AccountName 'GSM-ServiceAccount'
    .NOTES
        All five conditions are checked (not short-circuited), so every
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

    if (-not (Test-GSMUserRight -AccountName $AccountName -RightName 'SeServiceLogonRight')) {
        Write-GSMLog -Level Error -Message "Service account '$AccountName' does not have SeServiceLogonRight."
        $isValid = $false
    }

    if (-not (Test-GSMUserRight -AccountName $AccountName -RightName 'SeBatchLogonRight')) {
        Write-GSMLog -Level Error -Message "Service account '$AccountName' does not have SeBatchLogonRight."
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
        Removing the account leaves its secedit user-rights entries behind,
        referencing a SID that no longer resolves to anything. These
        orphaned entries are harmless (Windows ignores rights entries for
        SIDs that don't exist) and cleaning them up is out of scope for
        Phase 1.
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

function Get-GSMServiceAccountCredential {
    <#
    .SYNOPSIS
        Builds a PSCredential for GSM's service account from its stored,
        DPAPI-encrypted password.
    .DESCRIPTION
        Reads Config/ServiceAccount.secure.txt (written by
        New-GSMServiceAccount), decrypts it via ConvertTo-SecureString
        (which only succeeds for the same Windows user and machine that
        encrypted it), and returns a PSCredential built from AccountName and
        the decrypted password.
    .PARAMETER AccountName
        Name of the local service account. Defaults to 'GSM-ServiceAccount'.
    .EXAMPLE
        $credential = Get-GSMServiceAccountCredential
    .NOTES
        Core/ProcessManager.psm1 uses this to register a Scheduled Task that
        runs a game server as this account. Registering a Scheduled Task
        with a stored credential requires Windows Task Scheduler's own API
        to receive the password as a plain string at registration time -
        there is no SecureString-accepting overload for
        Register-ScheduledTask. That is a Windows API limitation, not a
        design choice made here. Callers must extract the plaintext (via
        this credential's GetNetworkCredential().Password) only immediately
        before calling Register-ScheduledTask, and must never log or persist
        it.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter()]
        [string]$AccountName = 'GSM-ServiceAccount'
    )

    $secureFilePath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Config/ServiceAccount.secure.txt'

    if (-not (Test-Path -Path $secureFilePath -PathType Leaf)) {
        throw "No stored credential found for '$AccountName' at '$secureFilePath'. Run New-GSMServiceAccount first."
    }

    try {
        # .Trim() matters here: Get-Content -Raw returns the file's exact
        # bytes, trailing newline included (Set-Content always appends one),
        # and ConvertTo-SecureString rejects that trailing whitespace as an
        # invalid format.
        $encryptedPassword = (Get-Content -Path $secureFilePath -Raw -ErrorAction Stop).Trim()
        $securePassword = ConvertTo-SecureString -String $encryptedPassword -ErrorAction Stop
    }
    catch {
        throw "Failed to decrypt the stored credential for '$AccountName': $($_.Exception.Message)"
    }

    return [pscredential]::new($AccountName, $securePassword)
}

Export-ModuleMember -Function New-GSMServiceAccount, Set-GSMServiceAccountRights, Test-GSMServiceAccount, Remove-GSMServiceAccount, Get-GSMServiceAccountCredential
