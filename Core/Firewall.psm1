#Requires -Version 7.0
<#
.SYNOPSIS
    Windows Firewall rule management for GSM server instances.
.DESCRIPTION
    Phase 3 (PRD section 9). Uses the built-in NetSecurity module
    (New-NetFirewallRule, Remove-NetFirewallRule, Get-NetFirewallRule) to
    open and track inbound firewall rules for each server instance's game
    port. No external tool, no bundling - NetSecurity ships with Windows.

    "Instance" here means a plugin folder (Config/<FolderName>.json), the
    same one-server-per-folder model every other Core module uses - GSM has
    no separate multi-instance-per-plugin concept (see PRD section 4,
    "Multi-server orchestration" is a non-goal).

    Inbound rules only: dedicated game servers need player connections let
    in, and Windows' default outbound-allow policy already covers the
    server's own outbound traffic (Steam auth, master server registration,
    etc.) with no explicit rule needed.
.NOTES
    Rule identity (the -Name passed to New-NetFirewallRule, which must be
    unique - unlike -DisplayName, duplicates aren't allowed) is
    "GSM-<FolderName>-<Port>-<Protocol>", e.g. "GSM-Insurgency2014-27015-TCP".
    A port opened for both TCP and UDP is therefore two rule objects, not
    one: NetFirewallRule's -Protocol parameter takes a single protocol per
    rule, so covering both protocols for one port has no single-object
    representation. -DisplayName is set to the same string as -Name, so
    Remove-GSMFirewallRule and Get-GSMFirewallRuleStatus can find every rule
    for a folder with one -DisplayName wildcard query.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PluginLoader.psm1') -Force

function Get-GSMFirewallPluginJson {
    # Internal helper. Not exported: resolves and validates
    # Plugins/<FolderName>/Plugin.json, reusing Core/PluginLoader.psm1's own
    # Test-GSMPlugin rather than duplicating Plugin.json schema validation
    # here.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $pluginJsonPath = Join-Path -Path (Get-GSMRootPath) -ChildPath "Plugins/$FolderName/Plugin.json"

    if (-not (Test-Path -Path $pluginJsonPath -PathType Leaf)) {
        throw "Plugin.json not found for '$FolderName' at '$pluginJsonPath'."
    }

    try {
        $rawJson = Get-Content -Path $pluginJsonPath -Raw -ErrorAction Stop
        $pluginJson = $rawJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read Plugin.json for '$FolderName': $($_.Exception.Message)"
    }

    Test-GSMPlugin -PluginJson $pluginJson

    return $pluginJson
}

function Get-GSMFirewallProtocolList {
    # Internal helper. Not exported: resolves which protocol(s) a rule
    # should be created for from Plugin.json's optional 'Protocol' field.
    # None of the five Phase 1 plugins set this field today, so every
    # existing plugin resolves to the default of both TCP and UDP; the
    # field exists so a future plugin can narrow that if its game only
    # listens on one protocol.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [psobject]$PluginJson
    )

    $property = $PluginJson.PSObject.Properties['Protocol']
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace($property.Value)) {
        return [string[]]@('TCP', 'UDP')
    }

    $value = $property.Value
    if ($value -notin @('TCP', 'UDP', 'Both')) {
        throw "Plugin.json field 'Protocol' value '$value' is invalid. Must be 'TCP', 'UDP', or 'Both'."
    }

    if ($value -eq 'Both') {
        return [string[]]@('TCP', 'UDP')
    }

    return [string[]]@($value)
}

function Get-GSMFirewallRuleName {
    # Internal helper. Not exported: builds the "GSM-<FolderName>-<Port>-
    # <Protocol>" rule identity shared by Add-GSMFirewallRule (creation),
    # Remove-GSMFirewallRule, and Get-GSMFirewallRuleStatus (both of which
    # match on the "GSM-<FolderName>-" prefix instead of rebuilding a full
    # name, so they work even if the port on file has since changed).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter(Mandatory)]
        [string]$Protocol
    )

    return "GSM-$FolderName-$Port-$Protocol"
}

function Add-GSMFirewallRule {
    <#
    .SYNOPSIS
        Opens inbound Windows Firewall rule(s) for a server instance's game
        port.
    .DESCRIPTION
        Reads the instance's Plugins/<FolderName>/Plugin.json for its
        DefaultPort and optional Protocol field (defaulting to both TCP and
        UDP when Protocol is absent), then creates one inbound Allow rule
        per resolved protocol, named "GSM-<FolderName>-<Port>-<Protocol>".

        Idempotent: if a rule with that exact name already exists, it is
        left alone (and its name still returned) unless -Force is set, in
        which case the existing rule is removed and recreated fresh.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER Port
        Overrides the port read from Plugin.json's DefaultPort. Use this
        when an instance's live config has a different port than the
        plugin's default.
    .PARAMETER Force
        Remove and recreate any existing rule of the same name instead of
        leaving it alone.
    .EXAMPLE
        Add-GSMFirewallRule -FolderName 'Insurgency2014'
    .NOTES
        Throws if Plugin.json is missing/invalid or if New-NetFirewallRule
        fails. Never leaves a partially-created set of rules silently
        unreported: each protocol's failure throws immediately.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter()]
        [int]$Port,

        [Parameter()]
        [switch]$Force
    )

    $pluginJson = Get-GSMFirewallPluginJson -FolderName $FolderName
    $resolvedPort = if ($PSBoundParameters.ContainsKey('Port')) { $Port } else { $pluginJson.DefaultPort }
    $protocols = Get-GSMFirewallProtocolList -PluginJson $pluginJson

    $ruleNames = [System.Collections.Generic.List[string]]::new()

    foreach ($protocol in $protocols) {
        $ruleName = Get-GSMFirewallRuleName -FolderName $FolderName -Port $resolvedPort -Protocol $protocol
        $existingRule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue

        if ($existingRule -and -not $Force) {
            Write-GSMLog -Level Info -Message "Firewall rule '$ruleName' already exists; Add-GSMFirewallRule is a no-op for it."
            $ruleNames.Add($ruleName)
            continue
        }

        if ($existingRule -and $Force) {
            try {
                Remove-NetFirewallRule -Name $ruleName -ErrorAction Stop
            }
            catch {
                Write-GSMLog -Level Error -Message "Failed to remove existing firewall rule '$ruleName' before recreating it: $($_.Exception.Message)"
                throw "Failed to remove existing firewall rule '$ruleName' for '$FolderName': $($_.Exception.Message)"
            }
        }

        try {
            New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Inbound -Protocol $protocol -LocalPort $resolvedPort -Action Allow -ErrorAction Stop | Out-Null
        }
        catch {
            Write-GSMLog -Level Error -Message "Failed to create firewall rule '$ruleName': $($_.Exception.Message)"
            throw "Failed to create firewall rule '$ruleName' for '$FolderName': $($_.Exception.Message)"
        }

        Write-GSMLog -Level Info -Message "Created firewall rule '$ruleName' (port $resolvedPort/$protocol) for '$FolderName'."
        $ruleNames.Add($ruleName)
    }

    return $ruleNames.ToArray()
}

function Remove-GSMFirewallRule {
    <#
    .SYNOPSIS
        Removes every Windows Firewall rule GSM created for a server
        instance.
    .DESCRIPTION
        Finds every rule whose DisplayName starts with "GSM-<FolderName>-"
        and removes it. Matching by prefix rather than rebuilding the exact
        expected name(s) means removal still works even if the port on file
        has changed since the rule was created, or Plugin.json is missing
        or has since been edited. A no-op returning $true (with an info log,
        not an error) if no matching rules exist.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Remove-GSMFirewallRule -FolderName 'Insurgency2014'
    .NOTES
        Never throws for a missing rule. A failure removing a rule that
        does exist is logged as a warning, not fatal, so one bad rule
        doesn't block cleanup of the rest.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $namePrefix = "GSM-$FolderName-"
    # Filters out $null explicitly rather than just wrapping in @(...): when
    # Get-NetFirewallRule finds no matches, it returns $null, and @($null)
    # is a one-element array containing $null, not an empty one - Set-
    # StrictMode -Version Latest then throws on the property access below.
    $existingRules = @(Get-NetFirewallRule -DisplayName "$namePrefix*" -ErrorAction SilentlyContinue | Where-Object { $_ })

    if ($existingRules.Count -eq 0) {
        Write-GSMLog -Level Info -Message "No firewall rules found for '$FolderName'; Remove-GSMFirewallRule is a no-op."
        return $true
    }

    foreach ($rule in $existingRules) {
        try {
            Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
            Write-GSMLog -Level Info -Message "Removed firewall rule '$($rule.Name)' for '$FolderName'."
        }
        catch {
            Write-GSMLog -Level Warning -Message "Failed to remove firewall rule '$($rule.Name)' for '$FolderName' (it may have already been removed): $($_.Exception.Message)"
        }
    }

    return $true
}

function Get-GSMFirewallRuleStatus {
    <#
    .SYNOPSIS
        Reports every Windows Firewall rule GSM has created for a server
        instance.
    .DESCRIPTION
        Finds every rule whose DisplayName starts with "GSM-<FolderName>-"
        and returns one object per rule with its name, protocol, port,
        enabled state, direction, and action. Protocol and port are parsed
        directly from the rule's own name (Get-GSMFirewallRuleName's
        "GSM-<FolderName>-<Port>-<Protocol>" format), not read back via
        Get-NetFirewallPortFilter: that cmdlet requires a genuine
        NetFirewallRule CimInstance, which only the real NetSecurity module
        can produce, making it untestable without touching the live
        firewall. Parsing the name GSM itself generated needs nothing but
        the rule object already in hand. Returns an empty array, not an
        error, when no rules exist for FolderName.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Get-GSMFirewallRuleStatus -FolderName 'Insurgency2014'
    .NOTES
        Consumed by Core/Reports.psm1's health report to cross-reference
        open ports against firewall rule status.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $namePrefix = "GSM-$FolderName-"
    # Filters out $null explicitly - see the identical comment in
    # Remove-GSMFirewallRule for why @(...) alone isn't enough.
    $rules = @(Get-NetFirewallRule -DisplayName "$namePrefix*" -ErrorAction SilentlyContinue | Where-Object { $_ })

    $namePattern = '^{0}(\d+)-(TCP|UDP)$' -f [regex]::Escape($namePrefix)

    $statuses = [System.Collections.Generic.List[psobject]]::new()

    foreach ($rule in $rules) {
        $port = $null
        $protocol = $null
        if ($rule.Name -match $namePattern) {
            $port = [int]$matches[1]
            $protocol = $matches[2]
        }

        $statuses.Add([PSCustomObject]@{
                FolderName = $FolderName
                RuleName   = $rule.Name
                Protocol   = $protocol
                Port       = $port
                Enabled    = ($rule.Enabled -eq 'True' -or $rule.Enabled -eq $true)
                Direction  = $rule.Direction
                Action     = $rule.Action
            })
    }

    return $statuses.ToArray()
}

Export-ModuleMember -Function Add-GSMFirewallRule, Remove-GSMFirewallRule, Get-GSMFirewallRuleStatus
