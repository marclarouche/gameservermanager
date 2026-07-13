#Requires -Version 7.0
<#
.SYNOPSIS
    Server health report generation for GSM.
.DESCRIPTION
    Phase 3 (PRD section 9). New-GSMServerHealthReport produces a single
    static Reports/ServerHealth-<yyyyMMdd-HHmmss>.html, built entirely as a
    PowerShell-generated HTML string - no external templating library.

    Data-gathering (Get-GSMServerHealthReportData and its per-section
    helpers) and HTML rendering (ConvertTo-GSMServerHealthReportHtml) are
    deliberately separate, internal functions: Pester can exercise the
    gathered data objects directly, without fragile string-diffing against
    rendered HTML.
.NOTES
    Cross-references every other Phase 1-3 Core module by design: installed
    plugins and per-instance config (Core/PluginLoader.psm1,
    Core/Config.psm1), running status (Core/Service.psm1), firewall rules
    (Core/Firewall.psm1), and backup status (Core/Backup.psm1). This module
    is the one place in Phase 3 that's expected to import that many
    siblings - a health report's entire purpose is aggregating them.

    Update history: Core/Update.psm1's Update-GSMServer logs every attempt
    via Write-GSMLog to the daily chained-hash log
    (Logs/GSM-<date>.log), but nothing in Phase 1 or 2 tracks update
    history as structured, queryable data. Rather than parsing daily log
    files into a fabricated per-instance history, this report says so
    directly (see Get-GSMServerHealthReportData's UpdateHistoryNote).
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PluginLoader.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'SteamCMD.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Service.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Firewall.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Backup.psm1') -Force

function Get-GSMReportSystemInfo {
    # Internal helper. Not exported: gathers Windows version, CPU/memory
    # usage, disk free/total space for the drive GSM lives on, and the GSM
    # root folder's own on-disk size. Any individual reading that can't be
    # obtained (e.g. Win32_Processor unavailable) is left $null rather than
    # failing the whole report.
    [CmdletBinding()]
    [OutputType([psobject])]
    param()

    $rootPath = Get-GSMRootPath

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    # Filters out $null explicitly rather than just wrapping in @(...): when
    # Get-CimInstance itself returns $null (unavailable, or mocked as such
    # in tests), @($null) would otherwise be a one-element array containing
    # $null, not an empty one, and Set-StrictMode -Version Latest throws on
    # property access against that $null element below.
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Where-Object { $_ })

    $cpuUsagePercent = $null
    $loadValues = @($processors | Where-Object { $null -ne $_.LoadPercentage } | Select-Object -ExpandProperty LoadPercentage)
    if ($loadValues.Count -gt 0) {
        $cpuUsagePercent = [math]::Round(($loadValues | Measure-Object -Average).Average, 1)
    }

    $totalMemoryGB = $null
    $freeMemoryGB = $null
    $memoryUsagePercent = $null
    if ($os -and $os.TotalVisibleMemorySize) {
        $totalMemoryGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $freeMemoryGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        $memoryUsagePercent = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
    }

    $rootDriveLetter = ([System.IO.Path]::GetPathRoot($rootPath)).TrimEnd('\', '/').TrimEnd(':')
    $logicalDisk = $null
    if ($rootDriveLetter) {
        $logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${rootDriveLetter}:'" -ErrorAction SilentlyContinue
    }
    $diskFreeGB = if ($logicalDisk) { [math]::Round($logicalDisk.FreeSpace / 1GB, 2) } else { $null }
    $diskTotalGB = if ($logicalDisk) { [math]::Round($logicalDisk.Size / 1GB, 2) } else { $null }

    $gsmRootSizeGB = $null
    if (Test-Path -Path $rootPath -PathType Container) {
        # Wrapped in @(...) and Count-checked before ever calling
        # Measure-Object: when Get-ChildItem finds zero files, piping
        # nothing into Measure-Object -Sum produces no output object at
        # all (not one with Sum = 0 or Sum = $null), so the parenthesized
        # pipeline itself evaluates to $null and Set-StrictMode -Version
        # Latest throws on ".Sum" against that $null.
        $rootFiles = @(Get-ChildItem -Path $rootPath -Recurse -File -ErrorAction SilentlyContinue)
        if ($rootFiles.Count -gt 0) {
            $sizeBytes = ($rootFiles | Measure-Object -Property Length -Sum).Sum
            if ($sizeBytes) {
                $gsmRootSizeGB = [math]::Round($sizeBytes / 1GB, 2)
            }
        }
    }

    return [PSCustomObject]@{
        WindowsCaption     = if ($os) { $os.Caption } else { $null }
        WindowsVersion     = if ($os) { $os.Version } else { $null }
        CpuUsagePercent    = $cpuUsagePercent
        TotalMemoryGB      = $totalMemoryGB
        FreeMemoryGB       = $freeMemoryGB
        MemoryUsagePercent = $memoryUsagePercent
        DiskFreeGB         = $diskFreeGB
        DiskTotalGB        = $diskTotalGB
        GSMRootSizeGB      = $gsmRootSizeGB
    }
}

function Get-GSMReportSteamCMDInfo {
    # Internal helper. Not exported: reports whether SteamCMD is installed
    # and the pinned-install metadata (VerifiedBy/VerifiedDate) from
    # Config/SteamCMD.json. Deliberately does not launch steamcmd.exe to
    # query a live version string: SteamCMD self-updates over the network
    # on every launch, and triggering that as a side effect of generating a
    # report would be surprising and outside what a report should do.
    [CmdletBinding()]
    [OutputType([psobject])]
    param()

    $installed = Test-SteamCMDPresent

    $verifiedBy = $null
    $verifiedDate = $null
    $configPath = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Config/SteamCMD.json'

    if (Test-Path -Path $configPath -PathType Leaf) {
        try {
            $config = Get-Content -Path $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $verifiedByProperty = $config.PSObject.Properties['VerifiedBy']
            $verifiedDateProperty = $config.PSObject.Properties['VerifiedDate']
            $verifiedBy = if ($verifiedByProperty) { $verifiedByProperty.Value } else { $null }
            $verifiedDate = if ($verifiedDateProperty) { $verifiedDateProperty.Value } else { $null }
        }
        catch {
            Write-GSMLog -Level Warning -Message "Could not read Config/SteamCMD.json for the health report: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        Installed    = $installed
        VerifiedBy   = $verifiedBy
        VerifiedDate = $verifiedDate
    }
}

function Get-GSMReportInstanceSummary {
    # Internal helper. Not exported: builds one server instance's full
    # summary - install/running status, config (RCONPassword redacted),
    # custom maps, firewall rule status, and backup status. A failure
    # reading any one piece (bad JSON, an unreachable firewall/backup
    # query) is logged as a warning and leaves that piece empty/$null
    # rather than failing the whole report over one instance's problem.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Plugin
    )

    $rootPath = Get-GSMRootPath
    $folderName = $Plugin.FolderName

    $executablePath = Join-Path -Path $rootPath -ChildPath "Servers/$folderName/$($Plugin.Executable)"
    $installed = Test-Path -Path $executablePath -PathType Leaf

    $serverStatus = $null
    if ($installed) {
        try {
            $serverStatus = Get-GSMServerStatus -FolderName $folderName
        }
        catch {
            $serverStatus = 'Unknown'
        }
    }

    $configPath = Join-Path -Path $rootPath -ChildPath "Config/$folderName.json"
    $configSummary = $null
    if (Test-Path -Path $configPath -PathType Leaf) {
        try {
            $config = Get-GSMConfig -Path $configPath
            $configSummary = [ordered]@{}
            foreach ($property in $config.PSObject.Properties) {
                # A health report is meant to be reviewed/shared, not a
                # secrets dump - RCONPassword's value is redacted, its
                # presence is not.
                $configSummary[$property.Name] = if ($property.Name -eq 'RCONPassword' -and $property.Value) { '(set, redacted)' } else { $property.Value }
            }
        }
        catch {
            Write-GSMLog -Level Warning -Message "Could not read config for '$folderName' for the health report: $($_.Exception.Message)"
        }
    }

    $customMaps = @()
    $customMapsPath = Join-Path -Path $rootPath -ChildPath 'Config/CustomMaps.json'
    if (Test-Path -Path $customMapsPath -PathType Leaf) {
        try {
            $allCustomMaps = Get-Content -Path $customMapsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $property = $allCustomMaps.PSObject.Properties[$folderName]
            if ($property) {
                $customMaps = @($property.Value)
            }
        }
        catch {
            Write-GSMLog -Level Warning -Message "Could not read Config/CustomMaps.json for '$folderName' for the health report: $($_.Exception.Message)"
        }
    }

    $firewallRules = @()
    try {
        $firewallRules = @(Get-GSMFirewallRuleStatus -FolderName $folderName)
    }
    catch {
        Write-GSMLog -Level Warning -Message "Could not read firewall rule status for '$folderName' for the health report: $($_.Exception.Message)"
    }

    $backups = @()
    try {
        $backups = @(Get-GSMBackupList -FolderName $folderName)
    }
    catch {
        Write-GSMLog -Level Warning -Message "Could not read backup list for '$folderName' for the health report: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        FolderName          = $folderName
        GameName            = $Plugin.GameName
        Version             = $Plugin.Version
        AppID               = $Plugin.AppID
        Installed           = $installed
        ServerStatus        = $serverStatus
        ConfigSummary       = $configSummary
        CustomMaps          = $customMaps
        FirewallRules       = $firewallRules
        BackupCount         = $backups.Count
        LastBackupTimestamp = if ($backups.Count -gt 0) { $backups[0].Timestamp } else { $null }
    }
}

function Get-GSMServerHealthReportData {
    <#
    .SYNOPSIS
        Gathers all data for a server health report.
    .DESCRIPTION
        Scans installed plugins via Core/PluginLoader.psm1's
        Find-GSMPlugins, builds one Get-GSMReportInstanceSummary per
        plugin, and combines it with host system info and SteamCMD status
        into a single report data object. Kept separate from HTML
        rendering so it can be tested directly.
    .EXAMPLE
        Get-GSMServerHealthReportData
    .NOTES
        Exported (in addition to New-GSMServerHealthReport) so
        Core/Dashboard.psm1's polled JSON status endpoint can reuse this
        same data-gathering instead of duplicating instance/system
        discovery there (PRD section 13's Phase 4 decisions log).
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param()

    $plugins = @(Find-GSMPlugins)
    $instances = @($plugins | ForEach-Object { Get-GSMReportInstanceSummary -Plugin $_ })

    return [PSCustomObject]@{
        GeneratedAtUtc    = (Get-Date).ToUniversalTime()
        System            = Get-GSMReportSystemInfo
        SteamCMD          = Get-GSMReportSteamCMDInfo
        Instances         = $instances
        UpdateHistoryNote = 'Update history is not tracked as structured, queryable data anywhere in Phase 1 or Phase 2. Core/Update.psm1 logs every update attempt via Write-GSMLog to the daily chained-hash log (Logs/GSM-<date>.log), but this report does not parse those logs into a per-instance update history.'
    }
}

function Get-GSMReportHtmlEncode {
    # Internal helper. Not exported: HTML-encodes a value for safe
    # embedding in the rendered report (config values, map names, etc. are
    # user-supplied data, not trusted markup).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-GSMServerHealthReportHtml {
    <#
    .SYNOPSIS
        Renders a report data object (from Get-GSMServerHealthReportData)
        as a single static HTML string.
    .DESCRIPTION
        Pure rendering: takes ReportData and returns an HTML string, with
        no file I/O of its own. Built as a PowerShell-generated string via
        a StringBuilder - no external templating library.
    .PARAMETER ReportData
        The report data object to render, from Get-GSMServerHealthReportData.
    .EXAMPLE
        ConvertTo-GSMServerHealthReportHtml -ReportData (Get-GSMServerHealthReportData)
    .NOTES
        Not exported - internal to Core/Reports.psm1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [psobject]$ReportData
    )

    $enc = { param($v) Get-GSMReportHtmlEncode -Value $v }
    $html = [System.Text.StringBuilder]::new()

    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$html.AppendLine('<title>GSM Server Health Report</title>')
    [void]$html.AppendLine('<style>')
    [void]$html.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#1a1a1a;background:#fafafa}')
    [void]$html.AppendLine('h1{margin-bottom:0}')
    [void]$html.AppendLine('.subtitle{color:#666;margin-top:0.2em}')
    [void]$html.AppendLine('table{border-collapse:collapse;margin:0.5em 0 1.5em 0;width:100%}')
    [void]$html.AppendLine('th,td{border:1px solid #ccc;padding:0.4em 0.7em;text-align:left;vertical-align:top}')
    [void]$html.AppendLine('th{background:#eee}')
    [void]$html.AppendLine('.instance{border:1px solid #ccc;border-radius:6px;padding:1em;margin-bottom:1.5em;background:#fff}')
    [void]$html.AppendLine('.badge{display:inline-block;padding:0.15em 0.6em;border-radius:4px;font-size:0.85em;color:#fff}')
    [void]$html.AppendLine('.badge-running{background:#2e7d32}')
    [void]$html.AppendLine('.badge-stopped{background:#616161}')
    [void]$html.AppendLine('.badge-crashed{background:#c62828}')
    [void]$html.AppendLine('.badge-unknown{background:#b8860b}')
    [void]$html.AppendLine('.note{background:#fff8e1;border:1px solid #e0c068;padding:0.8em;border-radius:6px}')
    [void]$html.AppendLine('</style></head><body>')

    [void]$html.AppendLine('<h1>GSM Server Health Report</h1>')
    [void]$html.AppendLine("<p class='subtitle'>Generated $(& $enc $ReportData.GeneratedAtUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC</p>")

    # System section.
    $system = $ReportData.System
    [void]$html.AppendLine('<h2>System</h2><table>')
    [void]$html.AppendLine("<tr><th>Windows</th><td>$(& $enc $system.WindowsCaption) ($(& $enc $system.WindowsVersion))</td></tr>")
    [void]$html.AppendLine("<tr><th>CPU usage</th><td>$(& $enc $system.CpuUsagePercent)%</td></tr>")
    [void]$html.AppendLine("<tr><th>Memory usage</th><td>$(& $enc $system.MemoryUsagePercent)% ($(& $enc $system.FreeMemoryGB) GB free of $(& $enc $system.TotalMemoryGB) GB)</td></tr>")
    [void]$html.AppendLine("<tr><th>Disk free (GSM drive)</th><td>$(& $enc $system.DiskFreeGB) GB free of $(& $enc $system.DiskTotalGB) GB</td></tr>")
    [void]$html.AppendLine("<tr><th>GSM root size on disk</th><td>$(& $enc $system.GSMRootSizeGB) GB</td></tr>")
    [void]$html.AppendLine('</table>')

    # SteamCMD section.
    $steamCmd = $ReportData.SteamCMD
    [void]$html.AppendLine('<h2>SteamCMD</h2><table>')
    [void]$html.AppendLine("<tr><th>Installed</th><td>$(& $enc $steamCmd.Installed)</td></tr>")
    [void]$html.AppendLine("<tr><th>Pinned build verified by</th><td>$(& $enc $steamCmd.VerifiedBy)</td></tr>")
    [void]$html.AppendLine("<tr><th>Pinned build verified on</th><td>$(& $enc $steamCmd.VerifiedDate)</td></tr>")
    [void]$html.AppendLine('</table>')

    # Instances.
    [void]$html.AppendLine('<h2>Server instances</h2>')

    if ($ReportData.Instances.Count -eq 0) {
        [void]$html.AppendLine('<p>No installed plugins found.</p>')
    }

    foreach ($instance in $ReportData.Instances) {
        $statusClass = switch ($instance.ServerStatus) {
            'Running' { 'badge-running' }
            'Stopped' { 'badge-stopped' }
            'Crashed' { 'badge-crashed' }
            default { 'badge-unknown' }
        }
        $statusText = if ($instance.ServerStatus) { $instance.ServerStatus } elseif ($instance.Installed) { 'Unknown' } else { 'Not installed' }

        [void]$html.AppendLine('<div class="instance">')
        [void]$html.AppendLine("<h3>$(& $enc $instance.FolderName) <span class='badge $statusClass'>$(& $enc $statusText)</span></h3>")
        [void]$html.AppendLine("<p>$(& $enc $instance.GameName) $(& $enc $instance.Version) &mdash; AppID $(& $enc $instance.AppID)</p>")

        [void]$html.AppendLine('<h4>Configuration</h4>')
        if ($instance.ConfigSummary -and $instance.ConfigSummary.Count -gt 0) {
            [void]$html.AppendLine('<table><tr><th>Field</th><th>Value</th></tr>')
            foreach ($key in $instance.ConfigSummary.Keys) {
                [void]$html.AppendLine("<tr><td>$(& $enc $key)</td><td>$(& $enc $instance.ConfigSummary[$key])</td></tr>")
            }
            [void]$html.AppendLine('</table>')
        }
        else {
            [void]$html.AppendLine('<p>Not configured yet.</p>')
        }

        [void]$html.AppendLine('<h4>Custom maps</h4>')
        if ($instance.CustomMaps.Count -gt 0) {
            [void]$html.AppendLine("<p>$(& $enc ($instance.CustomMaps -join ', '))</p>")
        }
        else {
            [void]$html.AppendLine('<p>None.</p>')
        }

        [void]$html.AppendLine('<h4>Firewall rules</h4>')
        if ($instance.FirewallRules.Count -gt 0) {
            [void]$html.AppendLine('<table><tr><th>Rule</th><th>Protocol</th><th>Port</th><th>Enabled</th></tr>')
            foreach ($rule in $instance.FirewallRules) {
                [void]$html.AppendLine("<tr><td>$(& $enc $rule.RuleName)</td><td>$(& $enc $rule.Protocol)</td><td>$(& $enc $rule.Port)</td><td>$(& $enc $rule.Enabled)</td></tr>")
            }
            [void]$html.AppendLine('</table>')
        }
        else {
            [void]$html.AppendLine('<p>No firewall rules found.</p>')
        }

        [void]$html.AppendLine('<h4>Backups</h4>')
        [void]$html.AppendLine("<p>$(& $enc $instance.BackupCount) backup(s) on file. Most recent: $(& $enc ($instance.LastBackupTimestamp ? $instance.LastBackupTimestamp : 'none'))</p>")

        [void]$html.AppendLine('</div>')
    }

    [void]$html.AppendLine('<h2>Update history</h2>')
    [void]$html.AppendLine("<div class='note'>$(& $enc $ReportData.UpdateHistoryNote)</div>")

    [void]$html.AppendLine('</body></html>')

    return $html.ToString()
}

function New-GSMServerHealthReport {
    <#
    .SYNOPSIS
        Generates a static HTML server health report.
    .DESCRIPTION
        Gathers data via Get-GSMServerHealthReportData, renders it via
        ConvertTo-GSMServerHealthReportHtml, and writes the result to
        Reports/ServerHealth-<yyyyMMdd-HHmmss>.html.
    .EXAMPLE
        New-GSMServerHealthReport
    .NOTES
        Throws if the report file can't be written. Returns the full path
        to the generated report on success.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $rootPath = Get-GSMRootPath
    $reportsDirectory = Join-Path -Path $rootPath -ChildPath 'Reports'
    New-Item -ItemType Directory -Path $reportsDirectory -Force -ErrorAction SilentlyContinue | Out-Null

    $reportData = Get-GSMServerHealthReportData
    $html = ConvertTo-GSMServerHealthReportHtml -ReportData $reportData

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $reportPath = Join-Path -Path $reportsDirectory -ChildPath "ServerHealth-$timestamp.html"

    try {
        Set-Content -Path $reportPath -Value $html -ErrorAction Stop
    }
    catch {
        Write-GSMLog -Level Error -Message "Failed to write health report to '$reportPath': $($_.Exception.Message)"
        throw "Failed to write health report to '$reportPath': $($_.Exception.Message)"
    }

    Write-GSMLog -Level Info -Message "Generated server health report '$reportPath'."

    return $reportPath
}

Export-ModuleMember -Function New-GSMServerHealthReport, Get-GSMServerHealthReportData
