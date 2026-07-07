#Requires -Version 7.0
<#
.SYNOPSIS
    Runs every Pester test file in Tests/ in its own isolated process.
.DESCRIPTION
    Several plugins share bare module names (Install, Server, Maps, Modes),
    and multiple Tests/*.Tests.ps1 files import those bare-named modules at
    the top level. Running the whole Tests/ directory through a single
    `Invoke-Pester -Path .\Tests\` call shares one PowerShell process across
    every file, so leftover global module state from one file's fixtures can
    interfere with another's - this was observed causing
    Tests/Menu.Tests.ps1's fake-plugin dispatch tests to fail only when run
    as part of a full-directory suite, never when that file ran alone.
    Running each file in its own fresh `pwsh -NoProfile` child process
    eliminates that cross-file state sharing entirely.
.PARAMETER Path
    Directory to scan for *.Tests.ps1 files. Defaults to this script's own
    directory (Tests/).
.EXAMPLE
    pwsh -NoProfile -File .\Tests\Run-AllTests.ps1
.NOTES
    Invoke via `pwsh -NoProfile -File ...` (a child process), not by
    dot-sourcing or running directly in an interactive session: this script
    calls `exit` with the aggregate pass/fail result for CI use, which would
    otherwise close the calling interactive PowerShell window.

    Exits 1 if any file has a failed test, 0 otherwise.
#>
[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'CLI test runner; console progress/summary output is direct user-facing display, not pipeline data. Matches the same justification used for Show-MainMenu in Core/Menu.psm1.')]
param(
    [Parameter()]
    [string]$Path = $PSScriptRoot
)

Set-StrictMode -Version Latest

$testFiles = Get-ChildItem -Path $Path -Filter '*.Tests.ps1' -File | Sort-Object -Property Name

if (-not $testFiles -or $testFiles.Count -eq 0) {
    Write-Warning "No *.Tests.ps1 files found under '$Path'."
    exit 0
}

$results = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($testFile in $testFiles) {
    Write-Host "Running $($testFile.Name)..." -ForegroundColor Cyan

    $resultJsonPath = [System.IO.Path]::GetTempFileName()
    try {
        $command = "`$r = Invoke-Pester -Path '$($testFile.FullName)' -PassThru; " +
            "[PSCustomObject]@{ Total = `$r.TotalCount; Passed = `$r.PassedCount; Failed = `$r.FailedCount; Skipped = `$r.SkippedCount } | " +
            "ConvertTo-Json | Set-Content -Path '$resultJsonPath'"

        & pwsh -NoProfile -Command $command | Out-Null

        $summary = Get-Content -Path $resultJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $summary = [PSCustomObject]@{ Total = 0; Passed = 0; Failed = 1; Skipped = 0 }
        Write-Warning "Failed to run '$($testFile.Name)': $($_.Exception.Message)"
    }
    finally {
        Remove-Item -Path $resultJsonPath -Force -ErrorAction SilentlyContinue
    }

    $results.Add([PSCustomObject]@{
            File    = $testFile.Name
            Total   = $summary.Total
            Passed  = $summary.Passed
            Failed  = $summary.Failed
            Skipped = $summary.Skipped
        })
}

$results | Format-Table -AutoSize

$grandTotal = ($results.Total | Measure-Object -Sum).Sum
$grandPassed = ($results.Passed | Measure-Object -Sum).Sum
$grandFailed = ($results.Failed | Measure-Object -Sum).Sum
$grandSkipped = ($results.Skipped | Measure-Object -Sum).Sum

Write-Host ''
$summaryColor = if ($grandFailed -gt 0) { 'Red' } else { 'Green' }
Write-Host "TOTAL: $grandTotal, Passed: $grandPassed, Failed: $grandFailed, Skipped: $grandSkipped" -ForegroundColor $summaryColor

if ($grandFailed -gt 0) {
    exit 1
}
exit 0
