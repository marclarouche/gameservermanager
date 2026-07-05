#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helper functions.
.DESCRIPTION
    Phase 1. Path resolution, SHA-256 hashing, and console prompt helpers used
    across Core and Plugins. No game- or plugin-specific logic here.
#>

Set-StrictMode -Version Latest

function Get-GSMRootPath {
    <#
    .SYNOPSIS
        Returns the GSM repository root path.
    .DESCRIPTION
        Resolves the repository root as the parent of this module's own
        directory (Core/), so the path is never hard-coded. Every other Core
        module should call this rather than resolving the root itself.
    .EXAMPLE
        $root = Get-GSMRootPath
    .NOTES
        Returns the parent of $PSScriptRoot, i.e. the folder containing Core/.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Get-FileHashSHA256 {
    <#
    .SYNOPSIS
        Computes the SHA-256 hash of a file.
    .DESCRIPTION
        Thin wrapper around Get-FileHash -Algorithm SHA256, returning just the
        hash string. Used for verifying SteamCMD downloads.
    .PARAMETER Path
        Full path to the file to hash.
    .EXAMPLE
        Get-FileHashSHA256 -Path 'D:\GSM\SteamCMD\steamcmd.exe'
    .NOTES
        Throws if Path does not exist or cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }

    try {
        $result = Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop
        return $result.Hash
    }
    catch {
        throw "Failed to compute SHA-256 hash for '$Path': $($_.Exception.Message)"
    }
}

function Read-GSMPrompt {
    <#
    .SYNOPSIS
        Prompts the user for console input, optionally restricted to a set of
        valid values.
    .DESCRIPTION
        Displays Message via Read-Host and returns the response. If
        ValidValues is supplied, reprompts on any response not in that list
        until a valid one is entered.
    .PARAMETER Message
        The prompt text shown to the user.
    .PARAMETER ValidValues
        Optional list of acceptable responses. When omitted, any input is
        accepted.
    .EXAMPLE
        Read-GSMPrompt -Message 'Start the server now?' -ValidValues @('y', 'n')
    .NOTES
        Comparison against ValidValues is case-insensitive, matching default
        PowerShell string comparison behavior.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [string[]]$ValidValues
    )

    while ($true) {
        $response = Read-Host -Prompt $Message

        if (-not $ValidValues -or $ValidValues.Count -eq 0) {
            return $response
        }

        if ($ValidValues -contains $response) {
            return $response
        }

        Write-Warning "Invalid input. Valid values: $($ValidValues -join ', ')"
    }
}

Export-ModuleMember -Function Get-GSMRootPath, Get-FileHashSHA256, Read-GSMPrompt
