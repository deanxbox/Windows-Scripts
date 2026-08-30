BeforeAll {
    . (Join-Path $PSScriptRoot 'Update-AmongUsMalumMenu.ps1')
}

Describe 'Update-AmongUsMalumMenu.ps1' {
    It 'normalizes release and DLL versions for comparison' {
        (ConvertTo-MalumMenuVersion -Version 'v3.3.0') | Should -Be ([version]'3.3.0.0')
        (ConvertTo-MalumMenuVersion -Version '3.3.0.0') | Should -Be ([version]'3.3.0.0')
    }

    It 'requires Among Us.exe in a custom directory' {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('among-us-test-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $testRoot | Out-Null
            Test-AmongUsDirectory -Path $testRoot | Should -BeFalse
            New-Item -ItemType File -Path (Join-Path $testRoot 'Among Us.exe') | Out-Null
            Test-AmongUsDirectory -Path $testRoot | Should -BeTrue
        }
        finally {
            if ((Test-Path -LiteralPath $testRoot) -and
                $testRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }

    It 'selects only the two platform zip assets from a release' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = 'v3.3.0'
                assets   = @(
                    [pscustomobject]@{ name = 'MalumMenu-3.3.0.dll'; browser_download_url = 'dll' }
                    [pscustomobject]@{ name = 'MalumMenu-3.3.0-Steam-Itch.zip'; browser_download_url = 'steam' }
                    [pscustomobject]@{ name = 'MalumMenu-3.3.0-MicrosoftStore-EpicGames-XboxApp.zip'; browser_download_url = 'microsoft' }
                )
            }
        }

        $release = Get-MalumMenuRelease

        $release.Version | Should -Be ([version]'3.3.0.0')
        $release.SteamUrl | Should -Be 'steam'
        $release.MicrosoftUrl | Should -Be 'microsoft'
    }

    It 'can start and quit cleanly when no installation is detected' {
        Mock Get-SteamAmongUsDirectory
        Mock Get-EpicAmongUsDirectory
        Mock Read-CustomGameDirectory
        Mock Read-Host { 'Q' } -ParameterFilter { $Prompt -eq 'Choice' }

        { Invoke-MalumMenuUpdater } | Should -Not -Throw
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -eq 'Choice' }
    }
}
