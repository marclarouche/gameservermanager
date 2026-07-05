BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Logging.psm1" -Force
    $script:TestDir = Join-Path $TestDrive 'logging-tests'
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
}

Describe 'Core/Logging.psm1' {

    Context 'Write-GSMLog' {
        It 'creates a new log file and appends entries in order, chained by hash' {
            $dir = Join-Path $script:TestDir 'append'
            Write-GSMLog -Level Info -Message 'first' -LogDirectory $dir
            Write-GSMLog -Level Warning -Message 'second' -LogDirectory $dir

            $logPath = Join-Path $dir ('GSM-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
            $lines = @(Get-Content -Path $logPath)
            $lines.Count | Should -Be 2

            $first = $lines[0] | ConvertFrom-Json
            $second = $lines[1] | ConvertFrom-Json

            $first.Message | Should -Be 'first'
            $first.PreviousHash | Should -Be '0'
            $second.Message | Should -Be 'second'
            $second.PreviousHash | Should -Be $first.Hash
        }
    }

    Context 'New-GSMLogFile rotation' {
        It 'creates a new file for today without touching an existing old-dated file' {
            $dir = Join-Path $script:TestDir 'rotation'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $yesterdayFile = Join-Path $dir 'GSM-2020-01-01.log'
            Set-Content -Path $yesterdayFile -Value '{"Timestamp":"2020-01-01T00:00:00.0000000Z","Level":"Info","Message":"old","PreviousHash":"0","Hash":"deadbeef"}'

            $path = New-GSMLogFile -LogDirectory $dir
            $expected = Join-Path $dir ('GSM-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))

            $path | Should -Be $expected
            $path | Should -Not -Be $yesterdayFile
            (Get-Content -Path $yesterdayFile -Raw) | Should -Match 'old'
        }

        It 'does not recreate or truncate an existing file for today' {
            $dir = Join-Path $script:TestDir 'rotation-existing'
            Write-GSMLog -Level Info -Message 'first' -LogDirectory $dir
            $path = New-GSMLogFile -LogDirectory $dir
            Write-GSMLog -Level Info -Message 'second' -LogDirectory $dir

            $lines = @(Get-Content -Path $path)
            $lines.Count | Should -Be 2
        }
    }

    Context 'Test-GSMLogIntegrity' {
        It 'passes on an untouched log' {
            $dir = Join-Path $script:TestDir 'integrity-pass'
            Write-GSMLog -Level Info -Message 'first' -LogDirectory $dir
            Write-GSMLog -Level Warning -Message 'second' -LogDirectory $dir
            Write-GSMLog -Level Error -Message 'third' -LogDirectory $dir

            $logPath = Join-Path $dir ('GSM-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
            Test-GSMLogIntegrity -Path $logPath | Should -Be $true
        }

        It 'throws, naming the line number, when an entry is tampered with' {
            $dir = Join-Path $script:TestDir 'integrity-fail'
            Write-GSMLog -Level Info -Message 'first' -LogDirectory $dir
            Write-GSMLog -Level Warning -Message 'second' -LogDirectory $dir
            Write-GSMLog -Level Error -Message 'third' -LogDirectory $dir

            $logPath = Join-Path $dir ('GSM-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
            $lines = @(Get-Content -Path $logPath)

            $tampered = $lines[1] | ConvertFrom-Json
            $tampered.Message = 'tampered'
            $lines[1] = $tampered | ConvertTo-Json -Compress -Depth 3
            Set-Content -Path $logPath -Value $lines

            { Test-GSMLogIntegrity -Path $logPath } | Should -Throw '*line 2*'
        }
    }
}
