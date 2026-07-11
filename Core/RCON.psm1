#Requires -Version 7.0
<#
.SYNOPSIS
    Source RCON protocol client for GSM server instances.
.DESCRIPTION
    Phase 4 (PRD section 13). Implements Valve's Source RCON Protocol (TCP,
    binary packets) as one generic Core module: all five plugins are Source
    engine and share this same protocol, so there is no per-plugin RCON code.

    Send-GSMRCONCommand is a stateless one-shot primitive (connect, auth,
    send one command, read one response, close). Start-GSMRCONConsole is a
    thin interactive REPL built on top of the same connect/auth logic, kept
    in exactly one place (Open-GSMRCONSession) so the two exported functions
    never duplicate it.

    Connects to 127.0.0.1 only: GSM manages server instances on the local
    machine (see PRD - remote/multi-host management is a non-goal).
.NOTES
    Packet layout (Size/ID/Type are little-endian Int32; this assumes a
    little-endian host, true for every Windows platform GSM targets):
      Size  - byte length of everything that follows (ID + Type + Body +
              2 null terminator bytes)
      ID    - request/response correlation ID, client-chosen
      Type  - SERVERDATA_AUTH (3), SERVERDATA_AUTH_RESPONSE (2),
              SERVERDATA_EXECCOMMAND (2), SERVERDATA_RESPONSE_VALUE (0).
              AUTH_RESPONSE and EXECCOMMAND share the value 2; direction
              disambiguates them, and a client never receives an
              EXECCOMMAND packet.
      Body  - ASCII string, single null-byte terminated
      (trailing empty string, itself null-terminated - one more null byte)

    New-GSMRCONConnection is this module's sole seam for Pester mocking:
    every other function operates on the Connection object's ReadStream/
    WriteStream, so tests replace New-GSMRCONConnection with one returning
    an in-memory stream pair instead of touching a real socket.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Config.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PluginLoader.psm1') -Force

$script:GSMRCONPacketType = @{
    Auth          = 3
    ExecCommand   = 2
    ResponseValue = 0
}

function Get-GSMRCONPropertyValue {
    # Internal helper. Not exported: reads a property from a psobject via
    # PSObject.Properties, returning $null when it doesn't exist instead of
    # letting dot-notation throw PropertyNotFoundException under
    # Set-StrictMode -Version Latest. Mirrors Core/Config.psm1's own helper.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [psobject]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-GSMRCONPluginJson {
    # Internal helper. Not exported: resolves and validates
    # Plugins/<FolderName>/Plugin.json, reusing Core/PluginLoader.psm1's own
    # Test-GSMPlugin rather than duplicating Plugin.json schema validation
    # here. Mirrors Core/Firewall.psm1's and Core/Scheduler.psm1's identical
    # helper.
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

function ConvertTo-GSMRCONPacketBytes {
    # Internal helper. Not exported: builds the raw byte layout for one RCON
    # packet - Int32 LE Size, Int32 LE Id, Int32 LE Type, ASCII Body + null
    # terminator, then one more trailing null byte for the protocol's empty
    # trailing string field.
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [int]$Id,

        [Parameter(Mandatory)]
        [int]$Type,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Body
    )

    $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
    $size = 4 + 4 + $bodyBytes.Length + 1 + 1

    $memoryStream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($memoryStream)
    try {
        $writer.Write([int]$size)
        $writer.Write([int]$Id)
        $writer.Write([int]$Type)
        $writer.Write($bodyBytes)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Flush()
        return $memoryStream.ToArray()
    }
    finally {
        $writer.Dispose()
    }
}

function ConvertFrom-GSMRCONPacketBytes {
    # Internal helper. Not exported: parses Id/Type/Body from the bytes that
    # follow a packet's Size field (Bytes does not include Size itself - the
    # caller already read it separately to know how many bytes to read).
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $id = [System.BitConverter]::ToInt32($Bytes, 0)
    $type = [System.BitConverter]::ToInt32($Bytes, 4)

    $bodyLength = $Bytes.Length - 8 - 2
    $body = if ($bodyLength -gt 0) { [System.Text.Encoding]::ASCII.GetString($Bytes, 8, $bodyLength) } else { '' }

    return [PSCustomObject]@{
        Id   = $id
        Type = $type
        Body = $body
    }
}

function Read-GSMRCONExactBytes {
    # Internal helper. Not exported: reads exactly Count bytes from Stream,
    # looping over Stream.Read since a single call can return fewer bytes
    # than requested (normal, documented .NET stream behavior). Throws if
    # the stream ends before Count bytes are read, or on a timeout.
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory)]
        [int]$Count
    )

    $buffer = [byte[]]::new($Count)
    $offset = 0

    while ($offset -lt $Count) {
        try {
            $read = $Stream.Read($buffer, $offset, $Count - $offset)
        }
        catch [System.IO.IOException] {
            $innerException = $_.Exception.InnerException
            if ($innerException -is [System.Net.Sockets.SocketException] -and $innerException.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                throw 'Timed out waiting for a response from the RCON server.'
            }
            throw "Connection error while reading RCON response: $($_.Exception.Message)"
        }

        if ($read -eq 0) {
            throw 'Connection closed before a complete RCON packet was received.'
        }
        $offset += $read
    }

    return $buffer
}

function Send-GSMRCONPacket {
    # Internal helper. Not exported: encodes and writes one RCON packet to
    # Connection's WriteStream.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Connection,

        [Parameter(Mandatory)]
        [int]$Id,

        [Parameter(Mandatory)]
        [int]$Type,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Body
    )

    $bytes = ConvertTo-GSMRCONPacketBytes -Id $Id -Type $Type -Body $Body
    $Connection.WriteStream.Write($bytes, 0, $bytes.Length)
    $Connection.WriteStream.Flush()
}

function Read-GSMRCONPacket {
    # Internal helper. Not exported: reads exactly one RCON packet from
    # Connection's ReadStream - a 4-byte Size header, then Size bytes of
    # Id/Type/Body/terminators. v1 reads a single packet only; it does not
    # reassemble a response split across multiple SERVERDATA_RESPONSE_VALUE
    # packets (see Send-GSMRCONCommand's .NOTES).
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Connection
    )

    $sizeBytes = Read-GSMRCONExactBytes -Stream $Connection.ReadStream -Count 4
    $size = [System.BitConverter]::ToInt32($sizeBytes, 0)

    $payloadBytes = Read-GSMRCONExactBytes -Stream $Connection.ReadStream -Count $size

    return ConvertFrom-GSMRCONPacketBytes -Bytes $payloadBytes
}

function New-GSMRCONConnection {
    # Internal helper. Not exported: opens a real TCP connection to
    # HostName:Port and returns the connection wrapper object (Client,
    # ReadStream, WriteStream, NextId) every other function in this module
    # operates on. This is the module's sole seam for Pester mocking: tests
    # replace this whole function with one returning an in-memory
    # ReadStream/WriteStream pair, so Open-GSMRCONSession/Send-GSMRCONPacket/
    # Read-GSMRCONPacket run unchanged against fake I/O with no real socket
    # involved.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [int]$Port,

        [Parameter()]
        [int]$TimeoutMilliseconds = 5000
    )

    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        $connected = $connectTask.Wait($TimeoutMilliseconds)
    }
    catch {
        $client.Dispose()
        $innerException = $_.Exception.InnerException
        if ($innerException -is [System.Net.Sockets.SocketException]) {
            throw "Connection to '${HostName}:${Port}' was refused. Is the server running with RCON enabled on that port?"
        }
        throw "Failed to connect to '${HostName}:${Port}': $($_.Exception.Message)"
    }

    if (-not $connected) {
        $client.Dispose()
        throw "Connection to '${HostName}:${Port}' timed out after ${TimeoutMilliseconds}ms."
    }

    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMilliseconds
    $stream.WriteTimeout = $TimeoutMilliseconds

    return [PSCustomObject]@{
        Client      = $client
        ReadStream  = $stream
        WriteStream = $stream
        NextId      = 1
    }
}

function Close-GSMRCONConnection {
    # Internal helper. Not exported: disposes Connection's underlying TCP
    # client, which also disposes its stream. A no-op when Client is $null
    # (a Pester fake connection with no real socket).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Connection
    )

    if ($Connection.Client) {
        $Connection.Client.Dispose()
    }
}

function Open-GSMRCONSession {
    # Internal helper. Not exported: resolves FolderName's DefaultPort
    # (Plugin.json) and RCONPassword (Config/<FolderName>.json), opens a TCP
    # connection to 127.0.0.1:<port> via New-GSMRCONConnection, and
    # authenticates with a SERVERDATA_AUTH packet. Shared by
    # Send-GSMRCONCommand (closes the session immediately after one command)
    # and Start-GSMRCONConsole (keeps it open across many commands), so
    # connect/auth logic lives in exactly one place.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    $rootPath = Get-GSMRootPath

    $pluginJson = Get-GSMRCONPluginJson -FolderName $FolderName
    $port = $pluginJson.DefaultPort

    $configPath = Join-Path -Path $rootPath -ChildPath "Config/$FolderName.json"
    if (-not (Test-Path -Path $configPath -PathType Leaf)) {
        throw "No config found for '$FolderName' at '$configPath'. Run the Configure action first."
    }
    $config = Get-GSMConfig -Path $configPath

    $password = Get-GSMRCONPropertyValue -InputObject $config -Name 'RCONPassword'
    if ([string]::IsNullOrEmpty($password)) {
        throw "Config for '$FolderName' has no RCONPassword set. Set one via the Configure action before using RCON."
    }

    $connection = New-GSMRCONConnection -HostName '127.0.0.1' -Port $port

    try {
        Send-GSMRCONPacket -Connection $connection -Id $connection.NextId -Type $script:GSMRCONPacketType.Auth -Body $password
        $authResponse = Read-GSMRCONPacket -Connection $connection

        if ($authResponse.Id -eq -1) {
            throw "RCON authentication failed for '$FolderName'. Check the configured RCONPassword."
        }

        $connection.NextId++
    }
    catch {
        Close-GSMRCONConnection -Connection $connection
        throw
    }

    return $connection
}

function Invoke-GSMRCONExecCommand {
    # Internal helper. Not exported: sends one SERVERDATA_EXECCOMMAND packet
    # on an already-authenticated Connection and returns the body of the
    # single SERVERDATA_RESPONSE_VALUE packet read back. Shared by
    # Send-GSMRCONCommand and Start-GSMRCONConsole's REPL loop.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Connection,

        [Parameter(Mandatory)]
        [string]$Command
    )

    $Connection.NextId++
    Send-GSMRCONPacket -Connection $Connection -Id $Connection.NextId -Type $script:GSMRCONPacketType.ExecCommand -Body $Command
    $response = Read-GSMRCONPacket -Connection $Connection

    return $response.Body
}

function Send-GSMRCONCommand {
    <#
    .SYNOPSIS
        Sends one command to a server instance over Source RCON and returns
        its response.
    .DESCRIPTION
        Stateless, one-shot: resolves the instance's port from
        Plugins/<FolderName>/Plugin.json's DefaultPort and its RCON password
        from Config/<FolderName>.json's RCONPassword, opens a TCP connection
        to 127.0.0.1 on that port, authenticates with SERVERDATA_AUTH, sends
        Command as SERVERDATA_EXECCOMMAND, reads one
        SERVERDATA_RESPONSE_VALUE response packet, closes the connection,
        and returns the response body. The command sent is logged via
        Write-GSMLog (Info level) with the command text and FolderName -
        RCONPassword is never logged.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .PARAMETER Command
        The RCON command text to execute (e.g. 'status', 'changelevel de_dust2').
    .EXAMPLE
        Send-GSMRCONCommand -FolderName 'Insurgency2014' -Command 'status'
    .NOTES
        v1 does not reassemble multi-packet responses: the Source RCON
        protocol splits any response over roughly 4096 bytes across multiple
        SERVERDATA_RESPONSE_VALUE packets, and this function reads only the
        first one. Long command output (e.g. 'status' on a full server, or
        'cvarlist') may be truncated. Reassembly is left for a later version.

        Throws on connection refused, authentication failure, and timeout,
        each with a distinct message - it never leaks RCONPassword in an
        error message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$Command
    )

    $connection = Open-GSMRCONSession -FolderName $FolderName

    try {
        $response = Invoke-GSMRCONExecCommand -Connection $connection -Command $Command
        Write-GSMLog -Level Info -Message "RCON command sent to '$FolderName': $Command"
        return $response
    }
    finally {
        Close-GSMRCONConnection -Connection $connection
    }
}

function Start-GSMRCONConsole {
    <#
    .SYNOPSIS
        Interactive RCON console (REPL) for a server instance.
    .DESCRIPTION
        Opens one authenticated RCON connection to FolderName's server (via
        the same Open-GSMRCONSession logic Send-GSMRCONCommand uses), then
        repeatedly prompts for a command, sends it, and prints the response,
        until the user types 'exit' or 'quit'. The connection is opened once
        and closed once when the loop ends, not reopened per command. Every
        command sent is logged via Write-GSMLog (Info level) with the
        command text and FolderName - RCONPassword is never logged.
    .PARAMETER FolderName
        The plugin's folder name under Plugins/ (e.g. 'Insurgency2014').
    .EXAMPLE
        Start-GSMRCONConsole -FolderName 'Insurgency2014'
    .NOTES
        Connection failures, authentication failures, and timeouts are
        printed as a clear message and the function returns - they are never
        allowed to throw an unhandled exception into the console loop.

        Shares Send-GSMRCONCommand's v1 limitation of not reassembling
        multi-packet responses (see its .NOTES) - long command output may be
        truncated here too.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console REPL; output is direct user-facing display, not pipeline data. Matches the same justification used for Show-MainMenu in Core/Menu.psm1.')]
    param(
        [Parameter(Mandatory)]
        [string]$FolderName
    )

    try {
        $connection = Open-GSMRCONSession -FolderName $FolderName
    }
    catch {
        Write-Warning "Could not start RCON console for '$FolderName': $($_.Exception.Message)"
        return
    }

    try {
        Write-Host "RCON console connected to '$FolderName'. Type 'exit' or 'quit' to leave."

        while ($true) {
            $command = Read-GSMPrompt -Message 'RCON>'

            if ($command -in @('exit', 'quit')) {
                break
            }

            try {
                $response = Invoke-GSMRCONExecCommand -Connection $connection -Command $command
                Write-GSMLog -Level Info -Message "RCON command sent to '$FolderName': $command"
                Write-Host $response
            }
            catch {
                Write-Warning "RCON command failed: $($_.Exception.Message)"
                break
            }
        }
    }
    finally {
        Close-GSMRCONConnection -Connection $connection
    }
}

Export-ModuleMember -Function Send-GSMRCONCommand, Start-GSMRCONConsole
