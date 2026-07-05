#Requires -Version 7.0
<#
.SYNOPSIS
    JSON configuration engine for GSM.
.DESCRIPTION
    Reads, writes, and validates JSON configuration files. Rejects malformed
    JSON, duplicate top-level keys, out-of-range ports, and unsafe launch
    option characters, per PRD section 10.
#>

Set-StrictMode -Version Latest

# Blocks shell metacharacters that could turn a LaunchOptions value into a
# command injection: ; & | ` $ $() > >> <
$script:UnsafeLaunchOptionPattern = '[;&|`$]|\$\(|>{1,2}|<'

function Get-GSMConfigPropertyValue {
    # Internal helper. Not exported: reads a property from a psobject via
    # PSObject.Properties, returning $null when it doesn't exist instead of
    # letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-GSMConfig {
    <#
    .SYNOPSIS
        Validates a GSM config object and its source JSON text.
    .DESCRIPTION
        Checks required fields, DefaultPort range, unsafe LaunchOptions
        characters, and duplicate top-level JSON keys. Throws on the first
        failure. Returns nothing on success.
    .PARAMETER Config
        The parsed config object (from ConvertFrom-Json) to validate.
    .PARAMETER RawJson
        The original JSON text. Needed only for duplicate-key detection,
        since ConvertFrom-Json silently keeps the last value for a repeated
        key and gives no way to detect the duplicate after parsing.
    .EXAMPLE
        Test-GSMConfig -Config $cfg -RawJson $rawText
    .NOTES
        Assumes a flat config (no nested objects), matching the Plugin.json
        schema. The duplicate-key scan matches every "key": pattern regardless
        of line position and does not track JSON nesting depth; it will need
        rework if nested config objects are introduced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Config,

        [Parameter(Mandatory)]
        [string]$RawJson
    )

    $gameName = Get-GSMConfigPropertyValue -Config $Config -Name 'GameName'
    if (-not $gameName) {
        throw "Config is missing required field 'GameName'."
    }

    $appId = Get-GSMConfigPropertyValue -Config $Config -Name 'AppID'
    if (-not $appId) {
        throw "Config is missing required field 'AppID'."
    }

    $port = Get-GSMConfigPropertyValue -Config $Config -Name 'DefaultPort'
    if ($null -ne $port) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) {
            throw "DefaultPort '$port' is invalid. Must be an integer between 1 and 65535."
        }
    }

    $launchOptions = Get-GSMConfigPropertyValue -Config $Config -Name 'LaunchOptions'
    if ($launchOptions -and ($launchOptions -match $script:UnsafeLaunchOptionPattern)) {
        throw "LaunchOptions contains unsafe characters. Shell metacharacters are not allowed."
    }

    $topLevelKeys = [System.Collections.Generic.List[string]]::new()
    $keyMatches = [regex]::Matches($RawJson, '"([^"]+)"\s*:')
    foreach ($match in $keyMatches) {
        $topLevelKeys.Add($match.Groups[1].Value)
    }
    $duplicates = $topLevelKeys | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($duplicates) {
        $names = ($duplicates | ForEach-Object { $_.Name }) -join ', '
        throw "Config contains duplicate key(s): $names"
    }
}

function Get-GSMConfig {
    <#
    .SYNOPSIS
        Reads and validates a GSM JSON config file.
    .DESCRIPTION
        Loads the file at Path, parses it as JSON, validates it with
        Test-GSMConfig, and returns the parsed object.
    .PARAMETER Path
        Full path to the JSON config file.
    .EXAMPLE
        $cfg = Get-GSMConfig -Path './Config/insurgency2014.json'
    .NOTES
        Throws on missing file, malformed JSON, or failed validation. Callers
        resolve Path via Core/Utilities.psm1, never hard-code it here.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    try {
        $rawJson = Get-Content -Path $Path -Raw -ErrorAction Stop
    }
    catch {
        throw "Failed to read config file '$Path': $($_.Exception.Message)"
    }

    try {
        $config = $rawJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Config file '$Path' contains malformed JSON: $($_.Exception.Message)"
    }

    Test-GSMConfig -Config $config -RawJson $rawJson

    return $config
}

function Set-GSMConfig {
    <#
    .SYNOPSIS
        Validates and writes a GSM config object to disk as JSON.
    .DESCRIPTION
        Serializes Config to JSON, validates it with Test-GSMConfig, then
        writes it to Path.
    .PARAMETER Path
        Full path to write the JSON config file to.
    .PARAMETER Config
        The config object to serialize and write.
    .EXAMPLE
        Set-GSMConfig -Path './Config/insurgency2014.json' -Config $cfg
    .NOTES
        Does not back up the existing file before overwriting. Backup/restore
        is Core/Backup.psm1, Phase 3.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Config
    )

    $rawJson = $Config | ConvertTo-Json -Depth 10

    Test-GSMConfig -Config $Config -RawJson $rawJson

    try {
        Set-Content -Path $Path -Value $rawJson -ErrorAction Stop
    }
    catch {
        throw "Failed to write config file '$Path': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Get-GSMConfig, Set-GSMConfig, Test-GSMConfig
