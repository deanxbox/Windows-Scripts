BeforeAll {
    $script:PowerShellPath = Join-Path $PSHOME "pwsh.exe"
}

Describe "projectdump.ps1" {
    It "excludes local agent metadata" {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("projectdump-test-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Path (Join-Path $testRoot ".claude") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $testRoot ".claude\secret.txt") -Value "private-marker"
            Set-Content -LiteralPath (Join-Path $testRoot ".env.local") -Value "env-secret-marker"
            Set-Content -LiteralPath (Join-Path $testRoot "visible.txt") -Value "visible-marker"

            $output = & (Join-Path $PSScriptRoot "projectdump.ps1") $testRoot -NoClip | Out-String

            $output | Should -Match "visible-marker"
            $output | Should -Not -Match "private-marker"
            $output | Should -Not -Match "env-secret-marker"
        }
        finally {
            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }
}

Describe "updateprofile.ps1" {
    It "does not add Pester test files to the profile" {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("updateprofile-test-" + [guid]::NewGuid().ToString("N"))
        $profilePath = Join-Path $testRoot "profile.ps1"
        try {
            New-Item -ItemType Directory -Path $testRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $testRoot "tool.ps1") -Value "'tool'"
            Set-Content -LiteralPath (Join-Path $testRoot "tool.Tests.ps1") -Value "'test'"

            & $script:PowerShellPath `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -File (Join-Path $PSScriptRoot "updateprofile.ps1") `
                -ScriptsDir $testRoot `
                -ProfilePath $profilePath `
                -NoReload `
                -NoPause *> $null

            $LASTEXITCODE | Should -Be 0
            $profileContent = Get-Content -LiteralPath $profilePath -Raw
            $profileContent | Should -Match "tool\.ps1"
            $profileContent | Should -Not -Match "tool\.Tests\.ps1"
        }
        finally {
            if (Test-Path -LiteralPath $testRoot) {
                Remove-Item -LiteralPath $testRoot -Recurse -Force
            }
        }
    }
}

Describe "Set-PowerProfile.ps1" {
    It "keeps Profile as a compatibility alias" {
        $command = Get-Command (Join-Path $PSScriptRoot "Set-PowerProfile.ps1")
        $command.Parameters["ProfileName"].Aliases | Should -Contain "Profile"
    }

    It "labels WhatIf output as a preview" {
        $output = & $script:PowerShellPath `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File (Join-Path $PSScriptRoot "Set-PowerProfile.ps1") `
            -ProfileName Default `
            -WhatIf `
            -NoPause 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match "Preview complete\. No settings were changed\."
        $output | Should -Not -Match "Not running as Administrator"
    }
}

Describe "Apply-GPUPreferences.ps1" {
    It "completes a WhatIf run without registry writes" {
        Mock Read-Host { "H" } -ParameterFilter { $Prompt -eq "Select GPU preference" }
        Mock Read-Host { "" } -ParameterFilter { $Prompt -eq "Select [1]" }
        Mock Read-Host { "N" } -ParameterFilter { $Prompt -eq "Choice" }
        Mock Get-CimInstance { @() } -ParameterFilter { $ClassName -eq "Win32_VideoController" }
        Mock Get-ChildItem { @() }

        { & (Join-Path $PSScriptRoot "Apply-GPUPreferences.ps1") -WhatIf -NoPause *> $null } |
            Should -Not -Throw
        Should -Invoke Read-Host -Times 3 -Exactly
    }
}
