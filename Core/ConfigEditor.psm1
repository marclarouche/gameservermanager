#Requires -Version 7.0
<#
.SYNOPSIS
    Generic interactive server config editor for GSM (PRD section 8, item
    12).
.DESCRIPTION
    Phase 1. Prompts for a game server's config fields, validates the
    result via the plugin's own Test-<Game>ServerConfig function, backs up
    any existing config before overwriting it, and writes the result to
    Config/<FolderName>.json.

    Entirely game-agnostic, the same way Core/ProcessManager.psm1 is: every
    plugin's New-<Game>Config is a thin wrapper that supplies its own
    identity (FolderName, GameName, AppID, DefaultPort), whether it needs a
    Mode field or Workshop support, and the names of its own
    Get-<Game>Maps / Get-<Game>Modes / Test-<Game>ServerConfig functions.
    No plugin builds any of the prompting, backup, or file-writing logic
    itself.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force

function Get-GSMConfigEditorPropertyValue {
    # Internal helper. Not exported: reads a property from an existing
    # config psobject (used to pre-populate prompts), returning $null when
    # it doesn't exist or Config itself is $null, instead of letting
    # dot-notation throw under Set-StrictMode -Version Latest.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [psobject]$Config,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Config) {
        return $null
    }

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Read-GSMConfigEditorInt {
    # Internal helper. Not exported: prompts for an integer, reprompting on
    # anything that doesn't parse as one. No range checking here - that's
    # the plugin's own Test-<Game>ServerConfig function's job, called once
    # the whole config is assembled.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    while ($true) {
        $response = Read-Host -Prompt $Message
        $parsedValue = 0
        if ([int]::TryParse($response, [ref]$parsedValue)) {
            return $parsedValue
        }
        Write-Warning "'$response' is not a valid whole number."
    }
}

function Backup-GSMExistingConfig {
    # Internal helper. Not exported: copies an existing Config/<FolderName>.json
    # to Backups/<FolderName>-<timestamp>.json before it gets overwritten, per
    # PRD section 10's "Auto-backup before any update or config change"
    # requirement. A no-op if there's nothing to back up yet.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        return
    }

    $backupsDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Backups'
    New-Item -ItemType Directory -Path $backupsDirectory -Force -ErrorAction SilentlyContinue | Out-Null

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backupPath = Join-Path -Path $backupsDirectory -ChildPath "$FolderName-$timestamp.json"

    try {
        Copy-Item -Path $ConfigPath -Destination $backupPath -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Warning -Message "Failed to back up existing config for '$FolderName' to '$backupPath' before overwriting it: $($_.Exception.Message)"
    }
}

function New-GSMServerConfig {
    <#
    .SYNOPSIS
        Interactively builds and writes a game server's config file.
    .DESCRIPTION
        Prompts for Map (from GetMapsFunctionName's list), Mode (from
        GetModesFunctionName's list, only if RequiresMode is set), Port,
        MaxPlayers, RCONPassword, and WorkshopItems (only if SupportsWorkshop
        is set). Pre-populates each prompt's displayed current value from
        Config/<FolderName>.json if it already exists. Assembles a candidate
        config object and validates it by calling
        TestServerConfigFunctionName; on failure, shows the validation error
        and re-prompts every field. Once valid, backs up any existing config
        to Backups/<FolderName>-<timestamp>.json, then writes the result to
        Config/<FolderName>.json via Core/Config.psm1's Set-GSMConfig.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014'),
        used for the config and backup file paths. Deliberately not
        GameName: L4D and L4D2 share the GameName "Left4Dead" (see their
        Plugin.json files), so keying files by GameName would make the two
        plugins overwrite each other's config. This matches the FolderName
        -keying convention already used by Config/CustomMaps.json.
    .PARAMETER GameName
        The plugin's Plugin.json GameName value (e.g. 'Insurgency'), written
        into the config's own GameName field so Core/Menu.psm1's
        Invoke-GSMAction can find the right plugin for it.
    .PARAMETER AppID
        The plugin's Plugin.json AppID value, written into the config as-is.
    .PARAMETER DefaultPort
        The plugin's Plugin.json DefaultPort value, shown as the current
        value on first configuration (before any config file exists).
    .PARAMETER GetMapsFunctionName
        Name of the plugin's own Get-<Game>Maps function.
    .PARAMETER TestServerConfigFunctionName
        Name of the plugin's own Test-<Game>ServerConfig function, used to
        validate the assembled config before it's written.
    .PARAMETER GetModesFunctionName
        Name of the plugin's own Get-<Game>Modes function. Required when
        RequiresMode is set; ignored otherwise.
    .PARAMETER RequiresMode
        Whether this plugin's config needs a Mode field (true for
        Insurgency2014, L4D, and L4D2; false for TeamFortress2 and
        CounterStrikeSource, whose map names self-encode mode).
    .PARAMETER SupportsWorkshop
        Whether this plugin's config needs a WorkshopItems field (true for
        Insurgency2014, TeamFortress2, and L4D2; false for
        CounterStrikeSource and L4D).
    .EXAMPLE
        New-GSMServerConfig -FolderName 'Insurgency2014' -GameName 'Insurgency' -AppID '237410' -DefaultPort 27015 -GetMapsFunctionName 'Get-Insurgency2014Maps' -GetModesFunctionName 'Get-Insurgency2014Modes' -TestServerConfigFunctionName 'Test-Insurgency2014ServerConfig' -RequiresMode -SupportsWorkshop
    .NOTES
        Loops re-prompting the whole config, rather than a single field,
        when TestServerConfigFunctionName rejects it: this module has no
        plugin-specific knowledge of which field a given validation error
        maps to (e.g. MaxPlayers' valid range differs per game), so it
        relies entirely on the plugin's own validation function as the
        source of truth rather than duplicating range logic here.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$GameName,

        [Parameter(Mandatory)]
        [string]$AppID,

        [Parameter(Mandatory)]
        [int]$DefaultPort,

        [Parameter(Mandatory)]
        [string]$GetMapsFunctionName,

        [Parameter(Mandatory)]
        [string]$TestServerConfigFunctionName,

        [Parameter()]
        [string]$GetModesFunctionName,

        [Parameter()]
        [switch]$RequiresMode,

        [Parameter()]
        [switch]$SupportsWorkshop
    )

    if ($RequiresMode -and -not $GetModesFunctionName) {
        throw 'GetModesFunctionName is required when -RequiresMode is set.'
    }

    $getMapsCommand = Get-Command -Name $GetMapsFunctionName -ErrorAction SilentlyContinue
    if (-not $getMapsCommand) {
        throw "Maps function '$GetMapsFunctionName' is not available. Is the plugin imported?"
    }

    $testServerConfigCommand = Get-Command -Name $TestServerConfigFunctionName -ErrorAction SilentlyContinue
    if (-not $testServerConfigCommand) {
        throw "Validation function '$TestServerConfigFunctionName' is not available. Is the plugin imported?"
    }

    $getModesCommand = $null
    if ($RequiresMode) {
        $getModesCommand = Get-Command -Name $GetModesFunctionName -ErrorAction SilentlyContinue
        if (-not $getModesCommand) {
            throw "Modes function '$GetModesFunctionName' is not available. Is the plugin imported?"
        }
    }

    $configPath = Join-Path -Path (Get-GSMRootPath) -ChildPath "Config/$FolderName.json"

    $existingConfig = $null
    if (Test-Path -Path $configPath -PathType Leaf) {
        try {
            $existingConfig = Get-GSMConfig -Path $configPath
        }
        catch {
            Write-GSMLog -Level Warning -Message "Existing config for '$FolderName' at '$configPath' could not be read and will be ignored for pre-population: $($_.Exception.Message)"
        }
    }

    while ($true) {
        $maps = @(& $getMapsCommand)
        $currentMap = Get-GSMConfigEditorPropertyValue -Config $existingConfig -Name 'Map'
        $mapPromptMessage = if ($currentMap) { "Map (current: $currentMap)" } else { 'Map' }
        $map = Read-GSMPrompt -Message $mapPromptMessage -ValidValues $maps

        $mode = $null
        if ($RequiresMode) {
            $modes = @(& $getModesCommand)
            $currentMode = Get-GSMConfigEditorPropertyValue -Config $existingConfig -Name 'Mode'
            $modePromptMessage = if ($currentMode) { "Mode (current: $currentMode)" } else { 'Mode' }
            $mode = Read-GSMPrompt -Message $modePromptMessage -ValidValues $modes
        }

        $currentPort = Get-GSMConfigEditorPropertyValue -Config $existingConfig -Name 'DefaultPort'
        $portDisplayDefault = if ($null -ne $currentPort) { $currentPort } else { $DefaultPort }
        $port = Read-GSMConfigEditorInt -Message "DefaultPort (current: $portDisplayDefault)"

        $currentMaxPlayers = Get-GSMConfigEditorPropertyValue -Config $existingConfig -Name 'MaxPlayers'
        $maxPlayersPromptMessage = if ($null -ne $currentMaxPlayers) { "MaxPlayers (current: $currentMaxPlayers)" } else { 'MaxPlayers' }
        $maxPlayers = Read-GSMConfigEditorInt -Message $maxPlayersPromptMessage

        $currentRconPassword = Get-GSMConfigEditorPropertyValue -Config $existingConfig -Name 'RCONPassword'
        $rconPromptMessage = if ($currentRconPassword) { 'RCONPassword (leave blank for none, currently set)' } else { 'RCONPassword (leave blank for none)' }
        $rconPassword = Read-Host -Prompt $rconPromptMessage
        if (-not $rconPassword) {
            $rconPassword = ''
        }

        $configObject = [PSCustomObject]@{
            GameName     = $GameName
            AppID        = $AppID
            DefaultPort  = $port
            Map          = $map
            MaxPlayers   = $maxPlayers
            RCONPassword = $rconPassword
        }

        if ($RequiresMode) {
            Add-Member -InputObject $configObject -NotePropertyName 'Mode' -NotePropertyValue $mode
        }

        if ($SupportsWorkshop) {
            $currentWorkshopItems = @(Get-GSMConfigEditorPropertyValue -Config $existingConfig -Name 'WorkshopItems')
            $workshopPromptMessage = if ($currentWorkshopItems.Count -gt 0) { "WorkshopItems, comma-separated (current: $($currentWorkshopItems -join ', '))" } else { 'WorkshopItems, comma-separated (leave blank for none)' }
            $workshopResponse = Read-Host -Prompt $workshopPromptMessage
            $workshopItems = @()
            if ($workshopResponse) {
                $workshopItems = @($workshopResponse -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            Add-Member -InputObject $configObject -NotePropertyName 'WorkshopItems' -NotePropertyValue $workshopItems
        }

        try {
            & $testServerConfigCommand -Config $configObject
        }
        catch {
            Write-Warning "This config is not valid: $($_.Exception.Message)"
            Write-Warning 'Please re-enter the configuration.'
            continue
        }

        Backup-GSMExistingConfig -FolderName $FolderName -ConfigPath $configPath
        Set-GSMConfig -Path $configPath -Config $configObject

        return $true
    }
}

Export-ModuleMember -Function New-GSMServerConfig
