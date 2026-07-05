#Requires -Version 7.0
<#
.SYNOPSIS
    Logging framework with daily rotation and tamper-evident chained hashes.
.DESCRIPTION
    Phase 1. Writes structured log entries to Logs/, rotates daily, and chains
    each entry's hash to the previous entry so tampering is detectable.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Utilities.psm1') -Force

# Default log directory, resolved from the repo root via Get-GSMRootPath so no
# absolute path is baked in. Callers can override via -LogDirectory.
$script:DefaultLogDirectory = Join-Path -Path (Get-GSMRootPath) -ChildPath 'Logs'

function Get-GSMLogHash {
    # Internal helper. Not exported: computes the SHA-256 chain hash for one
    # log entry from its Timestamp, Level, Message, and PreviousHash.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Timestamp,

        [Parameter(Mandatory)]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$PreviousHash
    )

    $raw = "$Timestamp$Level$Message$PreviousHash"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
}

function New-GSMLogFile {
    <#
    .SYNOPSIS
        Creates today's log file if it does not already exist.
    .DESCRIPTION
        Ensures LogDirectory exists, then ensures the file for today's date
        (GSM-yyyy-MM-dd.log) exists, creating an empty one if needed. Called
        internally by Write-GSMLog to perform lazy daily rotation, but also
        exported so tests can invoke rotation directly.
    .PARAMETER LogDirectory
        Directory the log file lives in. Defaults to a Logs/ folder next to
        the Core/ directory.
    .EXAMPLE
        New-GSMLogFile -LogDirectory 'D:\GSM\Logs'
    .NOTES
        Returns the full path to today's log file, whether it already existed
        or was just created.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$LogDirectory = $script:DefaultLogDirectory
    )

    try {
        if (-not (Test-Path -Path $LogDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction Stop | Out-Null
        }

        $fileName = 'GSM-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd')
        $logPath = Join-Path -Path $LogDirectory -ChildPath $fileName

        if (-not (Test-Path -Path $logPath -PathType Leaf)) {
            New-Item -ItemType File -Path $logPath -Force -ErrorAction Stop | Out-Null
        }

        return $logPath
    }
    catch {
        throw "Failed to create or access log file in '$LogDirectory': $($_.Exception.Message)"
    }
}

function Write-GSMLog {
    <#
    .SYNOPSIS
        Writes a chained-hash log entry to today's log file.
    .DESCRIPTION
        Performs lazy daily rotation via New-GSMLogFile, then appends a JSON
        log line containing Timestamp, Level, Message, PreviousHash, and Hash.
        Hash is SHA-256 of (Timestamp + Level + Message + PreviousHash), so
        each entry is cryptographically chained to the one before it. The
        first entry in a new log file uses PreviousHash "0".
    .PARAMETER Level
        Severity of the entry: Info, Warning, or Error.
    .PARAMETER Message
        The log message text.
    .PARAMETER LogDirectory
        Directory the log file lives in. Defaults to a Logs/ folder next to
        the Core/ directory.
    .EXAMPLE
        Write-GSMLog -Level Info -Message 'Server started.'
    .NOTES
        Throws on any file I/O failure rather than swallowing it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [string]$LogDirectory = $script:DefaultLogDirectory
    )

    try {
        $logPath = New-GSMLogFile -LogDirectory $LogDirectory

        $previousHash = '0'
        $existingLines = @(Get-Content -Path $logPath -ErrorAction Stop)
        if ($existingLines.Count -gt 0) {
            $lastEntry = $existingLines[-1] | ConvertFrom-Json -ErrorAction Stop
            $previousHash = $lastEntry.Hash
        }

        $timestamp = (Get-Date).ToUniversalTime().ToString('o')
        $hash = Get-GSMLogHash -Timestamp $timestamp -Level $Level -Message $Message -PreviousHash $previousHash

        $entry = [ordered]@{
            Timestamp    = $timestamp
            Level        = $Level
            Message      = $Message
            PreviousHash = $previousHash
            Hash         = $hash
        }

        $line = $entry | ConvertTo-Json -Compress -Depth 3
        Add-Content -Path $logPath -Value $line -ErrorAction Stop
    }
    catch {
        throw "Failed to write log entry: $($_.Exception.Message)"
    }
}

function Test-GSMLogIntegrity {
    <#
    .SYNOPSIS
        Verifies the chained-hash integrity of a GSM log file.
    .DESCRIPTION
        Walks each line of the log file at Path, recomputing the expected
        hash from Timestamp, Level, Message, and PreviousHash, and confirms it
        matches both the stored Hash and the PreviousHash carried by the
        entry. Throws as soon as a break in the chain is found, naming the
        offending line number.
    .PARAMETER Path
        Full path to the log file to verify.
    .EXAMPLE
        Test-GSMLogIntegrity -Path './Logs/GSM-2026-07-05.log'
    .NOTES
        Returns $true when every entry in the file is intact. An empty file
        has no chain to break and is considered valid.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Log file not found: $Path"
    }

    try {
        $lines = @(Get-Content -Path $Path -ErrorAction Stop)
    }
    catch {
        throw "Failed to read log file '$Path': $($_.Exception.Message)"
    }

    $previousHash = '0'

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineNumber = $i + 1

        try {
            $entry = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Log integrity check failed at line ${lineNumber}: entry is not valid JSON."
        }

        if ($entry.PreviousHash -ne $previousHash) {
            throw "Log integrity check failed at line ${lineNumber}: PreviousHash does not match the prior entry's Hash."
        }

        # ConvertFrom-Json auto-parses ISO 8601 strings into [datetime]; reformat
        # with 'o' to recover the exact original string used when the hash was
        # first computed.
        $entryTimestamp = $entry.Timestamp
        if ($entryTimestamp -is [datetime]) {
            $entryTimestamp = $entryTimestamp.ToString('o')
        }

        $expectedHash = Get-GSMLogHash -Timestamp $entryTimestamp -Level $entry.Level -Message $entry.Message -PreviousHash $entry.PreviousHash

        if ($entry.Hash -ne $expectedHash) {
            throw "Log integrity check failed at line ${lineNumber}: Hash does not match the entry's content."
        }

        $previousHash = $entry.Hash
    }

    return $true
}

Export-ModuleMember -Function Write-GSMLog, New-GSMLogFile, Test-GSMLogIntegrity
