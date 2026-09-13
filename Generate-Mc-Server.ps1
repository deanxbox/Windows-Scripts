# Generate-Mc-Server.ps1
# Interactively installs and configures a Vanilla, Fabric, Quilt, Forge, or NeoForge server.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "", Justification = "Script parameters are consumed by the nested entry-point function.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Private helpers run only after the interactive workflow has collected explicit paths and choices.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "", Justification = "Metadata is a mass noun in the private helper names.")]
[CmdletBinding()]
param(
    [switch]$Reconfigure,

    [string]$ServerPath
)

$script:VersionManifestUrl = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
$script:LegacyServerArchiveUrl = "https://files.betacraft.uk/server-archive"
$script:OfficialReleaseServerFallbackUrls = @{
    "1.0"   = "https://vault.omniarchive.uk/archive/java/server-release/1.0.0/1.0.0.jar"
    "1.1"   = "https://vault.omniarchive.uk/archive/java/server-release/1.1/1.1.jar"
    "1.2.1" = "https://vault.omniarchive.uk/archive/java/server-release/1.2/1.2.1.jar"
    "1.2.2" = "https://vault.omniarchive.uk/archive/java/server-release/1.2/1.2.2.jar"
    "1.2.3" = "https://vault.omniarchive.uk/archive/java/server-release/1.2/1.2.3.jar"
    "1.2.4" = "https://vault.omniarchive.uk/archive/java/server-release/1.2/1.2.4.jar"
}
$script:FabricGameUrl = "https://meta.fabricmc.net/v2/versions/game"
$script:FabricLoaderUrl = "https://meta.fabricmc.net/v2/versions/loader"
$script:FabricInstallerMetadataUrl = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml"
$script:QuiltGameUrl = "https://meta.quiltmc.org/v3/versions/game"
$script:QuiltLoaderUrl = "https://meta.quiltmc.org/v3/versions/loader"
$script:QuiltInstallerMetadataUrl = "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/maven-metadata.xml"
$script:ForgePromotionsUrl = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"
$script:ForgeMetadataUrl = "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
$script:NeoForgeMetadataUrl = "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
$script:ChunkyShapes = @("square", "circle", "triangle", "diamond", "pentagon", "hexagon", "star", "rectangle", "ellipse")
$script:AikarFlags = @(
    "-XX:+UseG1GC"
    "-XX:+ParallelRefProcEnabled"
    "-XX:MaxGCPauseMillis=200"
    "-XX:+UnlockExperimentalVMOptions"
    "-XX:+DisableExplicitGC"
    "-XX:+AlwaysPreTouch"
    "-XX:G1NewSizePercent=30"
    "-XX:G1MaxNewSizePercent=40"
    "-XX:G1HeapRegionSize=8M"
    "-XX:G1ReservePercent=20"
    "-XX:G1HeapWastePercent=5"
    "-XX:G1MixedGCCountTarget=4"
    "-XX:InitiatingHeapOccupancyPercent=15"
    "-XX:G1MixedGCLiveThresholdPercent=90"
    "-XX:G1RSetUpdatingPauseTimePercent=5"
    "-XX:SurvivorRatio=32"
    "-XX:+PerfDisableSharedMem"
    "-XX:MaxTenuringThreshold=1"
    "-Dusing.aikars.flags=https://mcflags.emc.gs"
    "-Daikars.new.flags=true"
)

function Test-InteractiveHost {
    return [Environment]::UserInteractive -and
        $null -ne $Host.UI -and
        -not [Console]::IsInputRedirected -and
        -not ([Environment]::GetCommandLineArgs() -contains "-NonInteractive")
}

function Write-Utf8Lf {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText(
        $LiteralPath,
        $normalized,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-RequiredText {
    param([Parameter(Mandatory)][string]$Prompt)

    while ($true) {
        $value = (Read-Host $Prompt).Trim().Trim('"')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        Write-Host "A value is required." -ForegroundColor Yellow
    }
}

function Read-Integer {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [int]$Minimum = [int]::MinValue,
        [int]$Default = 0
    )

    while ($true) {
        $raw = (Read-Host "$Prompt [$Default]").Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }

        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -ge $Minimum) {
            return $value
        }
        Write-Host "Enter a whole number greater than or equal to $Minimum." -ForegroundColor Yellow
    }
}

function Update-MenuSelectionState {
    param(
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$CursorIndex,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ItemCount,
        [Parameter(Mandatory)][ConsoleKey]$Key,
        [AllowEmptyCollection()][int[]]$SelectedIndex = @(),
        [switch]$Multiple
    )

    $CursorIndex = [Math]::Min($CursorIndex, $ItemCount - 1)
    $selected = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($index in $SelectedIndex) {
        if ($index -ge 0 -and $index -lt $ItemCount) {
            $null = $selected.Add($index)
        }
    }

    switch ($Key) {
        "UpArrow" { $CursorIndex = [Math]::Max(0, $CursorIndex - 1) }
        "DownArrow" { $CursorIndex = [Math]::Min($ItemCount - 1, $CursorIndex + 1) }
        "Spacebar" {
            if ($Multiple -and -not $selected.Remove($CursorIndex)) {
                $null = $selected.Add($CursorIndex)
            }
        }
    }

    if (-not $Multiple) {
        $selected.Clear()
        $null = $selected.Add($CursorIndex)
    }

    return [pscustomobject]@{
        CursorIndex  = $CursorIndex
        SelectedIndex = @($selected | Sort-Object)
        Confirmed    = if ($Multiple) {
            $Key -eq [ConsoleKey]::Enter -and $selected.Count -gt 0
        }
        else {
            $Key -in [ConsoleKey]::Spacebar, [ConsoleKey]::Enter
        }
    }
}

function Read-NumberedMenuItem {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Item,
        [scriptblock]$Label = { param($Value) [string]$Value },
        [switch]$Multiple,
        [AllowEmptyCollection()][int[]]$DefaultIndex = @()
    )

    $defaultIndexes = @($DefaultIndex | Where-Object { $_ -ge 0 -and $_ -lt $Item.Count } | Select-Object -Unique)
    if (-not $Multiple -and $defaultIndexes.Count -eq 0) {
        $defaultIndexes = @(0)
    }

    for ($index = 0; $index -lt $Item.Count; $index++) {
        Write-Host ("  [{0}] {1}" -f ($index + 1), (& $Label $Item[$index]))
    }

    while ($true) {
        $suffix = if ($Multiple) { " (comma-separated, blank for defaults)" } else { " [Default: $($defaultIndexes[0] + 1)]" }
        $choice = (Read-Host "$Prompt$suffix").Trim()
        if ($Multiple) {
            if (-not $choice -and $defaultIndexes.Count -gt 0) {
                $selectedItems = @($defaultIndexes | ForEach-Object { $Item[$_] })
                Write-Host "Selected: $(@($selectedItems | ForEach-Object { & $Label $_ }) -join ', ')" -ForegroundColor Green
                return $selectedItems
            }

            $parts = @($choice -split '\s*,\s*')
            $selectedIndexes = @($parts | ForEach-Object {
                $selected = 0
                if ([int]::TryParse($_, [ref]$selected) -and $selected -ge 1 -and $selected -le $Item.Count) {
                    $selected - 1
                }
            })
            if ($selectedIndexes.Count -eq $parts.Count) {
                $selectedItems = @($selectedIndexes | Select-Object -Unique | ForEach-Object { $Item[$_] })
                Write-Host "Selected: $(@($selectedItems | ForEach-Object { & $Label $_ }) -join ', ')" -ForegroundColor Green
                return $selectedItems
            }

            Write-Host "Enter one or more listed numbers." -ForegroundColor Yellow
            continue
        }

        if (-not $choice) {
            Write-Host "Selected: $(& $Label $Item[$defaultIndexes[0]])" -ForegroundColor Green
            return $Item[$defaultIndexes[0]]
        }

        $selected = 0
        if ([int]::TryParse($choice, [ref]$selected) -and $selected -ge 1 -and $selected -le $Item.Count) {
            Write-Host "Selected: $(& $Label $Item[$selected - 1])" -ForegroundColor Green
            return $Item[$selected - 1]
        }

        $exact = @($Item | Where-Object { (& $Label $_) -eq $choice })
        if ($exact.Count -eq 1) {
            Write-Host "Selected: $(& $Label $exact[0])" -ForegroundColor Green
            return $exact[0]
        }
        Write-Host "Enter a listed number or exact value." -ForegroundColor Yellow
    }
}

function Get-MenuTop {
    param(
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$CursorTop,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$WindowSize
    )

    return [Math]::Max(0, $CursorTop - $WindowSize)
}

function Select-MenuItem {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Item,
        [scriptblock]$Label = { param($Value) [string]$Value },
        [switch]$Multiple,
        [AllowEmptyCollection()][int[]]$DefaultIndex = @()
    )

    $defaultIndexes = @($DefaultIndex | Where-Object { $_ -ge 0 -and $_ -lt $Item.Count } | Select-Object -Unique)
    if (-not $Multiple -and $defaultIndexes.Count -eq 0) {
        $defaultIndexes = @(0)
    }

    if (-not (Test-InteractiveHost)) {
        return Read-NumberedMenuItem -Prompt $Prompt -Item $Item -Label $Label -Multiple:$Multiple -DefaultIndex $defaultIndexes
    }

    try {
        $windowSize = [Math]::Min(10, $Item.Count)
        $cursorIndex = if ($defaultIndexes.Count -gt 0) { $defaultIndexes[0] } else { 0 }
        $selectedIndex = $defaultIndexes
        $originalCursorVisible = [Console]::CursorVisible
        [Console]::CursorVisible = $false
        $controls = if ($Multiple) { "↑/↓ navigate, Space to toggle, Enter to confirm" } else { "↑/↓ navigate, Space to select" }
        Write-Host "$Prompt ($controls)"
        for ($row = 0; $row -lt $windowSize; $row++) {
            Write-Host ""
        }
        $menuTop = Get-MenuTop -CursorTop ([Console]::CursorTop) -WindowSize $windowSize

        while ($true) {
            $windowStart = [Math]::Min(
                [Math]::Max(0, $cursorIndex - [Math]::Floor($windowSize / 2)),
                [Math]::Max(0, $Item.Count - $windowSize)
            )
            $width = [Math]::Max(1, [Console]::BufferWidth - 1)
            for ($row = 0; $row -lt $windowSize; $row++) {
                $itemIndex = $windowStart + $row
                $cursorMarker = if ($itemIndex -eq $cursorIndex) { ">" } else { " " }
                $selectionMarker = if ($Multiple) {
                    if ($selectedIndex -contains $itemIndex) { "[x]" } else { "[ ]" }
                }
                else {
                    " "
                }
                $line = "$cursorMarker$selectionMarker $(& $Label $Item[$itemIndex])"
                if ($line.Length -gt $width) {
                    $line = $line.Substring(0, $width)
                }
                [Console]::SetCursorPosition(0, $menuTop + $row)
                [Console]::Write($line.PadRight($width))
            }
            [Console]::SetCursorPosition(0, $menuTop + $windowSize)

            $state = Update-MenuSelectionState -CursorIndex $cursorIndex -ItemCount $Item.Count `
                -Key ([Console]::ReadKey($true).Key) -SelectedIndex $selectedIndex -Multiple:$Multiple
            $cursorIndex = $state.CursorIndex
            $selectedIndex = @($state.SelectedIndex)
            if ($state.Confirmed) {
                if ($Multiple) {
                    $selectedItems = @($selectedIndex | ForEach-Object { $Item[$_] })
                    Write-Host "Selected: $(@($selectedItems | ForEach-Object { & $Label $_ }) -join ', ')" -ForegroundColor Green
                    return $selectedItems
                }
                Write-Host "Selected: $(& $Label $Item[$cursorIndex])" -ForegroundColor Green
                return $Item[$cursorIndex]
            }
        }
    }
    catch {
        if ($null -ne $originalCursorVisible) {
            try {
                [Console]::CursorVisible = $originalCursorVisible
                $originalCursorVisible = $null
            }
            catch {
                Write-Verbose "Could not restore console cursor visibility before numbered fallback."
            }
        }
        Write-Warning "Interactive menu is unavailable; using numbered input."
        return Read-NumberedMenuItem -Prompt $Prompt -Item $Item -Label $Label -Multiple:$Multiple -DefaultIndex $defaultIndexes
    }
    finally {
        if ($null -ne $originalCursorVisible) {
            try {
                [Console]::CursorVisible = $originalCursorVisible
            }
            catch {
                Write-Verbose "Could not restore console cursor visibility."
            }
        }
    }
}

function New-ServerDirectory {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$BaseDirectory = (Get-Location).ProviderPath
    )

    $Name = $Name.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($Name) -or
        [System.IO.Path]::IsPathRooted($Name) -or
        $Name -in ".", ".." -or
        $Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $Name.Contains([System.IO.Path]::DirectorySeparatorChar) -or
        $Name.Contains([System.IO.Path]::AltDirectorySeparatorChar)) {
        throw "Enter a server folder name, not a path."
    }

    $target = [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Name))
    if (Test-Path -LiteralPath $target) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "A non-directory item already exists at '$target'."
        }
        if (Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1) {
            throw "Server folder '$target' already exists and is not empty."
        }
    }
    else {
        New-Item -ItemType Directory -Path $target | Out-Null
    }
    return $target
}

function Get-MavenVersionList {
    param([Parameter(Mandatory)][string]$Uri)

    [xml]$metadata = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -ErrorAction Stop).Content
    return @($metadata.metadata.versioning.versions.version | ForEach-Object { [string]$_ })
}

function Get-SortedVersionList {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Version)

    return @(
        $Version | Sort-Object {
            [regex]::Replace([string]$_, '\d+', { param($Match) $Match.Value.PadLeft(10, "0") })
        } -Descending
    )
}

function Get-MinecraftVersionList {
    param(
        [switch]$IncludeSnapshots,
        [switch]$IncludeLegacy
    )

    $manifest = Invoke-RestMethod -Uri $script:VersionManifestUrl -ErrorAction Stop
    $versions = @(
        $manifest.versions | Where-Object {
            $_.type -eq "release" -or ($IncludeSnapshots -and $_.type -eq "snapshot")
        }
    )
    if ($IncludeLegacy) {
        $versions += @(Get-LegacyServerJarList)
    }
    return $versions
}

function Get-LegacyServerJarList {
    $versions = foreach ($archive in @(
        [pscustomobject]@{ Path = "beta"; Type = "old_beta" }
        [pscustomobject]@{ Path = "alpha"; Type = "old_alpha" }
    )) {
        $baseUri = "$script:LegacyServerArchiveUrl/$($archive.Path)/"
        $content = (Invoke-WebRequest -Uri $baseUri -UseBasicParsing -ErrorAction Stop).Content
        foreach ($match in [regex]::Matches($content, 'href="([^"]+\.jar)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $href = $match.Groups[1].Value
            [pscustomobject]@{
                id              = [System.IO.Path]::GetFileNameWithoutExtension([Uri]::UnescapeDataString($href))
                type            = $archive.Type
                legacyServerUrl = ([Uri]::new([Uri]$baseUri, $href)).AbsoluteUri
            }
        }
    }

    return @(
        $versions | Sort-Object {
            [regex]::Replace([string]$_.id, '\d+', { param($Match) $Match.Value.PadLeft(10, "0") })
        } -Descending
    )
}

function Test-MinecraftAtLeast {
    param(
        [Parameter(Mandatory)][string]$MinecraftVersion,
        [Parameter(Mandatory)][version]$Minimum
    )

    $parsed = $null
    return [version]::TryParse($MinecraftVersion, [ref]$parsed) -and $parsed -ge $Minimum
}

function Get-NeoForgeMinecraftVersion {
    param([Parameter(Mandatory)][string]$NeoForgeVersion)

    if ($NeoForgeVersion -notmatch '^(\d+)\.(\d+)(?:\.|$)') {
        return $null
    }
    return "1.$($Matches[1]).$($Matches[2])"
}

function Get-LoaderSupportedMinecraftVersionList {
    param([Parameter(Mandatory)][ValidateSet("Fabric", "Quilt")][string]$Loader)

    $uri = if ($Loader -eq "Fabric") { $script:FabricGameUrl } else { $script:QuiltGameUrl }
    return @((Invoke-RestMethod -Uri $uri -ErrorAction Stop).version)
}

function Get-AvailableLoaderList {
    param(
        [Parameter(Mandatory)][string]$MinecraftVersion,
        [pscustomobject]$VersionMetadata
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$VersionMetadata.legacyServerUrl)) {
        return @("Vanilla")
    }

    $available = @{ Fabric = $false; Quilt = $false }
    $warned = $false
    foreach ($loader in @("Fabric", "Quilt")) {
        try {
            $available[$loader] = $MinecraftVersion -in (Get-LoaderSupportedMinecraftVersionList -Loader $loader)
        }
        catch {
            if (-not $warned) {
                Write-Warning "Could not check mod loader compatibility metadata; affected loaders will be unavailable. $($_.Exception.Message)"
                $warned = $true
            }
        }
    }

    $vanillaAvailable = if ($VersionMetadata) {
        -not [string]::IsNullOrWhiteSpace([string]$VersionMetadata.downloads.server.url)
    }
    else {
        $true
    }

    return @(
        if ($vanillaAvailable) { "Vanilla" }
        if ($available.Fabric) { "Fabric" }
        if (Test-MinecraftAtLeast -MinecraftVersion $MinecraftVersion -Minimum ([version]"1.17")) {
            "NeoForge"
            "Forge"
        }
        if ($available.Quilt) { "Quilt" }
    )
}

function Get-LoaderVersionList {
    param(
        [Parameter(Mandatory)][ValidateSet("Fabric", "Quilt", "Forge", "NeoForge")][string]$Loader,
        [Parameter(Mandatory)][string]$MinecraftVersion
    )

    switch ($Loader) {
        "Fabric" {
            $supported = @(Get-LoaderSupportedMinecraftVersionList -Loader Fabric)
            if ($MinecraftVersion -notin $supported) {
                throw "Fabric metadata does not list Minecraft $MinecraftVersion."
            }
            return @(
                Invoke-RestMethod -Uri "$($script:FabricLoaderUrl)/$MinecraftVersion" -ErrorAction Stop |
                    ForEach-Object { $_.loader.version }
            )
        }
        "Quilt" {
            $supported = @(Get-LoaderSupportedMinecraftVersionList -Loader Quilt)
            if ($MinecraftVersion -notin $supported) {
                throw "Quilt metadata does not list Minecraft $MinecraftVersion."
            }
            return @(
                Invoke-RestMethod -Uri "$($script:QuiltLoaderUrl)/$MinecraftVersion" -ErrorAction Stop |
                    ForEach-Object { $_.loader.version }
            )
        }
        "Forge" {
            if (-not (Test-MinecraftAtLeast -MinecraftVersion $MinecraftVersion -Minimum ([version]"1.17"))) {
                throw "Forge automation requires a numeric Minecraft 1.17+ release; install legacy or snapshot servers manually."
            }

            $promotions = Invoke-RestMethod -Uri $script:ForgePromotionsUrl -ErrorAction Stop
            $preferred = @(
                $promotions.promos."$MinecraftVersion-recommended"
                $promotions.promos."$MinecraftVersion-latest"
            ) | Where-Object { $_ } | Select-Object -Unique
            $all = Get-MavenVersionList -Uri $script:ForgeMetadataUrl |
                Where-Object { $_ -like "$MinecraftVersion-*" } |
                ForEach-Object { $_.Substring($MinecraftVersion.Length + 1) }
            return @($preferred + @(Get-SortedVersionList -Version $all) | Select-Object -Unique)
        }
        "NeoForge" {
            if (-not (Test-MinecraftAtLeast -MinecraftVersion $MinecraftVersion -Minimum ([version]"1.17"))) {
                throw "NeoForge automation requires a numeric Minecraft 1.17+ release; install legacy or snapshot servers manually."
            }

            return @(
                Get-SortedVersionList -Version @(
                    Get-MavenVersionList -Uri $script:NeoForgeMetadataUrl |
                        Where-Object { (Get-NeoForgeMinecraftVersion $_) -eq $MinecraftVersion }
                )
            )
        }
    }
}

function Get-InstallerVersionList {
    param([Parameter(Mandatory)][ValidateSet("Fabric", "Quilt")][string]$Loader)

    $uri = if ($Loader -eq "Fabric") {
        $script:FabricInstallerMetadataUrl
    }
    else {
        $script:QuiltInstallerMetadataUrl
    }
    return @(Get-SortedVersionList -Version (Get-MavenVersionList -Uri $uri))
}

function Get-InstallerPlan {
    param(
        [Parameter(Mandatory)][ValidateSet("Fabric", "Quilt", "Forge", "NeoForge")][string]$Loader,
        [Parameter(Mandatory)][string]$MinecraftVersion,
        [Parameter(Mandatory)][string]$LoaderVersion,
        [string]$InstallerVersion,
        [Parameter(Mandatory)][string]$TargetDirectory
    )

    switch ($Loader) {
        "Fabric" {
            $name = "fabric-installer-$InstallerVersion.jar"
            return [pscustomobject]@{
                Uri       = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/$InstallerVersion/$name"
                FileName  = $name
                Arguments = @("-jar", $name, "server", "-dir", $TargetDirectory, "-mcversion", $MinecraftVersion, "-loader", $LoaderVersion, "-downloadMinecraft")
                WorkingDirectory = $TargetDirectory
            }
        }
        "Quilt" {
            return [pscustomobject]@{
                Uri       = "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/$InstallerVersion/quilt-installer-$InstallerVersion.jar"
                FileName  = "quilt-installer.jar"
                Arguments = @("-jar", "quilt-installer.jar", "install", "server", $MinecraftVersion, $LoaderVersion, "--install-dir=$TargetDirectory", "--create-scripts", "--download-server")
                WorkingDirectory = $TargetDirectory
            }
        }
        "Forge" {
            $name = "forge-$MinecraftVersion-$LoaderVersion-installer.jar"
            return [pscustomobject]@{
                Uri       = "https://maven.minecraftforge.net/net/minecraftforge/forge/$MinecraftVersion-$LoaderVersion/$name"
                FileName  = $name
                Arguments = @("-jar", $name, "--installServer", $TargetDirectory)
                WorkingDirectory = $TargetDirectory
            }
        }
        "NeoForge" {
            $name = "neoforge-$LoaderVersion-installer.jar"
            return [pscustomobject]@{
                Uri       = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$LoaderVersion/$name"
                FileName  = $name
                Arguments = @("-jar", $name, "--installServer")
                WorkingDirectory = $TargetDirectory
            }
        }
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "'$FilePath' exited with code $($process.ExitCode)."
    }
}

function Install-MinecraftServer {
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][string]$TargetDirectory
    )

    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        throw "Java was not found on PATH."
    }

    $installerPath = Join-Path ([System.IO.Path]::GetTempPath()) ("generate-mc-" + [guid]::NewGuid().ToString("N") + ".jar")
    $arguments = @($Plan.Arguments)
    $arguments[1] = $installerPath
    $workingDirectory = if ($Plan.WorkingDirectory) { $Plan.WorkingDirectory } else { $TargetDirectory }
    try {
        Write-Host "Downloading installer..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $Plan.Uri -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
        Write-Host "Running installer..." -ForegroundColor Cyan
        Invoke-ExternalCommand -FilePath "java" -ArgumentList $arguments -WorkingDirectory $workingDirectory
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }
    }
}

function Install-VanillaServer {
    param(
        [Parameter(Mandatory)][pscustomobject]$VersionMetadata,
        [Parameter(Mandatory)][string]$TargetDirectory
    )

    $serverUrl = [string]$VersionMetadata.legacyServerUrl
    if ([string]::IsNullOrWhiteSpace($serverUrl)) {
        $serverUrl = [string]$VersionMetadata.downloads.server.url
    }
    if ([string]::IsNullOrWhiteSpace($serverUrl)) {
        throw "The selected Minecraft version does not provide a vanilla server download."
    }

    Write-Host "Downloading vanilla server..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $serverUrl -OutFile (Join-Path $TargetDirectory "server.jar") -UseBasicParsing -ErrorAction Stop
}

function Get-JvmFlagList {
    param([Parameter(Mandatory)][ValidateRange(1, 1024)][int]$RamGb)

    return @("-Xms$($RamGb)G", "-Xmx$($RamGb)G") + $script:AikarFlags
}

function Get-QuiltLaunchJar {
    param([Parameter(Mandatory)][string]$TargetDirectory)

    $jar = Get-ChildItem -LiteralPath $TargetDirectory -File -Filter "*.jar" |
        Where-Object {
            $_.Name -notmatch 'installer' -and
            ($_.Name -eq "quilt-server-launch.jar" -or $_.Name -match 'server.*launch|launch.*server')
        } |
        Sort-Object { if ($_.Name -eq "quilt-server-launch.jar") { 0 } else { 1 } }, Name |
        Select-Object -First 1
    if (-not $jar) {
        throw "Could not find Quilt's generated server launch jar in '$TargetDirectory'."
    }
    return $jar.Name
}

function Get-RunShInvocation {
    param([Parameter(Mandatory)][string]$RunShPath)

    $line = Get-Content -LiteralPath $RunShPath |
        Where-Object { $_ -match '^\s*(?:exec\s+)?java(?:\s|$)' } |
        Select-Object -Last 1
    if (-not $line) {
        throw "Could not find the final java invocation in '$RunShPath'."
    }

    $line = $line.Trim() -replace '^exec\s+', ''
    $line = $line -replace '^java\s+', ''
    $tokens = [regex]::Matches($line, '(?:"[^"]*"|''[^'']*''|\S)+') |
        ForEach-Object { $_.Value.Trim('"', "'") } |
        Where-Object { $_ -notin '$@', '"$@"', "'$@'" }
    return @($tokens)
}

function New-StartScript {
    param(
        [Parameter(Mandatory)][ValidateSet("Vanilla", "Fabric", "Quilt", "Forge", "NeoForge")][string]$Loader,
        [Parameter(Mandatory)][string]$TargetDirectory,
        [Parameter(Mandatory)][ValidateRange(1, 1024)][int]$RamGb
    )

    $flags = Get-JvmFlagList -RamGb $RamGb
    $quotedFlags = $flags -join " "
    $javaArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($flag in $flags) {
        $javaArguments.Add($flag)
    }

    switch ($Loader) {
        "Vanilla" {
            $launchArguments = @("-jar", "server.jar", "nogui")
            $command = 'java $JVM_FLAGS -jar server.jar nogui'
        }
        "Fabric" {
            $launchArguments = @("-jar", "fabric-server-launch.jar", "nogui")
            $command = 'exec java $JVM_FLAGS -jar fabric-server-launch.jar nogui'
        }
        "Quilt" {
            $jar = Get-QuiltLaunchJar -TargetDirectory $TargetDirectory
            $launchArguments = @("-jar", $jar, "nogui")
            $command = "exec java `$JVM_FLAGS -jar '$jar' nogui"
        }
        default {
            $runArguments = Get-RunShInvocation -RunShPath (Join-Path $TargetDirectory "run.sh")
            $launchArguments = @($runArguments | Where-Object { $_ -notin '$@', '"$@"', "'$@'" }) + "nogui"
            $shellArguments = ($runArguments | Where-Object { $_ -notin '$@', '"$@"', "'$@'" }) -join " "
            $command = "exec java `$JVM_FLAGS $shellArguments nogui `"`$@`""
        }
    }

    foreach ($argument in $launchArguments) {
        $javaArguments.Add($argument)
    }

    $content = @"
#!/usr/bin/env bash
JVM_FLAGS='$quotedFlags'
$command
"@
    $path = Join-Path $TargetDirectory "start.sh"
    Write-Utf8Lf -LiteralPath $path -Content ($content.TrimEnd() + "`n")
    return [pscustomobject]@{
        Path          = $path
        JavaArguments = $javaArguments.ToArray()
    }
}

function Get-InstalledLoader {
    param([Parameter(Mandatory)][string]$TargetDirectory)

    if (Test-Path -LiteralPath (Join-Path $TargetDirectory "fabric-server-launch.jar")) {
        return "Fabric"
    }
    if (Get-ChildItem -LiteralPath $TargetDirectory -File -Filter "*.jar" -ErrorAction SilentlyContinue |
        Where-Object Name -Match 'quilt.*server.*launch|quilt-server-launch') {
        return "Quilt"
    }
    if (Test-Path -LiteralPath (Join-Path $TargetDirectory "run.sh")) {
        $runText = Get-Content -LiteralPath (Join-Path $TargetDirectory "run.sh") -Raw
        return if ($runText -match 'neoforge') { "NeoForge" } else { "Forge" }
    }
    if (Test-Path -LiteralPath (Join-Path $TargetDirectory "server.jar")) {
        return "Vanilla"
    }
    throw "Could not detect an installed Vanilla, Fabric, Quilt, Forge, or NeoForge server in '$TargetDirectory'."
}

function Set-ServerProperty {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $lines = if (Test-Path -LiteralPath $LiteralPath) {
        @(Get-Content -LiteralPath $LiteralPath)
    }
    else {
        @()
    }
    $replacement = "$Name=$Value"
    $found = $false
    $updated = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -match "^\s*$([regex]::Escape($Name))=") {
            if (-not $found) {
                $updated.Add($replacement)
                $found = $true
            }
        }
        else {
            $updated.Add($line)
        }
    }
    if (-not $found) {
        $updated.Add($replacement)
    }
    Write-Utf8Lf -LiteralPath $LiteralPath -Content (($updated -join "`n") + "`n")
}

function Set-EulaAccepted {
    param([Parameter(Mandatory)][string]$TargetDirectory)

    Write-Utf8Lf -LiteralPath (Join-Path $TargetDirectory "eula.txt") -Content "eula=true`n"
}

function Set-ServerIcon {
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$TargetDirectory
    )

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "Server icon '$ImagePath' does not exist."
    }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw "ffmpeg is required to create server-icon.png but was not found on PATH."
    }

    $arguments = @(
        "-y", "-i", ([System.IO.Path]::GetFullPath($ImagePath)),
        "-vf", "scale=64:64:force_original_aspect_ratio=decrease,pad=64:64:(ow-iw)/2:(oh-ih)/2:color=0x00000000",
        "-frames:v", "1",
        (Join-Path $TargetDirectory "server-icon.png")
    )
    Invoke-ExternalCommand -FilePath "ffmpeg" -ArgumentList $arguments -WorkingDirectory $TargetDirectory
}

function Copy-ModJar {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$TargetDirectory
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw "Mods folder '$SourceDirectory' does not exist."
    }

    $modDirectory = Join-Path $TargetDirectory "mods"
    New-Item -ItemType Directory -Path $modDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $SourceDirectory -File -Filter "*.jar" |
        Copy-Item -Destination $modDirectory -Force
    return $modDirectory
}

function Get-ZipEntryText {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][string[]]$EntryName
    )

    foreach ($name in $EntryName) {
        $entry = $Archive.GetEntry($name)
        if ($entry) {
            $reader = [System.IO.StreamReader]::new($entry.Open())
            try {
                return $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
    }
    return $null
}

function ConvertFrom-FabricModJson {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$JarPath
    )

    $data = $Json | ConvertFrom-Json -ErrorAction Stop
    $minecraftRange = $null
    $dependencies = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($data.depends) {
        foreach ($property in $data.depends.PSObject.Properties) {
            $range = if ($property.Value -is [array]) { $property.Value -join " || " } else { [string]$property.Value }
            if ($property.Name -eq "minecraft") {
                $minecraftRange = $range
            }
            else {
                $dependencies.Add([pscustomobject]@{ Id = $property.Name; Range = $range; Required = $true })
            }
        }
    }

    return [pscustomobject]@{
        JarPath        = $JarPath
        ModId          = [string]$data.id
        Version        = [string]$data.version
        MinecraftRange = $minecraftRange
        Dependencies   = $dependencies.ToArray()
    }
}

function ConvertFrom-QuiltModJson {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$JarPath
    )

    $data = ($Json | ConvertFrom-Json -ErrorAction Stop).quilt_loader
    $minecraftRange = $null
    $dependencies = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($dependency in @($data.depends)) {
        if ($dependency -is [string]) {
            $id = [string]$dependency
            $range = "*"
        }
        else {
            $id = [string]$dependency.id
            $range = if ($dependency.versions -is [array]) { $dependency.versions -join " || " } else { [string]$dependency.versions }
        }
        if ($id -eq "minecraft") {
            $minecraftRange = $range
        }
        elseif ($id) {
            $dependencies.Add([pscustomobject]@{ Id = $id; Range = $range; Required = $true })
        }
    }

    return [pscustomobject]@{
        JarPath        = $JarPath
        ModId          = [string]$data.id
        Version        = [string]$data.version
        MinecraftRange = $minecraftRange
        Dependencies   = $dependencies.ToArray()
    }
}

function ConvertFrom-ModToml {
    param(
        [Parameter(Mandatory)][string]$Toml,
        [Parameter(Mandatory)][string]$JarPath
    )

    $mods = [System.Collections.Generic.List[pscustomobject]]::new()
    $dependencyByOwner = @{}
    $section = ""
    $currentMod = $null
    $currentDependency = $null
    $ownerId = $null

    foreach ($rawLine in ($Toml -split "`r?`n")) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }
        if ($line -match '^\[\[mods\]\]$') {
            $section = "mod"
            $currentMod = [pscustomobject]@{ ModId = ""; Version = "" }
            $mods.Add($currentMod)
            continue
        }
        if ($line -match '^\[\[dependencies\.([^\]]+)\]\]$') {
            $section = "dependency"
            $ownerId = $Matches[1].Trim('"', "'")
            $currentDependency = [pscustomobject]@{ Id = ""; Range = "*"; Required = $true }
            if (-not $dependencyByOwner.ContainsKey($ownerId)) {
                $dependencyByOwner[$ownerId] = [System.Collections.Generic.List[pscustomobject]]::new()
            }
            $dependencyByOwner[$ownerId].Add($currentDependency)
            continue
        }
        if ($line -notmatch '^([A-Za-z0-9_.-]+)\s*=\s*(.+?)\s*$') {
            continue
        }

        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($section -eq "mod" -and $currentMod) {
            if ($key -eq "modId") { $currentMod.ModId = $value }
            if ($key -eq "version") { $currentMod.Version = $value }
        }
        elseif ($section -eq "dependency" -and $currentDependency) {
            if ($key -eq "modId") { $currentDependency.Id = $value }
            if ($key -eq "versionRange") { $currentDependency.Range = $value }
            if ($key -eq "mandatory") { $currentDependency.Required = $value -eq "true" }
            if ($key -eq "type") { $currentDependency.Required = $value -eq "required" }
        }
    }

    return @(
        foreach ($mod in $mods) {
            $dependencies = @($dependencyByOwner[$mod.ModId])
            $minecraft = $dependencies | Where-Object Id -eq "minecraft" | Select-Object -First 1
            [pscustomobject]@{
                JarPath        = $JarPath
                ModId          = $mod.ModId
                Version        = $mod.Version
                MinecraftRange = if ($minecraft) { $minecraft.Range } else { $null }
                Dependencies   = @($dependencies | Where-Object { $_.Id -ne "minecraft" })
            }
        }
    )
}

function Get-ModMetadata {
    param(
        [Parameter(Mandatory)][string]$JarPath,
        [Parameter(Mandatory)][ValidateSet("Fabric", "Quilt", "Forge", "NeoForge")][string]$Loader
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        if ($Loader -in "Fabric", "Quilt") {
            $fabricJson = Get-ZipEntryText -Archive $archive -EntryName @("fabric.mod.json")
            if ($fabricJson) {
                return @(ConvertFrom-FabricModJson -Json $fabricJson -JarPath $JarPath)
            }
            $quiltJson = Get-ZipEntryText -Archive $archive -EntryName @("quilt.mod.json")
            if ($quiltJson) {
                return @(ConvertFrom-QuiltModJson -Json $quiltJson -JarPath $JarPath)
            }
        }
        else {
            $toml = Get-ZipEntryText -Archive $archive -EntryName @("META-INF/neoforge.mods.toml", "META-INF/mods.toml")
            if ($toml) {
                return @(ConvertFrom-ModToml -Toml $toml -JarPath $JarPath)
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    return @()
}

function ConvertTo-NumericVersion {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?') {
        return $null
    }
    return [version]::new(
        [int]$Matches[1],
        [int]$(if ($Matches[2]) { $Matches[2] } else { 0 }),
        [int]$(if ($Matches[3]) { $Matches[3] } else { 0 }),
        [int]$(if ($Matches[4]) { $Matches[4] } else { 0 })
    )
}

function Test-VersionConstraint {
    param(
        [Parameter(Mandatory)][string]$Version,
        [AllowNull()][AllowEmptyString()][string]$Constraint
    )

    if ([string]::IsNullOrWhiteSpace($Constraint) -or $Constraint -eq "*") {
        return $true
    }
    foreach ($alternative in ($Constraint -split '\s*\|\|\s*')) {
        $candidate = $alternative.Trim()
        if ($candidate -match '^\[([^,\]]+)\]$') {
            if ((ConvertTo-NumericVersion $Version) -eq (ConvertTo-NumericVersion $Matches[1])) {
                return $true
            }
            continue
        }
        if ($candidate -match '^([\[\(])([^,]*),([^\]\)]*)([\]\)])$') {
            $actual = ConvertTo-NumericVersion $Version
            $lower = if ($Matches[2]) { ConvertTo-NumericVersion $Matches[2] } else { $null }
            $upper = if ($Matches[3]) { ConvertTo-NumericVersion $Matches[3] } else { $null }
            if ($actual -and
                (-not $lower -or $(if ($Matches[1] -eq "[") { $actual -ge $lower } else { $actual -gt $lower })) -and
                (-not $upper -or $(if ($Matches[4] -eq "]") { $actual -le $upper } else { $actual -lt $upper }))) {
                return $true
            }
            continue
        }

        $actual = ConvertTo-NumericVersion $Version
        $allMatch = $true
        foreach ($term in ($candidate -split '\s+')) {
            if (-not $term) { continue }
            if ($term -match '^[~^]?(\d+(?:\.\d+)*)(?:\.[xX*])?$') {
                $prefix = $Matches[1]
                if ($term -match '[xX*]$') {
                    $allMatch = $allMatch -and ($Version -like "$prefix.*")
                }
                elseif ($term.StartsWith("~")) {
                    $base = ConvertTo-NumericVersion $prefix
                    $allMatch = $allMatch -and $actual -and $actual -ge $base -and
                        $actual.Major -eq $base.Major -and $actual.Minor -eq $base.Minor
                }
                elseif ($term.StartsWith("^")) {
                    $base = ConvertTo-NumericVersion $prefix
                    $allMatch = $allMatch -and $actual -and $actual -ge $base -and $actual.Major -eq $base.Major
                }
                else {
                    $allMatch = $allMatch -and ($Version -eq $prefix)
                }
                continue
            }
            if ($term -match '^(>=|<=|>|<|=)(.+)$') {
                $expected = ConvertTo-NumericVersion $Matches[2]
                if (-not $actual -or -not $expected) {
                    $allMatch = $false
                    continue
                }
                $comparison = switch ($Matches[1]) {
                    ">=" { $actual -ge $expected }
                    "<=" { $actual -le $expected }
                    ">"  { $actual -gt $expected }
                    "<"  { $actual -lt $expected }
                    "="  { $actual -eq $expected }
                }
                $allMatch = $allMatch -and $comparison
                continue
            }
            $allMatch = $allMatch -and ($Version -eq $term)
        }
        if ($allMatch) {
            return $true
        }
    }
    return $false
}

function Get-ModWarningList {
    param(
        [Parameter(Mandatory)][object[]]$Metadata,
        [Parameter(Mandatory)][string]$MinecraftVersion,
        [Parameter(Mandatory)][ValidateSet("Fabric", "Quilt", "Forge", "NeoForge")][string]$Loader
    )

    $versionById = @{}
    foreach ($mod in $Metadata) {
        if ($mod.ModId) {
            $versionById[$mod.ModId.ToLowerInvariant()] = $mod.Version
        }
    }
    $loaderDependency = switch ($Loader) {
        "Fabric" { "fabricloader" }
        "Quilt" { "quilt_loader" }
        "Forge" { "forge" }
        "NeoForge" { "neoforge" }
    }
    $builtIn = @("minecraft", "java", $loaderDependency)
    $warnings = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($mod in $Metadata) {
        if ($mod.MinecraftRange -and -not (Test-VersionConstraint $MinecraftVersion $mod.MinecraftRange)) {
            $warnings.Add([pscustomobject]@{
                Jar   = [System.IO.Path]::GetFileName($mod.JarPath)
                ModId = $mod.ModId
                Issue = "Minecraft $MinecraftVersion does not match $($mod.MinecraftRange)"
            })
        }
        foreach ($dependency in @($mod.Dependencies | Where-Object Required)) {
            $id = $dependency.Id.ToLowerInvariant()
            if ($id -in $builtIn) {
                continue
            }
            if (-not $versionById.ContainsKey($id)) {
                $warnings.Add([pscustomobject]@{
                    Jar   = [System.IO.Path]::GetFileName($mod.JarPath)
                    ModId = $mod.ModId
                    Issue = "Missing required dependency '$($dependency.Id)'"
                })
            }
            elseif ($dependency.Range -and -not (Test-VersionConstraint $versionById[$id] $dependency.Range)) {
                $warnings.Add([pscustomobject]@{
                    Jar   = [System.IO.Path]::GetFileName($mod.JarPath)
                    ModId = $mod.ModId
                    Issue = "Dependency '$($dependency.Id)' version $($versionById[$id]) does not match $($dependency.Range)"
                })
            }
        }
    }
    return $warnings.ToArray()
}

function Get-ServerModMetadata {
    param(
        [Parameter(Mandatory)][string]$ModDirectory,
        [Parameter(Mandatory)][ValidateSet("Fabric", "Quilt", "Forge", "NeoForge")][string]$Loader
    )

    $metadata = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($jar in Get-ChildItem -LiteralPath $ModDirectory -File -Filter "*.jar") {
        try {
            foreach ($mod in @(Get-ModMetadata -JarPath $jar.FullName -Loader $Loader)) {
                $metadata.Add($mod)
            }
        }
        catch {
            Write-Warning "Could not inspect '$($jar.Name)': $($_.Exception.Message)"
        }
    }
    return $metadata.ToArray()
}

function Test-ModPresent {
    param(
        [Parameter(Mandatory)][object[]]$Metadata,
        [Parameter(Mandatory)][string]$ModDirectory,
        [Parameter(Mandatory)][string[]]$Identifier
    )

    foreach ($value in $Identifier) {
        if ($Metadata.ModId -contains $value) {
            return $true
        }
        if (Get-ChildItem -LiteralPath $ModDirectory -File -Filter "*.jar" |
            Where-Object BaseName -Match ([regex]::Escape($value))) {
            return $true
        }
    }
    return $false
}

function Set-ChunkyTaskFile {
    param(
        [Parameter(Mandatory)][string]$TargetDirectory,
        [Parameter(Mandatory)][string]$World,
        [Parameter(Mandatory)][int]$CenterX,
        [Parameter(Mandatory)][int]$CenterZ,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Radius,
        [Parameter(Mandatory)][ValidateSet("square", "circle", "triangle", "diamond", "pentagon", "hexagon", "star", "rectangle", "ellipse")][string]$Shape
    )

    $relativePath = $World.Replace(":", [string][System.IO.Path]::DirectorySeparatorChar) + ".properties"
    $taskPath = Join-Path (Join-Path $TargetDirectory "config/chunky/tasks") $relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskPath) -Force | Out-Null
    $content = @(
        "world=$World"
        "cancelled=false"
        "center-x=$CenterX"
        "center-z=$CenterZ"
        "radius=$Radius"
        "shape=$Shape"
        "pattern=concentric"
        "chunks=0"
        "time=0"
    ) -join "`n"
    Write-Utf8Lf -LiteralPath $taskPath -Content ($content + "`n")
}

function Set-ChunkyContinueOnRestart {
    param([Parameter(Mandatory)][string]$TargetDirectory)

    $path = Join-Path $TargetDirectory "config/chunky/config.json"
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $config = if (Test-Path -LiteralPath $path) {
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    else {
        [pscustomobject]@{}
    }
    $config.PSObject.Properties.Remove("update-interval")
    $config | Add-Member -NotePropertyName continueOnRestart -NotePropertyValue $true -Force
    $config | Add-Member -NotePropertyName updateInterval -NotePropertyValue 1 -Force
    $config | Add-Member -NotePropertyName silent -NotePropertyValue $false -Force
    Write-Utf8Lf -LiteralPath $path -Content (($config | ConvertTo-Json -Depth 20) + "`n")
}

function Read-ChunkyConfiguration {
    param([Parameter(Mandatory)][string]$TargetDirectory)

    Write-Host "Configure Chunky pre-generation:" -ForegroundColor Cyan
    $choices = @(Select-MenuItem -Prompt "Dimensions" -Item @("overworld", "nether", "end") -Multiple -DefaultIndex @(0, 1, 2))
    $worldByChoice = @{
        "overworld" = "minecraft:overworld"
        "nether"    = "minecraft:the_nether"
        "end"       = "minecraft:the_end"
    }
    $orderedChoices = @(@("overworld", "nether", "end") | Where-Object { $choices -contains $_ })
    $worlds = [System.Collections.Generic.List[string]]::new()
    foreach ($choice in $orderedChoices) {
        $world = $worldByChoice[$choice]
        $worlds.Add($world)
        $label = (Get-Culture).TextInfo.ToTitleCase($choice)
        Write-Host "-- $label --" -ForegroundColor DarkCyan
        $shape = Select-MenuItem -Prompt "$label - Chunky shape" -Item $script:ChunkyShapes
        $radius = Read-Integer -Prompt "$label - Chunky radius (blocks)" -Minimum 1 -Default 5000
        $centerX = Read-Integer -Prompt "$label - Center X" -Default 0
        $centerZ = Read-Integer -Prompt "$label - Center Z" -Default 0
        Set-ChunkyTaskFile -TargetDirectory $TargetDirectory -World $world -CenterX $centerX -CenterZ $centerZ -Radius $radius -Shape $shape
    }
    Set-ChunkyContinueOnRestart -TargetDirectory $TargetDirectory
    return $worlds.ToArray()
}

function Set-ConfigScalar {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [switch]$AddIfMissing
    )

    $lines = @(Get-Content -LiteralPath $LiteralPath)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^(\s*$([regex]::Escape($Key))\s*[:=]\s*)([^#\s]+)(.*)$") {
            $original = $Matches[2]
            $lines[$index] = "$($Matches[1])$Value$($Matches[3])"
            Write-Utf8Lf -LiteralPath $LiteralPath -Content (($lines -join "`n") + "`n")
            return [pscustomobject]@{ Path = $LiteralPath; Key = $Key; Original = $original }
        }
    }
    if ($AddIfMissing) {
        Write-Utf8Lf -LiteralPath $LiteralPath -Content (($lines + "$Key`: $Value" -join "`n") + "`n")
    }
    return $null
}

function Set-SquaremapThreadOverride {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][int]$Value
    )

    $lines = @(Get-Content -LiteralPath $LiteralPath)
    $stack = [System.Collections.Generic.List[pscustomobject]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -notmatch '^(\s*)([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$') {
            continue
        }
        $indent = $Matches[1].Length
        $key = $Matches[2]
        $valueText = $Matches[3]
        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $path = @($stack.Key) + $key
        if (($path -join "/") -match '(?:^|/)map/max-render-threads$' -and $valueText -match '^(-?\d+)(\s*(?:#.*)?)$') {
            $original = $Matches[1]
            $comment = $Matches[2]
            $lines[$index] = (" " * $indent) + "$key`: $Value$comment"
            Write-Utf8Lf -LiteralPath $LiteralPath -Content (($lines -join "`n") + "`n")
            return [pscustomobject]@{ Path = $LiteralPath; Key = "max-render-threads"; Original = $original }
        }
        if (-not $valueText) {
            $stack.Add([pscustomobject]@{ Indent = $indent; Key = $key })
        }
    }
    return $null
}

function Set-MapThreadOverride {
    param(
        [Parameter(Mandatory)][string]$TargetDirectory,
        [bool]$BlueMap,
        [bool]$Squaremap
    )

    $changes = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($BlueMap) {
        $path = Join-Path $TargetDirectory "config/bluemap/core.conf"
        if (Test-Path -LiteralPath $path) {
            $null = Set-ConfigScalar -LiteralPath $path -Key "accept-download" -Value "true" -AddIfMissing
            $change = Set-ConfigScalar -LiteralPath $path -Key "render-thread-count" -Value "0"
            if ($change) { $changes.Add($change) }
        }
        else {
            Write-Warning "BlueMap core.conf does not exist yet; its render thread count cannot be raised for this first run."
        }
    }
    if ($Squaremap) {
        $squaremapDirectory = Join-Path $TargetDirectory "config/squaremap"
        $files = @(
            Get-ChildItem -LiteralPath $squaremapDirectory -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object Extension -In ".yml", ".yaml"
        )
        foreach ($file in $files) {
            $change = Set-SquaremapThreadOverride -LiteralPath $file.FullName -Value ([Environment]::ProcessorCount)
            if ($change) { $changes.Add($change) }
        }
        if ($files.Count -eq 0) {
            Write-Warning "squaremap world configuration does not exist yet; its render thread count cannot be raised for this first run."
        }
    }
    return $changes.ToArray()
}

function Restore-MapThreadOverride {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Change)

    foreach ($item in $Change) {
        if (Test-Path -LiteralPath $item.Path) {
            $null = Set-ConfigScalar -LiteralPath $item.Path -Key $item.Key -Value $item.Original
        }
    }
}

function Start-HeadlessServerProcess {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo)

    return [System.Diagnostics.Process]::Start($StartInfo)
}

function Get-UtcNow {
    return [DateTime]::UtcNow
}

function Invoke-HeadlessPregen {
    param(
        [Parameter(Mandatory)][string]$TargetDirectory,
        [Parameter(Mandatory)][string[]]$JavaArguments,
        [string[]]$ExpectedCompletion = @(),
        [string[]]$ChunkyWorldSequence = @(),
        [switch]$StopWhenReady,
        [ValidateRange(10, 3600)][int]$IdleTimeoutSeconds = 120
    )

    if ($StopWhenReady) {
        Write-Host "Starting the server once to generate map plugin configuration." -ForegroundColor Cyan
        Write-Host "The server will stop after its ready message is detected." -ForegroundColor Yellow
    }
    else {
        Write-Host "Starting the server for best-effort pre-generation detection." -ForegroundColor Cyan
        Write-Host "Completion is detected from known log messages, with a $IdleTimeoutSeconds-second log-idle fallback." -ForegroundColor Yellow
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "java"
    $startInfo.WorkingDirectory = $TargetDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    foreach ($argument in $JavaArguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $logPath = Join-Path $TargetDirectory "logs/latest.log"
    $existingLog = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
    $lastLength = if ($existingLog) { $existingLog.Length } else { 0L }
    $logCreationTime = if ($existingLog) { $existingLog.CreationTimeUtc } else { [DateTime]::MinValue }
    $process = Start-HeadlessServerProcess -StartInfo $startInfo
    $started = Get-UtcNow
    $lastActivity = $started
    $lastHeartbeat = $started
    $completed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $serverReady = $false
    $chunkySequenceInitialized = $false
    $activeChunkyIndex = 0
    $pending = ""
    try {
        while (-not $process.HasExited) {
            Start-Sleep -Seconds 2
            $now = Get-UtcNow
            if (Test-Path -LiteralPath $logPath) {
                $file = Get-Item -LiteralPath $logPath
                if ($file.CreationTimeUtc -ne $logCreationTime) {
                    $logCreationTime = $file.CreationTimeUtc
                    $lastLength = 0
                    $pending = ""
                }
                elseif ($file.Length -lt $lastLength) {
                    $lastLength = 0
                    $pending = ""
                }
                if ($file.Length -gt $lastLength) {
                    $stream = [System.IO.File]::Open($logPath, "Open", "Read", "ReadWrite")
                    try {
                        $null = $stream.Seek($lastLength, [System.IO.SeekOrigin]::Begin)
                        $reader = [System.IO.StreamReader]::new($stream)
                        try { $newText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                        $lastLength = $stream.Position
                    }
                    finally {
                        $stream.Dispose()
                    }
                    # A read can stop mid-line, so keep any trailing partial line buffered and
                    # prefix it to the next read; otherwise a completion message split across
                    # two reads never matches. Always match against the full buffer immediately
                    # (rather than deferring until a newline arrives) so a message that never
                    # gets a following newline (e.g. the last line before the process goes
                    # quiet) is still detected instead of waiting for the idle fallback.
                    $newText = $pending + $newText
                    $lineBreak = $newText.LastIndexOf("`n")
                    $pending = if ($lineBreak -lt 0) { $newText } else { $newText.Substring($lineBreak + 1) }
                    $lastActivity = $now
                    if ($newText -match 'Done \([^)]+\)! For help, type "help"') {
                        $serverReady = $true
                    }
                    if (-not $StopWhenReady -and $serverReady -and -not $chunkySequenceInitialized) {
                        foreach ($world in @($ChunkyWorldSequence | Select-Object -Skip 1)) {
                            $process.StandardInput.WriteLine("chunky pause $world")
                        }
                        $chunkySequenceInitialized = $true
                    }
                    foreach ($match in [regex]::Matches($newText, 'Task finished for (.+?)\. Processed:')) {
                        $finishedWorld = $match.Groups[1].Value.Trim()
                        $null = $completed.Add("Chunky:$finishedWorld")
                        if ($activeChunkyIndex -lt $ChunkyWorldSequence.Count -and
                            [string]::Equals($finishedWorld, $ChunkyWorldSequence[$activeChunkyIndex], [System.StringComparison]::OrdinalIgnoreCase)) {
                            $activeChunkyIndex++
                            while ($activeChunkyIndex -lt $ChunkyWorldSequence.Count -and
                                $completed.Contains("Chunky:$($ChunkyWorldSequence[$activeChunkyIndex])")) {
                                $activeChunkyIndex++
                            }
                            if ($activeChunkyIndex -lt $ChunkyWorldSequence.Count) {
                                $process.StandardInput.WriteLine("chunky continue $($ChunkyWorldSequence[$activeChunkyIndex])")
                            }
                        }
                    }
                    if ($newText -match '(?i)BlueMap.*(?:render|map).*(?:finished|complete)' -and $completed.Add("BlueMap")) {
                        Write-Host "BlueMap render detected as finished." -ForegroundColor Green
                    }
                    if ($newText -match '(?i)squaremap.*(?:render|map).*(?:finished|complete)' -and $completed.Add("squaremap")) {
                        Write-Host "squaremap render detected as finished." -ForegroundColor Green
                    }
                }
            }
            if ($StopWhenReady -and $serverReady) {
                Write-Host "Detected the server ready message." -ForegroundColor Green
                break
            }
            if ($ExpectedCompletion.Count -gt 0 -and @($ExpectedCompletion | Where-Object { -not $completed.Contains($_) }).Count -eq 0) {
                Write-Host "Detected pre-generation completion in the server log." -ForegroundColor Green
                break
            }
            if (-not $StopWhenReady -and ($now - $lastHeartbeat).TotalSeconds -ge 5) {
                Write-Host ("Still waiting for pre-generation... ({0}s elapsed, last log activity {1}s ago)" -f
                    [int]($now - $started).TotalSeconds, [int]($now - $lastActivity).TotalSeconds) -ForegroundColor DarkGray
                $lastHeartbeat = $now
            }
            if (($now - $started).TotalSeconds -ge 30 -and
                ($now - $lastActivity).TotalSeconds -ge $IdleTimeoutSeconds) {
                Write-Warning "No server-log activity was detected for $IdleTimeoutSeconds seconds; stopping by the idle fallback."
                break
            }
        }
        if ($StopWhenReady -and -not $serverReady) {
            throw "The server exited before its ready message was detected."
        }
    }
    finally {
        if (-not $process.HasExited) {
            $process.StandardInput.WriteLine("stop")
            if (-not $process.WaitForExit(60000)) {
                $process.Kill($true)
            }
        }
        $process.Dispose()
    }
}

function Invoke-GenerateMcServer {
    param(
        [switch]$ReconfigureMode,
        [string]$RequestedServerPath
    )

    if (-not (Test-InteractiveHost)) {
        throw "Generate-Mc-Server.ps1 requires an interactive terminal."
    }

    if ($ReconfigureMode) {
        if ([string]::IsNullOrWhiteSpace($RequestedServerPath)) {
            throw "-ServerPath is required with -Reconfigure."
        }
        $target = [System.IO.Path]::GetFullPath($RequestedServerPath)
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "Server directory '$target' does not exist."
        }
        $loader = Get-InstalledLoader -TargetDirectory $target
        $ram = Read-Integer -Prompt "RAM in GB" -Minimum 1 -Default 8
        $result = New-StartScript -Loader $loader -TargetDirectory $target -RamGb $ram
        Write-Host "Regenerated '$($result.Path)'." -ForegroundColor Green
        return
    }

    $includeSnapshots = (Read-Host "Include Minecraft Snapshots [y/n] [Default N]").Trim() -match '^[Yy]$'
    if ($includeSnapshots) {
        Write-Warning "Loader availability is not guaranteed for Minecraft snapshots."
    }
    $includeLegacy = (Read-Host "Include legacy Alpha/Beta versions [y/n] [Default N]").Trim() -match '^[Yy]$'
    $minecraftVersions = @(Get-MinecraftVersionList -IncludeSnapshots:$includeSnapshots -IncludeLegacy:$includeLegacy)
    $availableLoaders = @()
    $versionMetadata = $null
    do {
        $minecraft = Select-MenuItem -Prompt "Minecraft version" -Item $minecraftVersions -Label {
            param($Value)
            if ($Value.type -eq "release") { $Value.id } else { "$($Value.id) [$($Value.type)]" }
        }
        $minecraftVersion = [string]$minecraft.id
        $versionMetadata = if ([string]::IsNullOrWhiteSpace([string]$minecraft.legacyServerUrl)) {
            Invoke-RestMethod -Uri $minecraft.url -ErrorAction Stop
        }
        else {
            $minecraft
        }
        if ([string]::IsNullOrWhiteSpace([string]$versionMetadata.legacyServerUrl) -and
            [string]::IsNullOrWhiteSpace([string]$versionMetadata.downloads.server.url) -and
            $script:OfficialReleaseServerFallbackUrls.ContainsKey($minecraftVersion)) {
            $versionMetadata | Add-Member -NotePropertyName legacyServerUrl -NotePropertyValue $script:OfficialReleaseServerFallbackUrls[$minecraftVersion] -Force
        }
        $availableLoaders = @(Get-AvailableLoaderList -MinecraftVersion $minecraftVersion -VersionMetadata $versionMetadata)
        if ($availableLoaders.Count -eq 0) {
            Write-Warning "Minecraft $minecraftVersion has no official server download and no compatible mod loader; choose a different version."
        }
    } while ($availableLoaders.Count -eq 0)
    $isLegacyVersion = -not [string]::IsNullOrWhiteSpace([string]$versionMetadata.legacyServerUrl)
    if ($availableLoaders.Count -eq 1) {
        Write-Warning "No mod loaders are available for Minecraft $minecraftVersion; Vanilla is the only option."
    }
    $loader = Select-MenuItem -Prompt "Mod loader" -Item $availableLoaders
    $loaderVersion = $null
    $installerVersion = $null
    if ($loader -ne "Vanilla") {
        $loaderVersions = @(Get-LoaderVersionList -Loader $loader -MinecraftVersion $minecraftVersion)
        if ($loaderVersions.Count -eq 0) {
            throw "No $loader versions were found for Minecraft $minecraftVersion."
        }
        $loaderVersion = [string](Select-MenuItem -Prompt "$loader version" -Item $loaderVersions)
        if ($loader -in "Fabric", "Quilt") {
            $installerVersions = @(Get-InstallerVersionList -Loader $loader)
            $installerVersion = [string](Select-MenuItem -Prompt "$loader installer version" -Item $installerVersions)
        }
    }

    $target = New-ServerDirectory -Name (Read-RequiredText -Prompt "Server folder name")
    if ($loader -eq "Vanilla") {
        Install-VanillaServer -VersionMetadata $versionMetadata -TargetDirectory $target
    }
    else {
        $plan = Get-InstallerPlan -Loader $loader -MinecraftVersion $minecraftVersion -LoaderVersion $loaderVersion -InstallerVersion $installerVersion -TargetDirectory $target
        Install-MinecraftServer -Plan $plan -TargetDirectory $target
    }

    $ram = Read-Integer -Prompt "RAM in GB" -Minimum 1 -Default 8
    $start = New-StartScript -Loader $loader -TargetDirectory $target -RamGb $ram

    $modDirectory = $null
    if ($loader -ne "Vanilla") {
        $modsSource = (Read-Host "Local mods folder (blank for none)").Trim().Trim('"')
        $modDirectory = Join-Path $target "mods"
        if ($modsSource) {
            $modDirectory = Copy-ModJar -SourceDirectory $modsSource -TargetDirectory $target
        }
        else {
            New-Item -ItemType Directory -Path $modDirectory -Force | Out-Null
        }
    }

    $propertiesPath = Join-Path $target "server.properties"
    $seed = (Read-Host "World seed (blank for random)").Trim()
    $motd = (Read-Host "MOTD").Trim()
    Set-ServerProperty -LiteralPath $propertiesPath -Name "level-seed" -Value $seed
    Set-ServerProperty -LiteralPath $propertiesPath -Name "motd" -Value $motd

    if (-not $isLegacyVersion) {
        $iconPath = (Read-Host "Server icon image (blank for none)").Trim().Trim('"')
        if ($iconPath) {
            Set-ServerIcon -ImagePath $iconPath -TargetDirectory $target
        }

        Set-EulaAccepted -TargetDirectory $target
        Write-Host "Wrote eula=true; this constitutes agreement to Mojang's EULA." -ForegroundColor Yellow
    }

    if ($loader -ne "Vanilla") {
        $metadata = @(Get-ServerModMetadata -ModDirectory $modDirectory -Loader $loader)
        $warnings = @(Get-ModWarningList -Metadata $metadata -MinecraftVersion $minecraftVersion -Loader $loader)
        if ($warnings.Count -gt 0) {
            Write-Warning "Likely mod compatibility issues (best-effort, non-blocking):"
            $warnings | Format-Table -AutoSize | Out-Host
        }

        $hasChunky = Test-ModPresent -Metadata $metadata -ModDirectory $modDirectory -Identifier @("chunky")
        $hasBlueMap = Test-ModPresent -Metadata $metadata -ModDirectory $modDirectory -Identifier @("bluemap")
        $hasSquaremap = Test-ModPresent -Metadata $metadata -ModDirectory $modDirectory -Identifier @("squaremap")
        $expected = [System.Collections.Generic.List[string]]::new()
        $chunkyWorlds = @()
        if ($hasChunky) {
            $chunkyWorlds = @(Read-ChunkyConfiguration -TargetDirectory $target)
            foreach ($world in $chunkyWorlds) {
                $expected.Add("Chunky:$world")
            }
        }

        if ($hasChunky -or $hasBlueMap -or $hasSquaremap) {
            if ($hasBlueMap -or $hasSquaremap) {
                Invoke-HeadlessPregen -TargetDirectory $target -JavaArguments $start.JavaArguments -StopWhenReady
            }
            $changes = @(Set-MapThreadOverride -TargetDirectory $target -BlueMap:$hasBlueMap -Squaremap:$hasSquaremap)
            try {
                if ($hasBlueMap -or $hasSquaremap) {
                    $mapRenderers = @(
                        if ($hasBlueMap) { "BlueMap" }
                        if ($hasSquaremap) { "squaremap" }
                    )
                    Write-Host "$($mapRenderers -join ' and ') will render automatically in the background during the pre-generation run below." -ForegroundColor Cyan
                    if (-not $hasChunky) {
                        Write-Warning "$($mapRenderers -join ' and ') do not provide a reliably detectable one-time completion signal; this run will stop after the 120-second log-idle fallback."
                    }
                }
                Invoke-HeadlessPregen -TargetDirectory $target -JavaArguments $start.JavaArguments `
                    -ExpectedCompletion $expected.ToArray() -ChunkyWorldSequence $chunkyWorlds
            }
            finally {
                Restore-MapThreadOverride -Change $changes
            }
        }
    }

    Write-Host "Server generated in '$target'. Start it on Linux with bash start.sh." -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-GenerateMcServer -ReconfigureMode:$Reconfigure -RequestedServerPath $ServerPath
}
