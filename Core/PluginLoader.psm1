#Requires -Version 7.0
<#
.SYNOPSIS
    Plugin discovery and validation.
.DESCRIPTION
    Phase 1. Scans Plugins/ for folders containing a valid Plugin.json,
    validates against the schema in PRD section 7, and imports the plugin's
    modules. Rejects plugins that fail validation.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')

function Get-GSMPluginPropertyValue {
    # Internal helper. Not exported: reads a property from a parsed Plugin.json
    # psobject via PSObject.Properties, returning $null when it doesn't exist
    # instead of letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. Mirrors Get-GSMConfigPropertyValue in
    # Core/Config.psm1.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [psobject]$PluginJson,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $PluginJson.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-GSMPlugin {
    <#
    .SYNOPSIS
        Validates a parsed Plugin.json object against the PRD section 7 schema.
    .DESCRIPTION
        Checks that GameName, Version, AppID, Engine, and Executable are all
        non-empty strings, DefaultPort is an integer (int or long, since
        ConvertFrom-Json returns long for whole numbers) between 1 and 65535,
        and SupportsWorkshop / SupportsRCON are booleans. Throws on the first
        failure. Returns nothing on success.
    .PARAMETER PluginJson
        The parsed Plugin.json object (from ConvertFrom-Json) to validate.
    .EXAMPLE
        Test-GSMPlugin -PluginJson $pluginJson
    .NOTES
        Uses Get-GSMPluginPropertyValue for every property read so a missing
        field returns $null instead of throwing under strict mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$PluginJson
    )

    $requiredStringFields = @('GameName', 'Version', 'AppID', 'Engine', 'Executable')
    foreach ($field in $requiredStringFields) {
        $value = Get-GSMPluginPropertyValue -PluginJson $PluginJson -Name $field
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Plugin.json field '$field' must be a non-empty string."
        }
    }

    $port = Get-GSMPluginPropertyValue -PluginJson $PluginJson -Name 'DefaultPort'
    if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1 -or $port -gt 65535) {
        throw "Plugin.json DefaultPort '$port' is invalid. Must be an integer between 1 and 65535."
    }

    $requiredBoolFields = @('SupportsWorkshop', 'SupportsRCON')
    foreach ($field in $requiredBoolFields) {
        $value = Get-GSMPluginPropertyValue -PluginJson $PluginJson -Name $field
        if ($value -isnot [bool]) {
            throw "Plugin.json field '$field' must be a boolean (true or false)."
        }
    }
}

function Find-GSMPlugins {
    <#
    .SYNOPSIS
        Discovers and validates all game plugins under a Plugins/ directory.
    .DESCRIPTION
        Scans each subfolder of PluginsDirectory for a Plugin.json file,
        validates it with Test-GSMPlugin, and returns the parsed object for
        every plugin that passes. A subfolder with no Plugin.json, malformed
        JSON, or a Plugin.json that fails validation is skipped rather than
        treated as fatal: a warning is logged via Write-GSMLog and scanning
        continues with the rest.
    .PARAMETER PluginsDirectory
        Directory to scan for plugin subfolders. Defaults to Plugins/ under
        the repo root, resolved via Get-GSMRootPath.
    .EXAMPLE
        $plugins = Find-GSMPlugins
    .NOTES
        Each returned object is the parsed Plugin.json with a FolderName
        property added, so callers such as Import-GSMPlugin know which
        subfolder it came from.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter()]
        [string]$PluginsDirectory = (Join-Path -Path (Get-GSMRootPath) -ChildPath 'Plugins')
    )

    if (-not (Test-Path -Path $PluginsDirectory -PathType Container)) {
        throw "Plugins directory not found: $PluginsDirectory"
    }

    try {
        $folders = Get-ChildItem -Path $PluginsDirectory -Directory -ErrorAction Stop
    }
    catch {
        throw "Failed to scan plugins directory '$PluginsDirectory': $($_.Exception.Message)"
    }

    $validPlugins = [System.Collections.Generic.List[psobject]]::new()

    foreach ($folder in $folders) {
        $pluginJsonPath = Join-Path -Path $folder.FullName -ChildPath 'Plugin.json'

        if (-not (Test-Path -Path $pluginJsonPath -PathType Leaf)) {
            Write-GSMLog -Level Warning -Message "Skipping plugin folder '$($folder.Name)': no Plugin.json found."
            continue
        }

        try {
            $rawJson = Get-Content -Path $pluginJsonPath -Raw -ErrorAction Stop
            $pluginJson = $rawJson | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-GSMLog -Level Warning -Message "Skipping plugin folder '$($folder.Name)': Plugin.json is malformed: $($_.Exception.Message)"
            continue
        }

        try {
            Test-GSMPlugin -PluginJson $pluginJson
        }
        catch {
            Write-GSMLog -Level Warning -Message "Skipping plugin folder '$($folder.Name)': $($_.Exception.Message)"
            continue
        }

        Add-Member -InputObject $pluginJson -NotePropertyName 'FolderName' -NotePropertyValue $folder.Name -Force
        $validPlugins.Add($pluginJson)
    }

    return $validPlugins.ToArray()
}

function Import-GSMPlugin {
    <#
    .SYNOPSIS
        Imports a plugin's PowerShell modules.
    .DESCRIPTION
        Imports Install.psm1, Server.psm1, Maps.psm1, and Modes.psm1 from the
        given plugin subfolder via Import-Module -Global, so their exported
        functions are available to the rest of the session (e.g. Menu.psm1),
        not just within PluginLoader's own module scope. Any Install/Server/
        Maps/Modes modules already loaded from a different plugin are removed
        first, so only one plugin's modules are ever loaded at a time.
    .PARAMETER FolderName
        Name of the plugin subfolder under PluginsDirectory, e.g.
        'Insurgency2014'.
    .PARAMETER PluginsDirectory
        Directory containing plugin subfolders. Defaults to Plugins/ under
        the repo root, resolved via Get-GSMRootPath.
    .EXAMPLE
        Import-GSMPlugin -FolderName 'Insurgency2014'
    .NOTES
        Throws if the plugin folder or any of its four expected module files
        is missing, or if a module fails to import.

        Every plugin's module files share the same bare names (Install,
        Server, Maps, Modes). Import-Module -Force alone does not guarantee
        a previously loaded module of the same name gets replaced when it
        was loaded from a different plugin's path, so Remove-Module runs
        first to guarantee the old plugin's copies are gone before the new
        ones load.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter()]
        [string]$PluginsDirectory = (Join-Path -Path (Get-GSMRootPath) -ChildPath 'Plugins')
    )

    $pluginPath = Join-Path -Path $PluginsDirectory -ChildPath $FolderName

    if (-not (Test-Path -Path $pluginPath -PathType Container)) {
        throw "Plugin folder not found: $pluginPath"
    }

    $moduleFileNames = @('Install.psm1', 'Server.psm1', 'Maps.psm1', 'Modes.psm1')

    Remove-Module -Name 'Install', 'Server', 'Maps', 'Modes' -Force -ErrorAction SilentlyContinue

    foreach ($moduleFileName in $moduleFileNames) {
        $modulePath = Join-Path -Path $pluginPath -ChildPath $moduleFileName

        if (-not (Test-Path -Path $modulePath -PathType Leaf)) {
            throw "Plugin '$FolderName' is missing expected module '$moduleFileName'."
        }

        try {
            Import-Module -Name $modulePath -Global -Force -ErrorAction Stop
        }
        catch {
            throw "Failed to import '$modulePath' for plugin '$FolderName': $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function Find-GSMPlugins, Test-GSMPlugin, Import-GSMPlugin
