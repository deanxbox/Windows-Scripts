BeforeAll {
    . (Join-Path $PSScriptRoot "Generate-Mc-Server.ps1")
}

Describe "Generate-Mc-Server.ps1" {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mc-server-test-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
    }

    AfterEach {
        if ($script:TestRoot -and
            (Test-Path -LiteralPath $script:TestRoot) -and
            $script:TestRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It "uses the Mojang manifest URL and defaults to releases" {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                versions = @(
                    [pscustomobject]@{ id = "1.21.8"; type = "release" }
                    [pscustomobject]@{ id = "26w01a"; type = "snapshot" }
                )
            }
        }

        $versions = @(Get-MinecraftVersionList)

        $versions.id | Should -Be @("1.21.8")
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
        }
    }

    It "merges parsed Betacraft Alpha and Beta server jars when requested" {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                versions = @(
                    [pscustomobject]@{ id = "1.21.8"; type = "release" }
                    [pscustomobject]@{ id = "26w01a"; type = "snapshot" }
                    [pscustomobject]@{ id = "b1.8.1"; type = "old_beta" }
                )
            }
        }
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = if ($Uri -like "*/beta/") {
                    '<a href="b1.7.3.jar">b1.7.3.jar</a><a href="b1.8.1.jar">b1.8.1.jar</a>'
                }
                else {
                    '<a href="a0.2.5-1004.jar">a0.2.5-1004.jar</a>'
                }
            }
        }

        $versions = @(Get-MinecraftVersionList -IncludeSnapshots -IncludeLegacy)

        $versions.id | Should -Be @("1.21.8", "26w01a", "b1.8.1", "b1.7.3", "a0.2.5-1004")
        $versions[-1].type | Should -Be "old_alpha"
        $versions[-1].legacyServerUrl | Should -Be "https://files.betacraft.uk/server-archive/alpha/a0.2.5-1004.jar"
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://files.betacraft.uk/server-archive/alpha/"
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://files.betacraft.uk/server-archive/beta/"
        }
    }

    It "uses numbered menu input when the host is not interactive" {
        Mock Test-InteractiveHost { $false }
        Mock Read-Host { "2" }

        Select-MenuItem -Prompt "Version" -Item @("one", "two", "three") | Should -Be "two"
    }

    It "defaults a single-select menu to the first item" {
        $state = Update-MenuSelectionState -CursorIndex 0 -ItemCount 3 -Key UpArrow

        $state.CursorIndex | Should -Be 0
        $state.SelectedIndex | Should -Be @(0)
        $state.Confirmed | Should -BeFalse
    }

    It "confirms the highlighted single-select item with Space" {
        $space = Update-MenuSelectionState -CursorIndex 1 -ItemCount 3 -Key Spacebar
        $enter = Update-MenuSelectionState -CursorIndex 1 -ItemCount 3 -Key Enter

        $space.SelectedIndex | Should -Be @(1)
        $space.Confirmed | Should -BeTrue
        $enter.Confirmed | Should -BeTrue
    }

    It "uses the first item when numbered menu input is empty" {
        Mock Test-InteractiveHost { $false }
        Mock Read-Host { "" }

        Select-MenuItem -Prompt "Version" -Item @("latest", "older") | Should -Be "latest"
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
            $Prompt -eq "Version [Default: 1]"
        }
    }

    It "updates interactive multi-select state" {
        $moved = Update-MenuSelectionState -CursorIndex 0 -ItemCount 3 -Key DownArrow
        $selected = Update-MenuSelectionState -CursorIndex $moved.CursorIndex -ItemCount 3 -Key Spacebar -Multiple
        $confirmed = Update-MenuSelectionState -CursorIndex $selected.CursorIndex -ItemCount 3 -Key Enter `
            -SelectedIndex $selected.SelectedIndex -Multiple

        $moved.CursorIndex | Should -Be 1
        $selected.SelectedIndex | Should -Be @(1)
        $confirmed.Confirmed | Should -BeTrue
    }

    It "anchors a menu to the rows reserved after console scrolling" {
        Get-MenuTop -CursorTop 24 -WindowSize 9 | Should -Be 15
        Get-MenuTop -CursorTop 3 -WindowSize 9 | Should -Be 0
    }

    It "creates a named server folder under the invocation location and rejects non-empty conflicts" {
        $target = New-ServerDirectory -Name "My Server" -BaseDirectory $script:TestRoot

        $target | Should -Be (Join-Path $script:TestRoot "My Server")
        Test-Path -LiteralPath $target -PathType Container | Should -BeTrue

        Set-Content -LiteralPath (Join-Path $target "existing.txt") -Value "occupied"
        { New-ServerDirectory -Name "My Server" -BaseDirectory $script:TestRoot } |
            Should -Throw "*already exists and is not empty*"
    }

    It "constructs loader metadata URLs without live network calls" {
        Mock Invoke-RestMethod {
            if ($Uri -eq "https://meta.fabricmc.net/v2/versions/game") {
                return @([pscustomobject]@{ version = "1.21.8"; stable = $true })
            }
            return @(
                [pscustomobject]@{ loader = [pscustomobject]@{ version = "0.17.2" } }
                [pscustomobject]@{ loader = [pscustomobject]@{ version = "0.17.1" } }
            )
        }

        $versions = @(Get-LoaderVersionList -Loader Fabric -MinecraftVersion "1.21.8")

        $versions | Should -Be @("0.17.2", "0.17.1")
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://meta.fabricmc.net/v2/versions/loader/1.21.8"
        }
    }

    It "offers only Vanilla when old Minecraft is absent from Fabric and Quilt metadata" {
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ version = "1.21.8" })
        }

        $loaders = @(Get-AvailableLoaderList -MinecraftVersion "1.0")

        $loaders | Should -Be @("Vanilla")
    }

    It "offers only Vanilla for legacy server archives without querying loader metadata" {
        Mock Invoke-RestMethod { throw "Loader metadata should not be queried." }
        $versionMetadata = [pscustomobject]@{
            legacyServerUrl = "https://files.betacraft.uk/server-archive/beta/b1.8.1.jar"
        }

        $loaders = @(Get-AvailableLoaderList -MinecraftVersion "b1.8.1" -VersionMetadata $versionMetadata)

        $loaders | Should -Be @("Vanilla")
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It "excludes Forge and NeoForge below Minecraft 1.17" {
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ version = "1.16.5" })
        }

        $loaders = @(Get-AvailableLoaderList -MinecraftVersion "1.16.5")

        $loaders | Should -Be @("Vanilla", "Fabric", "Quilt")
    }

    It "offers every loader for a recent supported Minecraft version" {
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ version = "1.21.8" })
        }

        $loaders = @(Get-AvailableLoaderList -MinecraftVersion "1.21.8")

        $loaders | Should -Be @("Vanilla", "Fabric", "NeoForge", "Forge", "Quilt")
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://meta.fabricmc.net/v2/versions/game"
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://meta.quiltmc.org/v3/versions/game"
        }
    }

    It "excludes Vanilla when the version has no server download" {
        Mock Invoke-RestMethod {
            return @([pscustomobject]@{ version = "1.21.8" })
        }

        $versionMetadata = [pscustomobject]@{ downloads = [pscustomobject]@{} }
        $loaders = @(Get-AvailableLoaderList -MinecraftVersion "1.0" -VersionMetadata $versionMetadata)

        $loaders | Should -Be @()
    }

    It "keeps Vanilla when the version metadata lists a server download" {
        Mock Invoke-RestMethod {
            return @([pscustomobject]@{ version = "1.21.8" })
        }

        $versionMetadata = [pscustomobject]@{ downloads = [pscustomobject]@{ server = [pscustomobject]@{ url = "https://example.test/server.jar" } } }
        $loaders = @(Get-AvailableLoaderList -MinecraftVersion "1.21.8" -VersionMetadata $versionMetadata)

        $loaders | Should -Contain "Vanilla"
    }

    It "keeps network metadata failures non-blocking and warns once" {
        Mock Invoke-RestMethod { throw "offline" }
        Mock Write-Warning

        $loaders = @(Get-AvailableLoaderList -MinecraftVersion "1.21.8")

        $loaders | Should -Be @("Vanilla", "NeoForge", "Forge")
        Should -Invoke Write-Warning -Times 1 -Exactly
    }

    It "reads installer versions from mocked Maven metadata" {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '<metadata><versioning><versions><version>0.9.2</version><version>0.12.0</version><version>1.0.3</version></versions></versioning></metadata>'
            }
        }

        $versions = @(Get-InstallerVersionList -Loader Quilt)

        $versions | Should -Be @("1.0.3", "0.12.0", "0.9.2")
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/maven-metadata.xml"
        }
    }

    It "constructs each installer download and CLI" {
        $fabric = Get-InstallerPlan -Loader Fabric -MinecraftVersion "1.21.1" -LoaderVersion "0.16.10" -InstallerVersion "1.0.3" -TargetDirectory $script:TestRoot
        $quilt = Get-InstallerPlan -Loader Quilt -MinecraftVersion "1.21.1" -LoaderVersion "0.28.1" -InstallerVersion "0.12.0" -TargetDirectory $script:TestRoot
        $forge = Get-InstallerPlan -Loader Forge -MinecraftVersion "1.21.1" -LoaderVersion "52.1.0" -TargetDirectory $script:TestRoot
        $neoForge = Get-InstallerPlan -Loader NeoForge -MinecraftVersion "1.21.1" -LoaderVersion "21.1.172" -TargetDirectory $script:TestRoot

        $fabric.Uri | Should -Be "https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.0.3/fabric-installer-1.0.3.jar"
        $fabric.Arguments -join " " | Should -Match "server -dir .* -mcversion 1.21.1 -loader 0.16.10 -downloadMinecraft"
        $quilt.Uri | Should -Be "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/0.12.0/quilt-installer-0.12.0.jar"
        $quilt.Arguments | Should -Contain "--create-scripts"
        $forge.Uri | Should -Be "https://maven.minecraftforge.net/net/minecraftforge/forge/1.21.1-52.1.0/forge-1.21.1-52.1.0-installer.jar"
        $forge.Arguments | Should -Contain "--installServer"
        $neoForge.Uri | Should -Be "https://maven.neoforged.net/releases/net/neoforged/neoforge/21.1.172/neoforge-21.1.172-installer.jar"
        $neoForge.WorkingDirectory | Should -Be $script:TestRoot
    }

    It "assembles Aikar flags and writes a LF-only Fabric start script" {
        $result = New-StartScript -Loader Fabric -TargetDirectory $script:TestRoot -RamGb 6
        $bytes = [System.IO.File]::ReadAllBytes($result.Path)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)

        $result.JavaArguments[0..1] | Should -Be @("-Xms6G", "-Xmx6G")
        $result.JavaArguments | Should -Contain "-XX:+UseG1GC"
        $result.JavaArguments | Should -Contain "-Daikars.new.flags=true"
        $text | Should -Match 'exec java \$JVM_FLAGS -jar fabric-server-launch.jar nogui'
        $text.Contains("`r") | Should -BeFalse
    }

    It "downloads and configures a Vanilla server without loader or mod scanning" {
        Push-Location $script:TestRoot
        try {
            Mock Test-InteractiveHost { $true }
            Mock Select-MenuItem {
                if ($Prompt -eq "Minecraft version") {
                    return [pscustomobject]@{
                        id   = "1.21.8"
                        type = "release"
                        url  = "https://example.test/1.21.8.json"
                    }
                }
                if ($Prompt -eq "Mod loader") {
                    return "Vanilla"
                }
                throw "Unexpected menu: $Prompt"
            }
            Mock Read-Host {
                switch ($Prompt) {
                    "Include Minecraft Snapshots [y/n] [Default N]" { return "" }
                    "Include legacy Alpha/Beta versions [y/n] [Default N]" { return "" }
                    "Server folder name" { return "Vanilla Test" }
                    "Local mods folder (blank for none)" { return "" }
                    "World seed (blank for random)" { return "" }
                    "MOTD" { return "Vanilla server" }
                    "Server icon image (blank for none)" { return "" }
                    default { throw "Unexpected prompt: $Prompt" }
                }
            }
            Mock Read-Integer { 4 }
            Mock Get-MinecraftVersionList {
                @([pscustomobject]@{
                    id   = "1.21.8"
                    type = "release"
                    url  = "https://example.test/1.21.8.json"
                })
            }
            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    downloads = [pscustomobject]@{
                        server = [pscustomobject]@{ url = "https://example.test/server.jar" }
                    }
                }
            }
            Mock Invoke-WebRequest {
                Set-Content -LiteralPath $OutFile -Value "fake server jar"
            }
            Mock Get-LoaderVersionList
            Mock Install-MinecraftServer
            Mock Get-ServerModMetadata
            Mock Test-ModPresent

            Invoke-GenerateMcServer

            $target = Join-Path $script:TestRoot "Vanilla Test"
            Test-Path -LiteralPath (Join-Path $target "server.jar") | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $target "start.sh") -Raw) |
                Should -Match '(?m)^java \$JVM_FLAGS -jar server\.jar nogui$'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -eq "https://example.test/1.21.8.json"
            }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq "https://example.test/server.jar" -and $OutFile -eq (Join-Path $target "server.jar")
            }
            Should -Invoke Get-LoaderVersionList -Times 0
            Should -Invoke Install-MinecraftServer -Times 0
            Should -Invoke Get-ServerModMetadata -Times 0
            Should -Invoke Test-ModPresent -Times 0
            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter {
                $Prompt -eq "Include Minecraft Snapshots [y/n] [Default N]"
            }
            Should -Invoke Read-Host -Times 0 -ParameterFilter {
                $Prompt -eq "Local mods folder (blank for none)"
            }
        }
        finally {
            Pop-Location
        }
    }

    It "falls back to the omniarchive mirror for official releases missing a server download" {
        Push-Location $script:TestRoot
        try {
            Mock Test-InteractiveHost { $true }
            Mock Select-MenuItem {
                if ($Prompt -eq "Minecraft version") {
                    return [pscustomobject]@{ id = "1.0"; type = "release"; url = "https://example.test/1.0.json" }
                }
                if ($Prompt -eq "Mod loader") {
                    return "Vanilla"
                }
                throw "Unexpected menu: $Prompt"
            }
            Mock Write-Warning
            Mock Read-Host {
                switch ($Prompt) {
                    "Include Minecraft Snapshots [y/n] [Default N]" { return "" }
                    "Include legacy Alpha/Beta versions [y/n] [Default N]" { return "" }
                    "Server folder name" { return "Fallback Test" }
                    "Local mods folder (blank for none)" { return "" }
                    "World seed (blank for random)" { return "" }
                    "MOTD" { return "Hi!" }
                    "Server icon image (blank for none)" { return "" }
                    default { throw "Unexpected prompt: $Prompt" }
                }
            }
            Mock Read-Integer { 4 }
            Mock Get-MinecraftVersionList {
                @([pscustomobject]@{ id = "1.0"; type = "release"; url = "https://example.test/1.0.json" })
            }
            Mock Invoke-RestMethod {
                return [pscustomobject]@{ downloads = [pscustomobject]@{} }
            }
            $downloadedFrom = $null
            Mock Invoke-WebRequest {
                $script:downloadedFrom = $Uri
                Set-Content -LiteralPath $OutFile -Value "fake server jar"
            }
            Mock Install-MinecraftServer
            Mock Get-ServerModMetadata
            Mock Test-ModPresent

            Invoke-GenerateMcServer

            Should -Not -Invoke Write-Warning -ParameterFilter {
                $Message -like "Minecraft 1.0 has no official server download*"
            }
            $script:downloadedFrom | Should -Be $script:OfficialReleaseServerFallbackUrls["1.0"]
        }
        finally {
            Pop-Location
        }
    }

    It "re-prompts for a Minecraft version when neither a vanilla download nor a loader is available" {
        Push-Location $script:TestRoot
        try {
            Mock Test-InteractiveHost { $true }
            $script:versionPromptCount = 0
            Mock Select-MenuItem {
                if ($Prompt -eq "Minecraft version") {
                    $script:versionPromptCount++
                    if ($script:versionPromptCount -eq 1) {
                        return [pscustomobject]@{ id = "1.0-test"; type = "release"; url = "https://example.test/1.0-test.json" }
                    }
                    return [pscustomobject]@{ id = "1.21.8"; type = "release"; url = "https://example.test/1.21.8.json" }
                }
                if ($Prompt -eq "Mod loader") {
                    return "Vanilla"
                }
                throw "Unexpected menu: $Prompt"
            }
            Mock Write-Warning
            Mock Read-Host {
                switch ($Prompt) {
                    "Include Minecraft Snapshots [y/n] [Default N]" { return "" }
                    "Include legacy Alpha/Beta versions [y/n] [Default N]" { return "" }
                    "Server folder name" { return "Vanilla Test" }
                    "Local mods folder (blank for none)" { return "" }
                    "World seed (blank for random)" { return "" }
                    "MOTD" { return "Vanilla server" }
                    "Server icon image (blank for none)" { return "" }
                    default { throw "Unexpected prompt: $Prompt" }
                }
            }
            Mock Read-Integer { 4 }
            Mock Get-MinecraftVersionList {
                @(
                    [pscustomobject]@{ id = "1.0-test"; type = "release"; url = "https://example.test/1.0-test.json" }
                    [pscustomobject]@{ id = "1.21.8"; type = "release"; url = "https://example.test/1.21.8.json" }
                )
            }
            Mock Invoke-RestMethod {
                if ($Uri -eq "https://example.test/1.0-test.json") {
                    return [pscustomobject]@{ downloads = [pscustomobject]@{} }
                }
                if ($Uri -like "*fabricmc*" -or $Uri -like "*quiltmc*") {
                    return @([pscustomobject]@{ version = "1.21.8" })
                }
                return [pscustomobject]@{
                    downloads = [pscustomobject]@{
                        server = [pscustomobject]@{ url = "https://example.test/server.jar" }
                    }
                }
            }
            Mock Invoke-WebRequest {
                Set-Content -LiteralPath $OutFile -Value "fake server jar"
            }
            Mock Install-MinecraftServer
            Mock Get-ServerModMetadata
            Mock Test-ModPresent

            Invoke-GenerateMcServer

            $script:versionPromptCount | Should -Be 2
            Should -Invoke Write-Warning -ParameterFilter {
                $Message -like "Minecraft 1.0-test has no official server download*"
            }
            $target = Join-Path $script:TestRoot "Vanilla Test"
            Test-Path -LiteralPath (Join-Path $target "server.jar") | Should -BeTrue
        }
        finally {
            Pop-Location
        }
    }

    It "splices JVM flags before Forge argfiles" {
        Write-Utf8Lf -LiteralPath (Join-Path $script:TestRoot "run.sh") -Content @'
#!/usr/bin/env sh
java @user_jvm_args.txt @libraries/net/minecraftforge/forge/1.21.1/unix_args.txt "$@"
'@

        $result = New-StartScript -Loader Forge -TargetDirectory $script:TestRoot -RamGb 8
        $text = Get-Content -LiteralPath $result.Path -Raw

        $text | Should -Match 'java \$JVM_FLAGS @user_jvm_args\.txt @libraries/.+?/unix_args\.txt nogui "\$@"'
        $result.JavaArguments | Should -Contain "@user_jvm_args.txt"
        $result.JavaArguments[-1] | Should -Be "nogui"
    }

    It "patches server.properties without duplicating keys" {
        $path = Join-Path $script:TestRoot "server.properties"
        Write-Utf8Lf -LiteralPath $path -Content "motd=Old`nview-distance=10`nmotd=Duplicate`n"

        Set-ServerProperty -LiteralPath $path -Name "motd" -Value "New server"
        Set-ServerProperty -LiteralPath $path -Name "level-seed" -Value "12345"
        $lines = Get-Content -LiteralPath $path

        @($lines | Where-Object { $_ -like "motd=*" }) | Should -Be @("motd=New server")
        $lines | Should -Contain "level-seed=12345"
        $lines | Should -Contain "view-distance=10"
    }

    It "writes eula=true" {
        Set-EulaAccepted -TargetDirectory $script:TestRoot

        (Get-Content -LiteralPath (Join-Path $script:TestRoot "eula.txt") -Raw) | Should -Be "eula=true`n"
    }

    It "installs a legacy Vanilla jar directly from Betacraft" {
        $versionMetadata = [pscustomobject]@{
            id              = "b1.8.1"
            type            = "old_beta"
            legacyServerUrl = "https://files.betacraft.uk/server-archive/beta/b1.8.1.jar"
        }
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value "legacy server jar"
        }

        Install-VanillaServer -VersionMetadata $versionMetadata -TargetDirectory $script:TestRoot

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq $versionMetadata.legacyServerUrl -and
            $OutFile -eq (Join-Path $script:TestRoot "server.jar")
        }
    }

    It "skips unsupported legacy prompts and files" {
        Push-Location $script:TestRoot
        try {
            $legacyVersion = [pscustomobject]@{
                id              = "b1.8.1"
                type            = "old_beta"
                legacyServerUrl = "https://files.betacraft.uk/server-archive/beta/b1.8.1.jar"
            }
            Mock Test-InteractiveHost { $true }
            Mock Get-MinecraftVersionList { @($legacyVersion) }
            Mock Select-MenuItem {
                if ($Prompt -eq "Minecraft version") { return $legacyVersion }
                if ($Prompt -eq "Mod loader") { return "Vanilla" }
                throw "Unexpected menu: $Prompt"
            }
            Mock Read-Host {
                switch ($Prompt) {
                    "Include Minecraft Snapshots [y/n] [Default N]" { return "" }
                    "Include legacy Alpha/Beta versions [y/n] [Default N]" { return "y" }
                    "Server folder name" { return "Legacy Test" }
                    "World seed (blank for random)" { return "" }
                    "MOTD" { return "Legacy server" }
                    default { throw "Unexpected prompt: $Prompt" }
                }
            }
            Mock Read-Integer { 4 }
            Mock Invoke-RestMethod { throw "Mojang metadata should not be requested." }
            Mock Invoke-WebRequest {
                Set-Content -LiteralPath $OutFile -Value "legacy server jar"
            }
            Mock Set-ServerIcon
            Mock Set-EulaAccepted

            Invoke-GenerateMcServer

            $target = Join-Path $script:TestRoot "Legacy Test"
            Test-Path -LiteralPath (Join-Path $target "server.jar") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $target "mods") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $target "eula.txt") | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $target "server.properties") -Raw) |
                Should -Match "(?m)^motd=Legacy server$"
            Should -Invoke Invoke-RestMethod -Times 0
            Should -Invoke Set-ServerIcon -Times 0
            Should -Invoke Set-EulaAccepted -Times 0
            Should -Invoke Get-MinecraftVersionList -Times 1 -Exactly -ParameterFilter {
                -not $IncludeSnapshots -and $IncludeLegacy
            }
        }
        finally {
            Pop-Location
        }
    }

    It "parses Fabric metadata from a mod jar zip" {
        $contentDirectory = Join-Path $script:TestRoot "fabric-content"
        $jarPath = Join-Path $script:TestRoot "example.jar"
        New-Item -ItemType Directory -Path $contentDirectory | Out-Null
        @'
{"schemaVersion":1,"id":"example","version":"2.0.0","depends":{"minecraft":">=1.21 <1.22","fabric-api":"*"}}
'@ | Set-Content -LiteralPath (Join-Path $contentDirectory "fabric.mod.json") -Encoding utf8NoBOM
        [System.IO.Compression.ZipFile]::CreateFromDirectory($contentDirectory, $jarPath)

        $metadata = @(Get-ModMetadata -JarPath $jarPath -Loader Fabric)

        $metadata.Count | Should -Be 1
        $metadata[0].ModId | Should -Be "example"
        $metadata[0].MinecraftRange | Should -Be ">=1.21 <1.22"
        $metadata[0].Dependencies[0].Id | Should -Be "fabric-api"
    }

    It "parses Forge and NeoForge TOML mod and dependency sections" {
        $toml = @'
[[mods]]
modId="example"
version="1.2.3"

[[dependencies.example]]
modId="minecraft"
mandatory=true
versionRange="[1.20.1,1.21)"

[[dependencies.example]]
modId="library"
type="required"
versionRange="[2.0,)"
'@

        $metadata = @(ConvertFrom-ModToml -Toml $toml -JarPath "example.jar")

        $metadata.Count | Should -Be 1
        $metadata[0].ModId | Should -Be "example"
        $metadata[0].Version | Should -Be "1.2.3"
        $metadata[0].MinecraftRange | Should -Be "[1.20.1,1.21)"
        $metadata[0].Dependencies[0].Id | Should -Be "library"
        $metadata[0].Dependencies[0].Required | Should -BeTrue
    }

    It "reports likely Minecraft and dependency incompatibilities" {
        $metadata = @(
            [pscustomobject]@{
                JarPath = "example.jar"; ModId = "example"; Version = "1.0"
                MinecraftRange = "[1.20,1.21)"
                Dependencies = @([pscustomobject]@{ Id = "missing-lib"; Range = "*"; Required = $true })
            }
        )

        $warnings = @(Get-ModWarningList -Metadata $metadata -MinecraftVersion "1.21.1" -Loader Fabric)

        $warnings.Count | Should -Be 2
        $warnings.Issue -join "`n" | Should -Match "does not match"
        $warnings.Issue -join "`n" | Should -Match "Missing required dependency"
        Test-VersionConstraint -Version "1.21.1" -Constraint "[1.21.1]" | Should -BeTrue
    }

    It "detects Chunky, BlueMap, and squaremap by mod ID or realistic jar name" {
        $metadata = @(
            [pscustomobject]@{ ModId = "chunky" }
            [pscustomobject]@{ ModId = "bluemap" }
            [pscustomobject]@{ ModId = "squaremap" }
        )
        foreach ($identifier in @("chunky", "bluemap", "squaremap")) {
            Test-ModPresent -Metadata $metadata -ModDirectory $script:TestRoot -Identifier $identifier |
                Should -BeTrue
        }

        $metadata = @([pscustomobject]@{ ModId = "unrelated" })
        foreach ($name in @(
            "BlueMap-5.10-fabric.jar",
            "squaremap-mc1.21.8-1.3.5.jar",
            "Chunky-Fabric-1.4.40.jar"
        )) {
            New-Item -ItemType File -Path (Join-Path $script:TestRoot $name) | Out-Null
        }

        foreach ($identifier in @("chunky", "bluemap", "squaremap")) {
            Test-ModPresent -Metadata $metadata -ModDirectory $script:TestRoot -Identifier $identifier |
                Should -BeTrue
        }
    }

    It "writes Chunky's mod task and config formats without losing existing settings" {
        $configDirectory = Join-Path $script:TestRoot "config/chunky"
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        Write-Utf8Lf -LiteralPath (Join-Path $configDirectory "config.json") `
            -Content '{"language":"en","continueOnRestart":false,"updateInterval":120,"update-interval":120}'

        Set-ChunkyTaskFile -TargetDirectory $script:TestRoot -World "minecraft:the_nether" -CenterX 10 -CenterZ -20 -Radius 3000 -Shape hexagon
        Set-ChunkyContinueOnRestart -TargetDirectory $script:TestRoot

        $task = Get-Content -LiteralPath (Join-Path $script:TestRoot "config/chunky/tasks/minecraft/the_nether.properties") -Raw
        $task | Should -Match "(?m)^world=minecraft:the_nether$"
        $task | Should -Match "(?m)^center-x=10$"
        $task | Should -Match "(?m)^center-z=-20$"
        $task | Should -Match "(?m)^radius=3000$"
        $task | Should -Match "(?m)^shape=hexagon$"
        $task | Should -Match "(?m)^pattern=concentric$"
        $config = Get-Content -LiteralPath (Join-Path $configDirectory "config.json") -Raw | ConvertFrom-Json
        $config.language | Should -Be "en"
        $config.continueOnRestart | Should -BeTrue
        $config.updateInterval | Should -Be 1
        $config.PSObject.Properties.Name | Should -Not -Contain "update-interval"
        $config.silent | Should -BeFalse
    }

    It "keeps Chunky range, shape, and center settings independent per dimension" {
        Mock Select-MenuItem {
            if ($Prompt -eq "Dimensions") { return @("end", "overworld") }
            if ($Prompt -eq "Overworld - Chunky shape") { return "circle" }
            if ($Prompt -eq "End - Chunky shape") { return "hexagon" }
            throw "Unexpected menu: $Prompt"
        }
        Mock Read-Integer {
            switch ($Prompt) {
                "Overworld - Chunky radius (blocks)" { return 4500 }
                "Overworld - Center X" { return 125 }
                "Overworld - Center Z" { return -75 }
                "End - Chunky radius (blocks)" { return 9000 }
                "End - Center X" { return -250 }
                "End - Center Z" { return 350 }
                default { throw "Unexpected integer prompt: $Prompt" }
            }
        }

        $worlds = @(Read-ChunkyConfiguration -TargetDirectory $script:TestRoot)

        $worlds | Should -Be @("minecraft:overworld", "minecraft:the_end")
        $overworld = Get-Content -LiteralPath (Join-Path $script:TestRoot "config/chunky/tasks/minecraft/overworld.properties") -Raw
        $overworld | Should -Match "(?m)^center-x=125$"
        $overworld | Should -Match "(?m)^center-z=-75$"
        $overworld | Should -Match "(?m)^radius=4500$"
        $overworld | Should -Match "(?m)^shape=circle$"

        $end = Get-Content -LiteralPath (Join-Path $script:TestRoot "config/chunky/tasks/minecraft/the_end.properties") -Raw
        $end | Should -Match "(?m)^center-x=-250$"
        $end | Should -Match "(?m)^center-z=350$"
        $end | Should -Match "(?m)^radius=9000$"
        $end | Should -Match "(?m)^shape=hexagon$"
        (Get-Content -LiteralPath (Join-Path $script:TestRoot "config/chunky/config.json") -Raw |
            ConvertFrom-Json).continueOnRestart | Should -BeTrue
    }

    It "boots map mods before overriding threads, pre-generating, and restoring settings" {
        Push-Location $script:TestRoot
        try {
            Mock Test-InteractiveHost { $true }
            Mock Get-MinecraftVersionList {
                @([pscustomobject]@{
                    id   = "1.21.8"
                    type = "release"
                    url  = "https://example.test/1.21.8.json"
                })
            }
            Mock Get-LoaderVersionList { @("0.17.2") }
            Mock Get-InstallerVersionList { @("1.0.3") }
            Mock Get-AvailableLoaderList { @("Vanilla", "Fabric", "NeoForge", "Forge", "Quilt") }
            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    downloads = [pscustomobject]@{
                        server = [pscustomobject]@{ url = "https://example.test/server.jar" }
                    }
                }
            }
            Mock Select-MenuItem {
                switch ($Prompt) {
                    "Minecraft version" {
                        return [pscustomobject]@{
                            id   = "1.21.8"
                            type = "release"
                            url  = "https://example.test/1.21.8.json"
                        }
                    }
                    "Mod loader" { return "Fabric" }
                    "Fabric version" { return "0.17.2" }
                    "Fabric installer version" { return "1.0.3" }
                    "Dimensions" { return @("end", "nether") }
                    "Nether - Chunky shape" { return "hexagon" }
                    "End - Chunky shape" { return "circle" }
                    default { throw "Unexpected menu: $Prompt" }
                }
            }
            Mock Read-Host {
                switch ($Prompt) {
                    "Include Minecraft Snapshots [y/n] [Default N]" { return "" }
                    "Include legacy Alpha/Beta versions [y/n] [Default N]" { return "" }
                    "Server folder name" { return "Chunky Server" }
                    "Local mods folder (blank for none)" { return "" }
                    "World seed (blank for random)" { return "" }
                    "MOTD" { return "Chunky integration test" }
                    "Server icon image (blank for none)" { return "" }
                    default { throw "Unexpected prompt: $Prompt" }
                }
            }
            Mock Read-Integer {
                switch ($Prompt) {
                    "RAM in GB" { return 6 }
                    "Nether - Chunky radius (blocks)" { return 3000 }
                    "Nether - Center X" { return 10 }
                    "Nether - Center Z" { return -20 }
                    "End - Chunky radius (blocks)" { return 6000 }
                    "End - Center X" { return 30 }
                    "End - Center Z" { return 40 }
                    default { throw "Unexpected integer prompt: $Prompt" }
                }
            }
            Mock Install-MinecraftServer
            Mock Write-Host
            Mock Get-ServerModMetadata {
                @(
                    [pscustomobject]@{
                        JarPath = "Chunky-Fabric-1.4.40.jar"; ModId = "chunky"; Version = "1.4.40"
                        MinecraftRange = "*"; Dependencies = @()
                    }
                    [pscustomobject]@{
                        JarPath = "BlueMap-5.10-fabric.jar"; ModId = "bluemap"; Version = "5.10"
                        MinecraftRange = "*"; Dependencies = @()
                    }
                    [pscustomobject]@{
                        JarPath = "squaremap-mc1.21.8-1.3.5.jar"; ModId = "squaremap"; Version = "1.3.5"
                        MinecraftRange = "*"; Dependencies = @()
                    }
                )
            }
            $script:headlessOrder = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-HeadlessPregen {
                if ($StopWhenReady) {
                    $script:headlessOrder.Add("boot")
                    $blueMapDirectory = Join-Path $TargetDirectory "config/bluemap"
                    $squaremapDirectory = Join-Path $TargetDirectory "config/squaremap/worlds"
                    New-Item -ItemType Directory -Path $blueMapDirectory, $squaremapDirectory -Force | Out-Null
                    Write-Utf8Lf -LiteralPath (Join-Path $blueMapDirectory "core.conf") `
                        -Content "accept-download: false`nrender-thread-count: 2`n"
                    Write-Utf8Lf -LiteralPath (Join-Path $squaremapDirectory "world.yml") -Content "map:`n  max-render-threads: -1`n"
                    return
                }

                $blueMapConfig = Get-Content -LiteralPath (Join-Path $TargetDirectory "config/bluemap/core.conf") -Raw
                $squaremapConfig = Get-Content -LiteralPath (Join-Path $TargetDirectory "config/squaremap/worlds/world.yml") -Raw
                if ($blueMapConfig -notmatch "accept-download: true" -or
                    $blueMapConfig -notmatch "render-thread-count: 0" -or
                    $squaremapConfig -notmatch "max-render-threads: $([Environment]::ProcessorCount)") {
                    throw "Map thread overrides were not applied before pre-generation."
                }
                $script:headlessOrder.Add("pregen")
            }

            Invoke-GenerateMcServer

            $target = Join-Path $script:TestRoot "Chunky Server"
            foreach ($path in @(
                (Join-Path $target "config/chunky/tasks/minecraft/the_nether.properties"),
                (Join-Path $target "config/chunky/tasks/minecraft/the_end.properties")
            )) {
                Test-Path -LiteralPath $path | Should -BeTrue
            }
            (Get-Content -LiteralPath (Join-Path $target "config/chunky/tasks/minecraft/the_nether.properties") -Raw) |
                Should -Match "(?m)^shape=hexagon$"
            (Get-Content -LiteralPath (Join-Path $target "config/chunky/tasks/minecraft/the_end.properties") -Raw) |
                Should -Match "(?m)^shape=circle$"
            (Get-Content -LiteralPath (Join-Path $target "config/chunky/config.json") -Raw |
                ConvertFrom-Json).continueOnRestart | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:TestRoot "config/chunky") | Should -BeFalse
            $script:headlessOrder | Should -Be @("boot", "pregen")
            (Get-Content -LiteralPath (Join-Path $target "config/bluemap/core.conf") -Raw) |
                Should -Match "render-thread-count: 2"
            (Get-Content -LiteralPath (Join-Path $target "config/bluemap/core.conf") -Raw) |
                Should -Match "accept-download: true"
            (Get-Content -LiteralPath (Join-Path $target "config/squaremap/worlds/world.yml") -Raw) |
                Should -Match "max-render-threads: -1"
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -eq "BlueMap and squaremap will render automatically in the background during the pre-generation run below."
            }
            Should -Invoke Invoke-HeadlessPregen -Times 1 -Exactly -ParameterFilter {
                $TargetDirectory -eq $target -and $StopWhenReady
            }
            Should -Invoke Invoke-HeadlessPregen -Times 1 -Exactly -ParameterFilter {
                $TargetDirectory -eq $target -and
                -not $StopWhenReady -and
                $ExpectedCompletion -contains "Chunky:minecraft:the_nether" -and
                $ExpectedCompletion -contains "Chunky:minecraft:the_end" -and
                $ExpectedCompletion.Count -eq 2 -and
                $ExpectedCompletion -notcontains "BlueMap" -and
                $ExpectedCompletion -notcontains "squaremap" -and
                ($ChunkyWorldSequence -join ",") -eq "minecraft:the_nether,minecraft:the_end"
            }
        }
        finally {
            Pop-Location
        }
    }

    It "temporarily changes and restores map render thread settings" {
        $blueMapDirectory = Join-Path $script:TestRoot "config/bluemap"
        $squaremapDirectory = Join-Path $script:TestRoot "config/squaremap/worlds"
        New-Item -ItemType Directory -Path $blueMapDirectory, $squaremapDirectory -Force | Out-Null
        Write-Utf8Lf -LiteralPath (Join-Path $blueMapDirectory "core.conf") `
            -Content "# accept-download: false`nrender-thread-count: 2`n"
        Write-Utf8Lf -LiteralPath (Join-Path $squaremapDirectory "world.yml") -Content @'
map:
  enabled: true
  max-render-threads: -1
  background-render:
    max-render-threads: 1
'@

        $changes = @(Set-MapThreadOverride -TargetDirectory $script:TestRoot -BlueMap $true -Squaremap $true)

        (Get-Content -LiteralPath (Join-Path $blueMapDirectory "core.conf") -Raw) | Should -Match "render-thread-count: 0"
        (Get-Content -LiteralPath (Join-Path $blueMapDirectory "core.conf") -Raw) | Should -Match "accept-download: true"
        (Get-Content -LiteralPath (Join-Path $squaremapDirectory "world.yml") -Raw) |
            Should -Match "max-render-threads: $([Environment]::ProcessorCount)"
        $changes.Count | Should -Be 2

        Restore-MapThreadOverride -Change $changes

        (Get-Content -LiteralPath (Join-Path $blueMapDirectory "core.conf") -Raw) | Should -Match "render-thread-count: 2"
        (Get-Content -LiteralPath (Join-Path $blueMapDirectory "core.conf") -Raw) | Should -Match "accept-download: true"
        (Get-Content -LiteralPath (Join-Path $squaremapDirectory "world.yml") -Raw) | Should -Match "max-render-threads: -1"
    }

    It "stops the configuration-seeding boot after the server ready message" {
        $standardInput = [pscustomobject]@{
            Lines = [System.Collections.Generic.List[string]]::new()
        }
        $standardInput | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param($Value)
            $this.Lines.Add($Value)
        }
        $process = [pscustomobject]@{
            HasExited    = $false
            StandardInput = $standardInput
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            $this.HasExited = $true
            return $Milliseconds -gt 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            param($EntireProcessTree)
            $this.HasExited = $EntireProcessTree
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

        Mock Start-HeadlessServerProcess { $process }
        Mock Start-Sleep {
            $logDirectory = Join-Path $script:TestRoot "logs"
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
            Write-Utf8Lf -LiteralPath (Join-Path $logDirectory "latest.log") `
                -Content '[Server thread/INFO]: Done (4.321s)! For help, type "help"'
        }

        Invoke-HeadlessPregen -TargetDirectory $script:TestRoot -JavaArguments @("-jar", "server.jar") -StopWhenReady

        $standardInput.Lines | Should -Be @("stop")
        $process.HasExited | Should -BeTrue
        Should -Invoke Start-HeadlessServerProcess -Times 1 -Exactly
    }

    It "sequences Chunky worlds and prints heartbeat and map completion status" {
        $standardInput = [pscustomobject]@{
            Lines = [System.Collections.Generic.List[string]]::new()
        }
        $standardInput | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param($Value)
            $this.Lines.Add($Value)
        }
        $process = [pscustomobject]@{
            HasExited    = $false
            StandardInput = $standardInput
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            $this.HasExited = $true
            return $Milliseconds -gt 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            param($EntireProcessTree)
            $this.HasExited = $EntireProcessTree
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

        $worlds = @("minecraft:overworld", "minecraft:the_nether", "minecraft:the_end")
        $script:now = [DateTime]::new(2026, 9, 13, 12, 0, 0, [DateTimeKind]::Utc)
        $script:poll = 0
        $script:logText = ""
        Mock Get-UtcNow { $script:now }
        Mock Start-HeadlessServerProcess { $process }
        Mock Write-Host
        Mock Write-Warning
        Mock Start-Sleep {
            $script:now = $script:now.AddSeconds(2)
            $script:poll++
            $newLine = switch ($script:poll) {
                1 { '[Server thread/INFO]: Done (4.321s)! For help, type "help"' }
                4 { "Task finished for minecraft:overworld. Processed: 100 chunks" }
                5 { "Task finished for minecraft:the_nether. Processed: 100 chunks`nBlueMap map render finished" }
                6 { "Task finished for minecraft:the_end. Processed: 100 chunks`squaremap map render complete" }
            }
            if ($newLine) {
                $script:logText += "$newLine`n"
                $logDirectory = Join-Path $script:TestRoot "logs"
                New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
                Write-Utf8Lf -LiteralPath (Join-Path $logDirectory "latest.log") -Content $script:logText
            }
        }

        Invoke-HeadlessPregen -TargetDirectory $script:TestRoot -JavaArguments @("-jar", "server.jar") `
            -ChunkyWorldSequence $worlds -ExpectedCompletion @(
                "Chunky:minecraft:overworld",
                "Chunky:minecraft:the_nether",
                "Chunky:minecraft:the_end",
                "BlueMap",
                "squaremap"
            )

        $standardInput.Lines | Should -Be @(
            "chunky pause minecraft:the_nether",
            "chunky pause minecraft:the_end",
            "chunky continue minecraft:the_nether",
            "chunky continue minecraft:the_end",
            "stop"
        )
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like "Still waiting for pre-generation...*"
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq "BlueMap render detected as finished."
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq "squaremap render detected as finished."
        }
        Should -Not -Invoke Write-Warning -ParameterFilter {
            $Message -like "No server-log activity was detected*"
        }
    }

    It "breaks on expected completion when a Chunky message is split across two log reads" {
        $standardInput = [pscustomobject]@{
            Lines = [System.Collections.Generic.List[string]]::new()
        }
        $standardInput | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param($Value)
            $this.Lines.Add($Value)
        }
        $process = [pscustomobject]@{
            HasExited     = $false
            StandardInput = $standardInput
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            return $Milliseconds -gt 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            param($EntireProcessTree)
            $this.HasExited = $EntireProcessTree
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

        $worlds = @("minecraft:overworld", "minecraft:the_nether", "minecraft:the_end")
        $finished = '[04:47:48 INFO] [Server thread]: [MinecraftServer] [Chunky] Task finished for ' +
            'minecraft:overworld. Processed: 16129 chunks (100.00%), Total time: 0:00:55'
        $script:now = [DateTime]::new(2026, 9, 13, 12, 0, 0, [DateTimeKind]::Utc)
        $script:poll = 0
        $script:logText = ""
        Mock Get-UtcNow { $script:now }
        Mock Start-HeadlessServerProcess { $process }
        Mock Write-Host
        Mock Write-Warning
        Mock Start-Sleep {
            $script:now = $script:now.AddSeconds(2)
            $script:poll++
            # Poll 3 flushes the overworld line without its newline, poll 4 supplies
            # the remainder, so the completion text spans two reads.
            $addition = switch ($script:poll) {
                1 { '[Server thread/INFO]: Done (4.321s)! For help, type "help"' + "`n" }
                3 { $finished.Substring(0, 100) }
                4 { $finished.Substring(100) + "`n" }
                6 { "Task finished for minecraft:the_nether. Processed: 100 chunks`n" }
                8 { "Task finished for minecraft:the_end. Processed: 100 chunks`n" }
            }
            if ($addition) {
                $script:logText += $addition
                $logDirectory = Join-Path $script:TestRoot "logs"
                New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
                Write-Utf8Lf -LiteralPath (Join-Path $logDirectory "latest.log") -Content $script:logText
            }
        }

        Invoke-HeadlessPregen -TargetDirectory $script:TestRoot -JavaArguments @("-jar", "server.jar") `
            -ChunkyWorldSequence $worlds -ExpectedCompletion @(
            "Chunky:minecraft:overworld",
            "Chunky:minecraft:the_nether",
            "Chunky:minecraft:the_end"
        )

        # The loop must stop on the completion match, not the 120-second idle fallback.
        $script:poll | Should -Be 8
        $standardInput.Lines | Should -Be @(
            "chunky pause minecraft:the_nether",
            "chunky pause minecraft:the_end",
            "chunky continue minecraft:the_nether",
            "chunky continue minecraft:the_end",
            "stop"
        )
        Should -Invoke Write-Host -ParameterFilter {
            $Object -eq "Detected pre-generation completion in the server log."
        }
        Should -Not -Invoke Write-Warning -ParameterFilter {
            $Message -like "No server-log activity was detected*"
        }
    }

    It "stops after Chunky finishes without waiting for map completion messages" {
        $standardInput = [pscustomobject]@{
            Lines = [System.Collections.Generic.List[string]]::new()
        }
        $standardInput | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param($Value)
            $this.Lines.Add($Value)
        }
        $process = [pscustomobject]@{
            HasExited     = $false
            StandardInput = $standardInput
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            $this.HasExited = $true
            return $Milliseconds -gt 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            param($EntireProcessTree)
            $this.HasExited = $EntireProcessTree
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

        $world = "minecraft:overworld"
        $script:now = [DateTime]::new(2026, 9, 13, 12, 0, 0, [DateTimeKind]::Utc)
        $script:poll = 0
        $script:logText = ""
        Mock Get-UtcNow { $script:now }
        Mock Start-HeadlessServerProcess { $process }
        Mock Write-Host
        Mock Write-Warning
        Mock Start-Sleep {
            $script:now = $script:now.AddSeconds(2)
            $script:poll++
            $newLine = switch ($script:poll) {
                1 { '[Server thread/INFO]: Done (4.321s)! For help, type "help"' }
                2 { "Task finished for $world. Processed: 16129 chunks (100.00%)" }
            }
            if ($newLine) {
                $script:logText += "$newLine`n"
                $logDirectory = Join-Path $script:TestRoot "logs"
                New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
                Write-Utf8Lf -LiteralPath (Join-Path $logDirectory "latest.log") -Content $script:logText
            }
        }

        Invoke-HeadlessPregen -TargetDirectory $script:TestRoot -JavaArguments @("-jar", "server.jar") `
            -ChunkyWorldSequence @($world) -ExpectedCompletion @("Chunky:$world")

        $script:poll | Should -Be 2
        $standardInput.Lines | Should -Be @("stop")
        Should -Not -Invoke Write-Warning -ParameterFilter {
            $Message -like "No server-log activity was detected*"
        }
        Should -Not -Invoke Write-Host -ParameterFilter {
            $Object -like "*render detected as finished."
        }
    }

    It "mocks Java installer execution" {
        $plan = Get-InstallerPlan -Loader NeoForge -MinecraftVersion "1.21.1" -LoaderVersion "21.1.172" -TargetDirectory $script:TestRoot
        Mock Get-Command { [pscustomobject]@{ Source = "java" } } -ParameterFilter { $Name -eq "java" }
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value "fake installer"
        }
        Mock Invoke-ExternalCommand

        Install-MinecraftServer -Plan $plan -TargetDirectory $script:TestRoot

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $plan.Uri }
        Should -Invoke Invoke-ExternalCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "java" -and $ArgumentList -contains "--installServer"
        }
    }

    It "mocks ffmpeg icon conversion" {
        $imagePath = Join-Path $script:TestRoot "icon.jpg"
        Set-Content -LiteralPath $imagePath -Value "fake image"
        Mock Get-Command { [pscustomobject]@{ Source = "ffmpeg" } } -ParameterFilter { $Name -eq "ffmpeg" }
        Mock Invoke-ExternalCommand

        Set-ServerIcon -ImagePath $imagePath -TargetDirectory $script:TestRoot

        Should -Invoke Invoke-ExternalCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "ffmpeg" -and
            $ArgumentList -contains "scale=64:64:force_original_aspect_ratio=decrease,pad=64:64:(ow-iw)/2:(oh-ih)/2:color=0x00000000"
        }
    }

    It "runs reconfigure mode without installation or network access" {
        Mock Test-InteractiveHost { $true }
        Mock Get-InstalledLoader { "Fabric" }
        Mock Read-Integer { 10 }
        Mock New-StartScript {
            [pscustomobject]@{ Path = Join-Path $TargetDirectory "start.sh"; JavaArguments = @() }
        }
        Mock Install-MinecraftServer
        Mock Invoke-RestMethod
        Mock Invoke-WebRequest

        Invoke-GenerateMcServer -ReconfigureMode -RequestedServerPath $script:TestRoot

        Should -Invoke New-StartScript -Times 1 -Exactly -ParameterFilter {
            $Loader -eq "Fabric" -and $RamGb -eq 10
        }
        Should -Invoke Install-MinecraftServer -Times 0
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
    }
}
