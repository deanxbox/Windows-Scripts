BeforeAll {
    $script:InstallModPath = Join-Path $PSScriptRoot "Install-Mod.ps1"
    $script:PowerShellPath = Join-Path $PSHOME "pwsh.exe"
    $script:InstallModSource = Get-Content -LiteralPath $script:InstallModPath -Raw
    $script:InstallModFunctionsSource = $script:InstallModSource.Substring(
        $script:InstallModSource.IndexOf("function Test-InteractiveHost")
    ).Split('$projectRoot = Get-NormalizedPath -Path $ProjectPath', 2)[0] +
        "`nExport-ModuleMember -Function Get-PrismInstance"
    $script:InstallModFunctions = New-Module -Name InstallModFunctions -ScriptBlock (
        [scriptblock]::Create($script:InstallModFunctionsSource)
    )

    function ConvertTo-SingleQuotedPowerShellLiteral {
        param([Parameter(Mandatory)][string]$Value)

        return "'" + $Value.Replace("'", "''") + "'"
    }

    function Invoke-InstallModProcess {
        param(
            [Parameter(Mandatory)][string]$ProjectPath,
            [string]$PrismPath,
            [string]$Instance,
            [string]$Artifact,
            [Parameter(Mandatory)][string]$StatePath,
            [switch]$Preview,
            [switch]$NoPersist
        )

        $arguments = @(
            "-ProjectPath $(ConvertTo-SingleQuotedPowerShellLiteral $ProjectPath)"
            "-StatePath $(ConvertTo-SingleQuotedPowerShellLiteral $StatePath)"
            "-Confirm:`$false"
        )
        if ($PrismPath) {
            $arguments += "-PrismPath $(ConvertTo-SingleQuotedPowerShellLiteral $PrismPath)"
        }
        if ($Instance) {
            $arguments += "-Instance $(ConvertTo-SingleQuotedPowerShellLiteral $Instance)"
        }
        if ($Artifact) {
            $arguments += "-Artifact $(ConvertTo-SingleQuotedPowerShellLiteral $Artifact)"
        }
        if ($Preview) {
            $arguments += "-WhatIf"
        }
        if ($NoPersist) {
            $arguments += "-NoPersist"
        }

        $scriptLiteral = ConvertTo-SingleQuotedPowerShellLiteral $script:InstallModPath
        $command = @"
`$ErrorActionPreference = 'Stop'
try {
    `$result = & $scriptLiteral $($arguments -join " ")
    [pscustomobject]@{ Success = `$true; Result = `$result; Error = `$null } |
        ConvertTo-Json -Depth 6 -Compress
    exit 0
}
catch {
    [pscustomobject]@{ Success = `$false; Result = `$null; Error = `$_.Exception.Message } |
        ConvertTo-Json -Depth 6 -Compress
    exit 1
}
"@
        $output = & $script:PowerShellPath -NoProfile -NonInteractive -Command $command 2>&1
        $exitCode = $LASTEXITCODE
        $json = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith("{") }) |
            Select-Object -Last 1

        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = @($output)
            Response = if ($json) { $json | ConvertFrom-Json }
        }
    }
}

Describe "Install-Mod.ps1" {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
            "install-mod-test-" + [guid]::NewGuid().ToString("N")
        )
        $script:ProjectPath = Join-Path $script:TestRoot "mod project"
        $script:PrismPath = Join-Path $script:TestRoot "PrismLauncher"
        $script:InstancePath = Join-Path $script:PrismPath "instances\test-instance"
        $script:LibraryPath = Join-Path $script:ProjectPath "build\libs"
        $script:StatePath = Join-Path $script:TestRoot "state\state.json"

        New-Item -ItemType Directory -Path (
            Join-Path $script:ProjectPath "src\main\resources"
        ), $script:LibraryPath, $script:InstancePath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ProjectPath "build.gradle.kts") -Value "plugins {}"
        Set-Content -LiteralPath (
            Join-Path $script:ProjectPath "src\main\resources\fabric.mod.json"
        ) -Value "{}"
        Set-Content -LiteralPath (Join-Path $script:InstancePath "instance.cfg") -Value "name=Test Instance"
    }

    AfterEach {
        if ($script:TestRoot -and
            (Test-Path -LiteralPath $script:TestRoot) -and
            $script:TestRoot.StartsWith(
                [System.IO.Path]::GetTempPath(),
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It "declares automation parameters and ShouldProcess support" {
        $command = Get-Command $script:InstallModPath

        $command.Parameters.Keys | Should -Contain "ProjectPath"
        $command.Parameters.Keys | Should -Contain "PrismPath"
        $command.Parameters.Keys | Should -Contain "Instance"
        $command.Parameters.Keys | Should -Contain "Artifact"
        $command.Parameters.Keys | Should -Contain "StatePath"
        $command.Parameters.Keys | Should -Contain "NoPersist"
        $command.Parameters.Keys | Should -Contain "WhatIf"
        $command.Parameters.Keys | Should -Contain "Confirm"
    }

    It "installs the primary jar and persists the selected instance" {
        $primaryJar = Join-Path $script:LibraryPath "example-1.0.0.jar"
        $sourceJar = Join-Path $script:LibraryPath "example-1.0.0-sources.jar"
        Set-Content -LiteralPath $primaryJar -Value "primary"
        Set-Content -LiteralPath $sourceJar -Value "sources"

        $process = Invoke-InstallModProcess `
            -ProjectPath $script:ProjectPath `
            -PrismPath $script:PrismPath `
            -Instance "Test Instance" `
            -StatePath $script:StatePath

        $destination = Join-Path $script:InstancePath "minecraft\mods\example-1.0.0.jar"
        $sourceDestination = Join-Path $script:InstancePath "minecraft\mods\example-1.0.0-sources.jar"
        $wrongDestination = Join-Path $script:InstancePath ".minecraft\mods\example-1.0.0.jar"
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $process.Response.Success | Should -BeTrue
        $process.Response.Result.Installed | Should -BeTrue
        $process.Response.Result.DefaultPersisted | Should -BeTrue
        $process.Response.Result.DestinationPath | Should -Be $destination
        Get-Content -LiteralPath $destination -Raw | Should -Match "primary"
        Test-Path -LiteralPath $sourceDestination | Should -BeFalse
        Test-Path -LiteralPath $wrongDestination | Should -BeFalse
        $state.PrismPath | Should -Be $script:PrismPath
        $state.InstancePath | Should -Be $script:InstancePath
    }

    It "reuses persisted Prism and instance paths without prompting" {
        $jar = Join-Path $script:LibraryPath "example.jar"
        Set-Content -LiteralPath $jar -Value "primary"
        New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($script:StatePath)) |
            Out-Null
        [pscustomobject]@{
            PrismPath    = $script:PrismPath
            InstancePath = $script:InstancePath
        } | ConvertTo-Json | Set-Content -LiteralPath $script:StatePath

        $process = Invoke-InstallModProcess `
            -ProjectPath $script:ProjectPath `
            -StatePath $script:StatePath

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $process.Response.Result.InstanceName | Should -Be "Test Instance"
        $process.Response.Result.DefaultPersisted | Should -BeTrue
    }

    It "recognizes minecraft-directory and instance.cfg instances when prompting" {
        $otherInstancePath = Join-Path $script:PrismPath "instances\alpha-instance"
        New-Item -ItemType Directory -Path (Join-Path $otherInstancePath "minecraft") -Force | Out-Null

        $menu = $script:InstallModFunctions.Invoke({
            param($RootPath, $SavedInstancePath)

            $script:menuCall = $null
            function Select-MenuItem {
                param($Prompt, $Item, $Label, $DefaultIndex)

                $script:menuCall = [pscustomobject]@{
                    Prompt       = $Prompt
                    Item         = @($Item)
                    Label        = $Label
                    DefaultIndex = $DefaultIndex
                }
                return $Item[$DefaultIndex]
            }

            $selected = Get-PrismInstance -RootPath $RootPath -SavedState ([pscustomobject]@{
                InstancePath = $SavedInstancePath
            }) -CanPrompt $true

            [pscustomobject]@{
                Item         = $script:menuCall.Item
                DefaultIndex = $script:menuCall.DefaultIndex
                Selected     = $selected
            }
        }, $script:PrismPath, $script:InstancePath)

        $menu.Item.Count | Should -Be 2
        $menu.Item.Id | Should -Contain "alpha-instance"
        $menu.Item[0].Id | Should -Be "test-instance"
        $menu.DefaultIndex | Should -Be 0
        $menu.Selected.Id | Should -Be "test-instance"
    }

    It "does not copy or persist under WhatIf" {
        Set-Content -LiteralPath (Join-Path $script:LibraryPath "example.jar") -Value "primary"

        $process = Invoke-InstallModProcess `
            -ProjectPath $script:ProjectPath `
            -PrismPath $script:PrismPath `
            -Instance "test-instance" `
            -StatePath $script:StatePath `
            -Preview

        $destination = Join-Path $script:InstancePath "minecraft\mods\example.jar"
        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $process.Response.Result.Installed | Should -BeFalse
        $process.Response.Result.DefaultPersisted | Should -BeFalse
        Test-Path -LiteralPath $destination | Should -BeFalse
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
    }

    It "accepts a project-relative artifact path across multiple build outputs" {
        $moduleLibrary = Join-Path $script:ProjectPath "fabric\build\libs"
        New-Item -ItemType Directory -Path $moduleLibrary -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:LibraryPath "common.jar") -Value "common"
        Set-Content -LiteralPath (Join-Path $moduleLibrary "fabric.jar") -Value "fabric"

        $process = Invoke-InstallModProcess `
            -ProjectPath $script:ProjectPath `
            -PrismPath $script:PrismPath `
            -Instance "test-instance" `
            -Artifact "fabric\build\libs\fabric.jar" `
            -StatePath $script:StatePath `
            -NoPersist

        $destination = Join-Path $script:InstancePath "minecraft\mods\fabric.jar"
        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        Get-Content -LiteralPath $destination -Raw | Should -Match "fabric"
        Test-Path -LiteralPath $script:StatePath | Should -BeFalse
    }

    It "requires an artifact selector for multiple primary jars without a terminal" {
        Set-Content -LiteralPath (Join-Path $script:LibraryPath "first.jar") -Value "first"
        Set-Content -LiteralPath (Join-Path $script:LibraryPath "second.jar") -Value "second"

        $process = Invoke-InstallModProcess `
            -ProjectPath $script:ProjectPath `
            -PrismPath $script:PrismPath `
            -Instance "test-instance" `
            -StatePath $script:StatePath

        $process.ExitCode | Should -Not -Be 0
        $process.Response.Success | Should -BeFalse
        $process.Response.Error | Should -Match "Multiple mod jars were found"
    }

    It "rejects a non-mod project before resolving Prism Launcher" {
        Remove-Item -LiteralPath (
            Join-Path $script:ProjectPath "src\main\resources\fabric.mod.json"
        )
        Set-Content -LiteralPath (Join-Path $script:LibraryPath "example.jar") -Value "primary"

        $process = Invoke-InstallModProcess `
            -ProjectPath $script:ProjectPath `
            -PrismPath (Join-Path $script:TestRoot "missing Prism") `
            -StatePath $script:StatePath

        $process.ExitCode | Should -Not -Be 0
        $process.Response.Error | Should -Match "does not look like a Minecraft mod Gradle project"
        $process.Response.Error | Should -Not -Match "Prism path"
    }
}
