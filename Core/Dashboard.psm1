#Requires -Version 7.0
<#
.SYNOPSIS
    Local web dashboard for GSM server instances.
.DESCRIPTION
    Phase 4 (PRD section 13). Serves a single-page dashboard over
    System.Net.HttpListener, bound to 127.0.0.1 only - no external
    dependency, consistent with the project's PowerShell-7-only dependency
    rule, and no auth layer since that trust boundary (loopback-only) needs
    none.

    Endpoints:
      GET  /            the dashboard page (static HTML/vanilla JS, no
                         external library)
      GET  /api/status   polled JSON status, reusing Core/Reports.psm1's
                         own Get-GSMServerHealthReportData rather than
                         duplicating instance/system discovery here
      POST /api/action   { FolderName, Action } - Start/Stop/Restart,
                         dispatched through Core/Menu.psm1's Invoke-GSMAction
      POST /api/rcon     { FolderName, Command } - dispatched through
                         Core/RCON.psm1's Send-GSMRCONCommand

    Both dispatch endpoints reuse the console's own dispatch functions
    (Invoke-GSMAction, Send-GSMRCONCommand), so logging and behavior never
    diverge between the console and the dashboard.

    Interactive from v1, run as a foreground blocking loop from a Menu.psm1
    action (Ctrl+C to stop) - not a background service.
.NOTES
    Invoke-GSMDashboardRequest is this module's sole seam for Pester: it
    takes an already-parsed Method/Path/Body and returns a plain
    StatusCode/ContentType/Body object, with no real HttpListener involved.
    Start-GSMDashboard's only job is translating a real HttpListenerContext
    into that call and writing the result back out - it is not unit tested
    directly, the same way Core/RCON.psm1's real TCP connection isn't.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Menu.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'RCON.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Reports.psm1') -Force

function Get-GSMDashboardHtml {
    # Internal helper. Not exported: the dashboard's single static HTML
    # page. All dynamic data is fetched client-side via fetch() calls to
    # /api/status, /api/action, and /api/rcon - no server-side templating,
    # no external JS library.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>GSM Dashboard</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#1a1a1a;background:#fafafa}
h1{margin-bottom:0.2em}
.instance{border:1px solid #ccc;border-radius:6px;padding:1em;margin-bottom:1em;background:#fff}
.badge{display:inline-block;padding:0.15em 0.6em;border-radius:4px;font-size:0.85em;color:#fff}
.badge-running{background:#2e7d32}
.badge-stopped{background:#616161}
.badge-crashed{background:#c62828}
.badge-unknown{background:#b8860b}
button{margin-right:0.4em;padding:0.3em 0.8em}
#rcon-panel{border:1px solid #ccc;border-radius:6px;padding:1em;background:#fff;margin-top:1.5em}
#rcon-output{white-space:pre-wrap;background:#111;color:#0f0;padding:0.8em;border-radius:4px;min-height:4em;font-family:Consolas,monospace}
select,input[type=text]{padding:0.3em;margin-right:0.4em}
</style>
</head>
<body>
<h1>GSM Dashboard</h1>
<p id="generated-at"></p>
<div id="instances">Loading...</div>

<div id="rcon-panel">
<h2>RCON Console</h2>
<select id="rcon-folder"></select>
<input type="text" id="rcon-command" placeholder="Command (e.g. status)">
<button onclick="sendRCONCommand()">Send</button>
<div id="rcon-output"></div>
</div>

<script>
async function refreshStatus() {
    const res = await fetch('/api/status');
    const data = await res.json();
    document.getElementById('generated-at').textContent = 'Updated: ' + data.GeneratedAtUtc;

    const container = document.getElementById('instances');
    container.innerHTML = '';
    const folderSelect = document.getElementById('rcon-folder');
    const previousFolder = folderSelect.value;
    folderSelect.innerHTML = '';

    for (const instance of data.Instances) {
        const badgeClass = instance.ServerStatus === 'Running' ? 'badge-running'
            : instance.ServerStatus === 'Stopped' ? 'badge-stopped'
            : instance.ServerStatus === 'Crashed' ? 'badge-crashed'
            : 'badge-unknown';
        const statusText = instance.ServerStatus || (instance.Installed ? 'Unknown' : 'Not installed');

        const div = document.createElement('div');
        div.className = 'instance';
        div.innerHTML = '<h3>' + instance.FolderName + ' <span class="badge ' + badgeClass + '">' + statusText + '</span></h3>' +
            '<p>' + instance.GameName + ' ' + instance.Version + '</p>' +
            '<button onclick="sendAction(\'' + instance.FolderName + '\',\'Start\')">Start</button>' +
            '<button onclick="sendAction(\'' + instance.FolderName + '\',\'Stop\')">Stop</button>' +
            '<button onclick="sendAction(\'' + instance.FolderName + '\',\'Restart\')">Restart</button>';
        container.appendChild(div);

        const option = document.createElement('option');
        option.value = instance.FolderName;
        option.textContent = instance.FolderName;
        folderSelect.appendChild(option);
    }

    if (previousFolder) {
        folderSelect.value = previousFolder;
    }
}

async function sendAction(folderName, action) {
    await fetch('/api/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ FolderName: folderName, Action: action })
    });
    refreshStatus();
}

async function sendRCONCommand() {
    const folderName = document.getElementById('rcon-folder').value;
    const command = document.getElementById('rcon-command').value;
    if (!folderName || !command) {
        return;
    }

    const res = await fetch('/api/rcon', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ FolderName: folderName, Command: command })
    });
    const result = await res.json();
    const output = document.getElementById('rcon-output');
    output.textContent = result.Success ? result.Response : ('Error: ' + result.Error);
}

refreshStatus();
setInterval(refreshStatus, 3000);
</script>
</body>
</html>
'@
}

function Get-GSMDashboardStatusJson {
    # Internal helper. Not exported: builds the JSON body for GET
    # /api/status by reusing Core/Reports.psm1's own
    # Get-GSMServerHealthReportData rather than duplicating instance/system
    # discovery here. RCONPassword is already redacted upstream by that
    # function's ConfigSummary - nothing further to scrub, and this
    # projection doesn't even forward ConfigSummary to the dashboard UI.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $reportData = Get-GSMServerHealthReportData

    $instances = @($reportData.Instances | ForEach-Object {
            [PSCustomObject]@{
                FolderName   = $_.FolderName
                GameName     = $_.GameName
                Version      = $_.Version
                Installed    = $_.Installed
                ServerStatus = $_.ServerStatus
            }
        })

    return ([PSCustomObject]@{
            GeneratedAtUtc = $reportData.GeneratedAtUtc
            Instances      = $instances
        } | ConvertTo-Json -Depth 5)
}

function Invoke-GSMDashboardAction {
    # Internal helper. Not exported: dispatches a Start/Stop/Restart action
    # from the dashboard's UI through Core/Menu.psm1's Invoke-GSMAction, the
    # same dispatch function the console menu uses, so lifecycle
    # actions/logging never diverge between the two front ends.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Stop', 'Restart')]
        [string]$Action
    )

    $succeeded = Invoke-GSMAction -FolderName $FolderName -Action $Action

    return [PSCustomObject]@{
        Success = $succeeded
    }
}

function Invoke-GSMDashboardRCONCommand {
    # Internal helper. Not exported: dispatches an RCON command from the
    # dashboard's command box through Core/RCON.psm1's Send-GSMRCONCommand,
    # the same primitive Start-GSMRCONConsole uses. Failures (auth,
    # connection refused, timeout) become a JSON error body, not an
    # unhandled exception surfaced to the HTTP client.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$Command
    )

    try {
        $response = Send-GSMRCONCommand -FolderName $FolderName -Command $Command
        return [PSCustomObject]@{
            Success  = $true
            Response = $response
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}

function Invoke-GSMDashboardRequest {
    # Internal helper. Not exported: routes one already-parsed HTTP request
    # (Method/Path/Body) to the right handler and returns a plain
    # StatusCode/ContentType/Body object. This is the module's sole seam for
    # Pester - see the module .NOTES.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Body = ''
    )

    if ($Method -eq 'GET' -and $Path -eq '/') {
        return [PSCustomObject]@{ StatusCode = 200; ContentType = 'text/html'; Body = Get-GSMDashboardHtml }
    }

    if ($Method -eq 'GET' -and $Path -eq '/api/status') {
        try {
            return [PSCustomObject]@{ StatusCode = 200; ContentType = 'application/json'; Body = Get-GSMDashboardStatusJson }
        }
        catch {
            $errorBody = [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message } | ConvertTo-Json -Depth 3
            return [PSCustomObject]@{ StatusCode = 500; ContentType = 'application/json'; Body = $errorBody }
        }
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/action') {
        try {
            $requestBody = $Body | ConvertFrom-Json -ErrorAction Stop
            $result = Invoke-GSMDashboardAction -FolderName $requestBody.FolderName -Action $requestBody.Action
            return [PSCustomObject]@{ StatusCode = 200; ContentType = 'application/json'; Body = ($result | ConvertTo-Json -Depth 3) }
        }
        catch {
            $errorBody = [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message } | ConvertTo-Json -Depth 3
            return [PSCustomObject]@{ StatusCode = 400; ContentType = 'application/json'; Body = $errorBody }
        }
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/rcon') {
        try {
            $requestBody = $Body | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $errorBody = [PSCustomObject]@{ Success = $false; Error = 'Malformed JSON request body.' } | ConvertTo-Json -Depth 3
            return [PSCustomObject]@{ StatusCode = 400; ContentType = 'application/json'; Body = $errorBody }
        }

        $result = Invoke-GSMDashboardRCONCommand -FolderName $requestBody.FolderName -Command $requestBody.Command
        return [PSCustomObject]@{ StatusCode = 200; ContentType = 'application/json'; Body = ($result | ConvertTo-Json -Depth 3) }
    }

    return [PSCustomObject]@{ StatusCode = 404; ContentType = 'text/plain'; Body = 'Not found.' }
}

function Start-GSMDashboard {
    <#
    .SYNOPSIS
        Runs GSM's local web dashboard.
    .DESCRIPTION
        Starts a System.Net.HttpListener bound to http://127.0.0.1:<Port>/
        and serves the dashboard's single HTML page, a polled JSON status
        endpoint, and Start/Stop/Restart and RCON command dispatch. Blocks
        in a foreground loop until interrupted (Ctrl+C) - this is a
        blocking loop, not a background service, for v1.

        Bound to 127.0.0.1 only - no auth layer is added, since only
        processes on the same machine can reach it at that trust boundary.
    .PARAMETER Port
        TCP port to listen on. Defaults to 8090.
    .EXAMPLE
        Start-GSMDashboard
    .EXAMPLE
        Start-GSMDashboard -Port 9000
    .NOTES
        Every dispatched action/RCON command is already logged by
        Invoke-GSMAction/Send-GSMRCONCommand themselves - this function only
        logs the dashboard's own start/stop. A failure handling one request
        is logged as a warning and answered with a 500, not allowed to take
        down the whole listener loop.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive startup message; output is direct user-facing display, not pipeline data. Matches the same justification used for Show-MainMenu in Core/Menu.psm1.')]
    param(
        [Parameter()]
        [int]$Port = 8090
    )

    $prefix = "http://127.0.0.1:$Port/"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch {
        Write-Warning "Could not start the dashboard on '$prefix': $($_.Exception.Message)"
        return
    }

    Write-GSMLog -Level Info -Message "Dashboard started on '$prefix'."
    Write-Host "GSM Dashboard running at $prefix (Ctrl+C to stop)."

    try {
        while ($listener.IsListening) {
            try {
                $context = $listener.GetContext()
            }
            catch [System.Net.HttpListenerException] {
                # The listener was stopped (e.g. Ctrl+C landed mid-GetContext) -
                # exit the loop cleanly rather than treating it as a per-request
                # failure.
                break
            }

            try {
                $request = $context.Request
                $response = $context.Response

                $requestBody = ''
                if ($request.HasEntityBody) {
                    $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                    try {
                        $requestBody = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }
                }

                $result = Invoke-GSMDashboardRequest -Method $request.HttpMethod -Path $request.Url.AbsolutePath -Body $requestBody

                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($result.Body)
                $response.StatusCode = $result.StatusCode
                $response.ContentType = $result.ContentType
                $response.ContentLength64 = $responseBytes.Length
                $response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
                $response.OutputStream.Close()
            }
            catch {
                Write-GSMLog -Level Warning -Message "Dashboard request handling failed: $($_.Exception.Message)"
                try {
                    $context.Response.StatusCode = 500
                    $context.Response.OutputStream.Close()
                }
                catch {
                    Write-GSMLog -Level Warning -Message "Could not send the dashboard's error response to the client (it may have already disconnected): $($_.Exception.Message)"
                }
            }
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
        Write-GSMLog -Level Info -Message 'Dashboard stopped.'
    }
}

Export-ModuleMember -Function Start-GSMDashboard
