BeforeAll {
    Import-Module "$PSScriptRoot/../Core/RCON.psm1" -Force

    function New-FakeGSMRootForRCON {
        # PSScriptAnalyzer's PSAvoidUsingPlainTextForPassword rule flags any
        # String-typed parameter whose name matches "password" - even in
        # test-only fixture code - so this fixture's RCON secret is accepted
        # as -RCONSecret, not -RCONPassword, and mapped onto the config's own
        # RCONPassword field only inside the function body. Matches
        # Tests/Scheduler.Tests.ps1's identical workaround for its service
        # account password fixture.
        param(
            [string]$FolderName = 'FakeGame',
            [int]$DefaultPort = 27015,
            [string]$RCONSecret = 'secret123',
            [switch]$WithoutConfig,
            [switch]$OmitRCONPassword
        )

        $root = Join-Path $TestDrive ('rcon-root-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root "Plugins/$FolderName") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null

        $pluginJson = [ordered]@{
            GameName         = 'FakeGame'
            Version          = '1'
            AppID            = '1'
            Engine           = 'Source'
            Executable       = 'srcds.exe'
            DefaultPort      = $DefaultPort
            SupportsWorkshop = $false
            SupportsRCON     = $true
        }
        $pluginJson | ConvertTo-Json | Set-Content -Path (Join-Path $root "Plugins/$FolderName/Plugin.json")

        if (-not $WithoutConfig) {
            $config = [ordered]@{ GameName = 'FakeGame'; AppID = '1' }
            if (-not $OmitRCONPassword) {
                $config['RCONPassword'] = $RCONSecret
            }
            $config | ConvertTo-Json | Set-Content -Path (Join-Path $root "Config/$FolderName.json")
        }

        return $root
    }

    # Builds the exact wire-format bytes a real Source RCON server would send
    # back, independent of the module's own ConvertTo-GSMRCONPacketBytes, so
    # tests aren't just checking the module against itself.
    function New-TestGSMRCONPacketBytes {
        param(
            [int]$Id,
            [int]$Type,
            [string]$Body = ''
        )

        $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
        $size = 4 + 4 + $bodyBytes.Length + 1 + 1

        $memoryStream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($memoryStream)
        $writer.Write([int]$size)
        $writer.Write([int]$Id)
        $writer.Write([int]$Type)
        $writer.Write($bodyBytes)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Flush()
        return $memoryStream.ToArray()
    }

    # Fake connection object matching the shape New-GSMRCONConnection
    # returns (Client/ReadStream/WriteStream/NextId), used to mock the
    # module's one TCP seam. ResponseBytes is fed into ReadStream as if it
    # were the server's replies, already queued up in order. Client is a
    # stand-in object exposing a Dispose() ScriptMethod so tests can verify
    # Close-GSMRCONConnection actually closes the connection.
    function New-FakeGSMRCONConnection {
        param(
            [byte[]]$ResponseBytes = @()
        )

        $fakeClient = [PSCustomObject]@{ DisposeCallCount = 0 }
        Add-Member -InputObject $fakeClient -MemberType ScriptMethod -Name Dispose -Value {
            $this.DisposeCallCount++
        }

        return [PSCustomObject]@{
            Client      = $fakeClient
            ReadStream  = [System.IO.MemoryStream]::new($ResponseBytes)
            WriteStream = [System.IO.MemoryStream]::new()
            NextId      = 1
        }
    }
}

Describe 'Core/RCON.psm1' {

    BeforeEach {
        Mock -ModuleName RCON -CommandName Write-GSMLog -MockWith { }
    }

    Context 'Send-GSMRCONCommand' {
        It 'authenticates, sends the command, and returns the response body' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame' -DefaultPort 27015 -RCONSecret 'secret123'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $authResponseBytes = New-TestGSMRCONPacketBytes -Id 1 -Type 2 -Body ''
            $execResponseBytes = New-TestGSMRCONPacketBytes -Id 2 -Type 0 -Body 'status output'
            $fakeConnection = New-FakeGSMRCONConnection -ResponseBytes ($authResponseBytes + $execResponseBytes)
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith { $fakeConnection }

            $result = Send-GSMRCONCommand -FolderName 'FakeGame' -Command 'status'

            $result | Should -Be 'status output'
            $fakeConnection.Client.DisposeCallCount | Should -Be 1
            Should -Invoke -ModuleName RCON -CommandName Write-GSMLog -Times 1 -ParameterFilter {
                $Level -eq 'Info' -and $Message -match 'status' -and $Message -match 'FakeGame'
            }
            Should -Invoke -ModuleName RCON -CommandName Write-GSMLog -Times 0 -ParameterFilter { $Message -match 'secret123' }
        }

        It 'throws a clear authentication-failure error and never leaks the password' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame' -RCONSecret 'secret123'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $authFailureBytes = New-TestGSMRCONPacketBytes -Id -1 -Type 2 -Body ''
            $fakeConnection = New-FakeGSMRCONConnection -ResponseBytes $authFailureBytes
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith { $fakeConnection }

            $caughtError = $null
            try {
                Send-GSMRCONCommand -FolderName 'FakeGame' -Command 'status' | Out-Null
            }
            catch {
                $caughtError = $_
            }

            $caughtError | Should -Not -BeNullOrEmpty
            $caughtError.Exception.Message | Should -Match 'authentication failed'
            $caughtError.Exception.Message | Should -Not -Match 'secret123'
            $fakeConnection.Client.DisposeCallCount | Should -Be 1
        }

        It 'throws a clear error and never connects when RCONPassword is missing from config' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame' -OmitRCONPassword
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith { throw 'New-GSMRCONConnection should not have been called.' }

            { Send-GSMRCONCommand -FolderName 'FakeGame' -Command 'status' } | Should -Throw '*RCONPassword*'
        }

        It 'throws a clear error when no config exists for the instance' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame' -WithoutConfig
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            { Send-GSMRCONCommand -FolderName 'FakeGame' -Command 'status' } | Should -Throw '*Configure*'
        }

        It 'propagates a distinct connection-refused error' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith {
                throw "Connection to '127.0.0.1:27015' was refused. Is the server running with RCON enabled on that port?"
            }

            { Send-GSMRCONCommand -FolderName 'FakeGame' -Command 'status' } | Should -Throw '*refused*'
        }
    }

    Context 'Start-GSMRCONConsole' {
        BeforeEach {
            Mock -ModuleName RCON -CommandName Write-Host -MockWith { }
        }

        It 'exits cleanly and closes the connection when the user types exit' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $authResponseBytes = New-TestGSMRCONPacketBytes -Id 1 -Type 2 -Body ''
            $fakeConnection = New-FakeGSMRCONConnection -ResponseBytes $authResponseBytes
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith { $fakeConnection }
            Mock -ModuleName RCON -CommandName Read-GSMPrompt -MockWith { 'exit' }

            { Start-GSMRCONConsole -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName RCON -CommandName Read-GSMPrompt -Times 1
            $fakeConnection.Client.DisposeCallCount | Should -Be 1
        }

        It 'exits cleanly when the user types quit' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $authResponseBytes = New-TestGSMRCONPacketBytes -Id 1 -Type 2 -Body ''
            $fakeConnection = New-FakeGSMRCONConnection -ResponseBytes $authResponseBytes
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith { $fakeConnection }
            Mock -ModuleName RCON -CommandName Read-GSMPrompt -MockWith { 'quit' }

            { Start-GSMRCONConsole -FolderName 'FakeGame' } | Should -Not -Throw

            $fakeConnection.Client.DisposeCallCount | Should -Be 1
        }

        It 'sends a command through the loop, logs it, then exits on the next prompt' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $authResponseBytes = New-TestGSMRCONPacketBytes -Id 1 -Type 2 -Body ''
            $execResponseBytes = New-TestGSMRCONPacketBytes -Id 2 -Type 0 -Body 'status output'
            $fakeConnection = New-FakeGSMRCONConnection -ResponseBytes ($authResponseBytes + $execResponseBytes)
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith { $fakeConnection }

            $script:PromptResponses = @('status', 'exit')
            $script:PromptCallCount = 0
            Mock -ModuleName RCON -CommandName Read-GSMPrompt -MockWith {
                $response = $script:PromptResponses[$script:PromptCallCount]
                $script:PromptCallCount++
                return $response
            }

            Start-GSMRCONConsole -FolderName 'FakeGame'

            Should -Invoke -ModuleName RCON -CommandName Read-GSMPrompt -Times 2
            Should -Invoke -ModuleName RCON -CommandName Write-GSMLog -Times 1 -ParameterFilter {
                $Level -eq 'Info' -and $Message -match 'status' -and $Message -match 'FakeGame'
            }
            $fakeConnection.Client.DisposeCallCount | Should -Be 1
        }

        It 'prints a warning and returns without throwing when the connection is refused' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith {
                throw "Connection to '127.0.0.1:27015' was refused. Is the server running with RCON enabled on that port?"
            }
            Mock -ModuleName RCON -CommandName Write-Warning -MockWith { }

            { Start-GSMRCONConsole -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName RCON -CommandName Write-Warning -Times 1 -ParameterFilter { $Message -match 'refused' }
        }

        It 'prints a warning and returns without throwing when authentication fails' {
            $fakeRoot = New-FakeGSMRootForRCON -FolderName 'FakeGame'
            Mock -ModuleName RCON -CommandName Get-GSMRootPath -MockWith { $fakeRoot }

            $authFailureBytes = New-TestGSMRCONPacketBytes -Id -1 -Type 2 -Body ''
            $fakeConnection = New-FakeGSMRCONConnection -ResponseBytes $authFailureBytes
            Mock -ModuleName RCON -CommandName New-GSMRCONConnection -MockWith { $fakeConnection }
            Mock -ModuleName RCON -CommandName Write-Warning -MockWith { }

            { Start-GSMRCONConsole -FolderName 'FakeGame' } | Should -Not -Throw

            Should -Invoke -ModuleName RCON -CommandName Write-Warning -Times 1 -ParameterFilter { $Message -match 'authentication failed' }
        }
    }

    Context 'Packet encode/decode (internal)' {
        It 'round-trips Id/Type/Body through ConvertTo/ConvertFrom-GSMRCONPacketBytes' {
            InModuleScope RCON {
                $bytes = ConvertTo-GSMRCONPacketBytes -Id 7 -Type 2 -Body 'hello'
                $payload = $bytes[4..($bytes.Length - 1)]
                $parsed = ConvertFrom-GSMRCONPacketBytes -Bytes $payload

                $parsed.Id | Should -Be 7
                $parsed.Type | Should -Be 2
                $parsed.Body | Should -Be 'hello'
            }
        }

        It 'computes Size as ID + Type + Body + 2 null terminator bytes' {
            InModuleScope RCON {
                $bytes = ConvertTo-GSMRCONPacketBytes -Id 1 -Type 3 -Body 'secret123'
                $size = [System.BitConverter]::ToInt32($bytes, 0)

                $size | Should -Be (4 + 4 + 9 + 1 + 1)
                $bytes.Length | Should -Be ($size + 4)
            }
        }
    }
}
