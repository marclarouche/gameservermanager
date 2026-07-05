BeforeAll {
    Import-Module "$PSScriptRoot/../Core/Utilities.psm1" -Force
    $script:TestDir = Join-Path $TestDrive 'utilities-tests'
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
}

Describe 'Core/Utilities.psm1' {

    Context 'Get-GSMRootPath' {
        It 'returns the repository root, the parent of Core/' {
            $root = Get-GSMRootPath
            $root | Should -Be (Resolve-Path "$PSScriptRoot/..").Path
            Test-Path -Path (Join-Path $root 'Core') -PathType Container | Should -Be $true
        }
    }

    Context 'Get-FileHashSHA256' {
        It 'returns the same hash as Get-FileHash -Algorithm SHA256' {
            $path = Join-Path $script:TestDir 'sample.txt'
            Set-Content -Path $path -Value 'hash me'

            $expected = (Get-FileHash -Path $path -Algorithm SHA256).Hash
            Get-FileHashSHA256 -Path $path | Should -Be $expected
        }

        It 'throws when the file does not exist' {
            $path = Join-Path $script:TestDir 'does-not-exist.txt'
            { Get-FileHashSHA256 -Path $path } | Should -Throw
        }
    }

    Context 'Read-GSMPrompt' {
        It 'returns the response unchanged when no ValidValues are given' {
            Mock -ModuleName Utilities -CommandName Read-Host -MockWith { 'anything' }

            Read-GSMPrompt -Message 'Enter a name' | Should -Be 'anything'
            Should -Invoke -ModuleName Utilities -CommandName Read-Host -Times 1
        }

        It 'returns immediately when the first response is a valid value' {
            Mock -ModuleName Utilities -CommandName Read-Host -MockWith { 'yes' }

            Read-GSMPrompt -Message 'Continue?' -ValidValues @('yes', 'no') | Should -Be 'yes'
            Should -Invoke -ModuleName Utilities -CommandName Read-Host -Times 1
        }

        It 'reprompts on invalid input until a valid value is given' {
            $script:responses = [System.Collections.Generic.Queue[string]]::new([string[]]@('bogus', 'no'))
            Mock -ModuleName Utilities -CommandName Read-Host -MockWith { $script:responses.Dequeue() }
            Mock -ModuleName Utilities -CommandName Write-Warning -MockWith { }

            Read-GSMPrompt -Message 'Continue?' -ValidValues @('yes', 'no') | Should -Be 'no'
            Should -Invoke -ModuleName Utilities -CommandName Read-Host -Times 2
            Should -Invoke -ModuleName Utilities -CommandName Write-Warning -Times 1
        }
    }
}
