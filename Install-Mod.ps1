# Install-Mod.ps1
# Copies a built Minecraft mod jar into a Prism Launcher instance.

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true)]
[OutputType([pscustomobject])]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ProjectPath = (Get-Location).Path,

    [ValidateNotNullOrEmpty()]
    [string]$PrismPath,

    [ValidateNotNullOrEmpty()]
    [string]$Instance,

    [ValidateNotNullOrEmpty()]
    [string]$Artifact,

    [ValidateNotNullOrEmpty()]
    [string]$StatePath = [System.IO.Path]::Combine(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData),
        "Install-Mod",
        "state.json"
    ),

    [switch]$NoPersist
)

function Test-InteractiveHost {
    return [Environment]::UserInteractive -and
        $null -ne $Host.UI -and
        -not [Console]::IsInputRedirected -and
        -not ([Environment]::GetCommandLineArgs() -contains "-NonInteractive")
}

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BasePath = (Get-Location).Path
    )

    if ([System.IO.Path]::IsPathFullyQualified($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath($Path, $BasePath)
}

function Select-MenuItem {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Item,
        [scriptblock]$Label = { param($Value) [string]$Value },
        [ValidateRange(0, [int]::MaxValue)][int]$DefaultIndex = 0
    )

    if (-not (Test-InteractiveHost)) {
        throw "$Prompt requires an interactive terminal; provide the corresponding parameter."
    }

    $windowSize = [Math]::Min(5, $Item.Count)
    $cursorIndex = [Math]::Min($DefaultIndex, $Item.Count - 1)
    $originalCursorVisible = $null

    try {
        $originalCursorVisible = [Console]::CursorVisible
        [Console]::CursorVisible = $false
        Write-Host "$Prompt (↑/↓ navigate, Space to select)"
        for ($row = 0; $row -lt $windowSize; $row++) {
            Write-Host ""
        }
        $menuTop = [Math]::Max(0, [Console]::CursorTop - $windowSize)

        while ($true) {
            $windowStart = [Math]::Min(
                [Math]::Max(0, $cursorIndex - [Math]::Floor($windowSize / 2)),
                [Math]::Max(0, $Item.Count - $windowSize)
            )
            $width = [Math]::Max(1, [Console]::BufferWidth - 1)

            for ($row = 0; $row -lt $windowSize; $row++) {
                $itemIndex = $windowStart + $row
                $line = if ($itemIndex -lt $Item.Count) {
                    $marker = if ($itemIndex -eq $cursorIndex) { ">" } else { " " }
                    "$marker  $(& $Label $Item[$itemIndex])"
                }
                else {
                    ""
                }
                if ($line.Length -gt $width) {
                    $line = $line.Substring(0, $width)
                }
                [Console]::SetCursorPosition(0, $menuTop + $row)
                [Console]::Write($line.PadRight($width))
            }
            [Console]::SetCursorPosition(0, $menuTop + $windowSize)

            switch ([Console]::ReadKey($true).Key) {
                "UpArrow" { $cursorIndex = [Math]::Max(0, $cursorIndex - 1) }
                "DownArrow" { $cursorIndex = [Math]::Min($Item.Count - 1, $cursorIndex + 1) }
                { $_ -in [ConsoleKey]::Spacebar, [ConsoleKey]::Enter } {
                    Write-Host "Selected: $(& $Label $Item[$cursorIndex])" -ForegroundColor Green
                    return $Item[$cursorIndex]
                }
            }
        }
    }
    catch {
        throw "Interactive selection failed; provide the corresponding parameter. $($_.Exception.Message)"
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

function Test-MinecraftModProject {
    param([Parameter(Mandatory)][string]$Path)

    $gradleMarker = @(
        "settings.gradle",
        "settings.gradle.kts",
        "build.gradle",
        "build.gradle.kts",
        "gradlew",
        "gradlew.bat"
    ) | Where-Object { Test-Path -LiteralPath (Join-Path $Path $_) } | Select-Object -First 1

    if (-not $gradleMarker) {
        return $false
    }

    $descriptor = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction Stop |
        Where-Object {
            $_.FullName -notmatch '[\\/](?:build|\.gradle|\.git)[\\/]' -and
            (
                $_.Name -in "fabric.mod.json", "quilt.mod.json", "neoforge.mods.toml", "mcmod.info" -or
                ($_.Name -eq "mods.toml" -and $_.DirectoryName -match '[\\/]META-INF(?:[\\/]|$)')
            )
        } |
        Select-Object -First 1

    return $null -ne $descriptor
}

function Get-ModArtifact {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [string]$RequestedArtifact,
        [Parameter(Mandatory)][bool]$CanPrompt
    )

    $libraryDirectories = Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Filter "libs" -ErrorAction Stop |
        Where-Object { $_.Parent.Name -eq "build" }
    $allArtifacts = @(
        $libraryDirectories |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Recurse -Filter "*.jar" -ErrorAction Stop } |
            Sort-Object FullName -Unique
    )

    if ($allArtifacts.Count -eq 0) {
        throw "No jar artifacts were found under '$RootPath\**\build\libs'. Build the mod first."
    }

    if ($RequestedArtifact) {
        $requestedPath = Get-NormalizedPath -Path $RequestedArtifact -BasePath $RootPath
        $artifactMatches = @($allArtifacts | Where-Object {
            $_.FullName.Equals($requestedPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            (-not [System.IO.Path]::IsPathFullyQualified($RequestedArtifact) -and
                -not $RequestedArtifact.Contains([System.IO.Path]::DirectorySeparatorChar) -and
                -not $RequestedArtifact.Contains([System.IO.Path]::AltDirectorySeparatorChar) -and
                $_.Name.Equals($RequestedArtifact, [System.StringComparison]::OrdinalIgnoreCase))
        })
        if ($artifactMatches.Count -eq 0) {
            throw "Artifact '$RequestedArtifact' is not a jar under a build/libs directory."
        }
        if ($artifactMatches.Count -gt 1) {
            throw "Artifact name '$RequestedArtifact' is ambiguous; provide its project-relative path."
        }
        return $artifactMatches[0]
    }

    $primaryArtifacts = @($allArtifacts | Where-Object {
        $_.BaseName -notmatch '(?i)(?:^|[-_.])(?:sources?|javadoc|dev(?:-shadow)?|deobf|shadow-dev)(?:[-_.]|$)'
    })
    $candidates = if ($primaryArtifacts.Count -gt 0) { $primaryArtifacts } else { $allArtifacts }
    $candidates = @($candidates | Sort-Object LastWriteTime -Descending)

    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }
    if (-not $CanPrompt) {
        throw "Multiple mod jars were found. Specify -Artifact with a project-relative path or filename."
    }

    return Select-MenuItem -Prompt "Select mod artifact" -Item $candidates -Label {
        param($File)
        $directory = [System.IO.Path]::GetRelativePath($RootPath, $File.DirectoryName)
        "{0} | {1} | {2:yyyy-MM-dd HH:mm:ss}" -f $directory, $File.Name, $File.LastWriteTime
    }
}

function Get-SavedState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Ignoring invalid installer state at '$Path': $($_.Exception.Message)"
        return $null
    }
}

function Get-PrismInstanceDirectory {
    param([Parameter(Mandatory)][string]$RootPath)

    $configurationPath = Join-Path $RootPath "prismlauncher.cfg"
    if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
        $match = [regex]::Match(
            (Get-Content -LiteralPath $configurationPath -Raw -ErrorAction Stop),
            '(?im)^InstanceDir=(?<Path>.+)$'
        )
        if ($match.Success) {
            $configuredPath = [Environment]::ExpandEnvironmentVariables(
                $match.Groups["Path"].Value.Trim().Trim('"')
            )
            return Get-NormalizedPath -Path $configuredPath -BasePath $RootPath
        }
    }

    return Join-Path $RootPath "instances"
}

function Test-PrismRoot {
    param([Parameter(Mandatory)][string]$Path)

    return (Test-Path -LiteralPath $Path -PathType Container) -and
        (Test-Path -LiteralPath (Get-PrismInstanceDirectory -RootPath $Path) -PathType Container)
}

function Get-PrismRoot {
    param(
        [string]$RequestedPath,
        [object]$SavedState,
        [Parameter(Mandatory)][bool]$CanPrompt
    )

    if ($RequestedPath) {
        $root = Get-NormalizedPath -Path $RequestedPath
        if (-not (Test-PrismRoot -Path $root)) {
            throw "Prism path '$root' does not contain a valid instances directory."
        }
        return $root
    }

    if ($SavedState.PrismPath) {
        $savedRoot = Get-NormalizedPath -Path ([string]$SavedState.PrismPath)
        if (Test-PrismRoot -Path $savedRoot) {
            return $savedRoot
        }
    }

    $knownPaths = @(
        $(if ($env:APPDATA) { Join-Path $env:APPDATA "PrismLauncher" }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "PrismLauncher" }),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "scoop\persist\prismlauncher" }),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "scoop\apps\prismlauncher\current" }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "PrismLauncher" }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "PrismLauncher" })
    ) | Where-Object { $_ }
    $candidates = @(
        $knownPaths |
            ForEach-Object { Get-NormalizedPath -Path $_ } |
            Select-Object -Unique |
            Where-Object { Test-PrismRoot -Path $_ }
    )

    if ($candidates.Count -eq 0) {
        throw "Prism Launcher data was not found. Specify -PrismPath with the directory containing 'instances'."
    }
    if ($candidates.Count -eq 1) {
        return $candidates[0]
    }
    if (-not $CanPrompt) {
        throw "Multiple Prism Launcher locations were found. Specify -PrismPath."
    }

    return Select-MenuItem -Prompt "Select Prism Launcher location" -Item $candidates
}

function Get-PrismInstance {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [string]$RequestedInstance,
        [object]$SavedState,
        [Parameter(Mandatory)][bool]$CanPrompt
    )

    $instanceDirectory = Get-PrismInstanceDirectory -RootPath $RootPath
    $instances = @(
        Get-ChildItem -LiteralPath $instanceDirectory -Directory -ErrorAction Stop |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName "instance.cfg") -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $_.FullName "minecraft") -PathType Container)
            } |
            ForEach-Object {
                $name = $_.Name
                $configurationPath = Join-Path $_.FullName "instance.cfg"
                if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
                    $match = [regex]::Match(
                        (Get-Content -LiteralPath $configurationPath -Raw -ErrorAction Stop),
                        '(?im)^name=(?<Name>.*)$'
                    )
                    if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups["Name"].Value)) {
                        $name = $match.Groups["Name"].Value.Trim()
                    }
                }
                [pscustomobject]@{
                    Name     = $name
                    Id       = $_.Name
                    FullName = $_.FullName
                }
            } |
            Sort-Object Name, Id
    )

    if ($instances.Count -eq 0) {
        throw "No Prism Launcher instances were found under '$instanceDirectory'."
    }

    if ($RequestedInstance) {
        $requestedPath = Get-NormalizedPath -Path $RequestedInstance -BasePath $instanceDirectory
        $instanceMatches = @($instances | Where-Object {
            $_.FullName.Equals($requestedPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Id.Equals($RequestedInstance, [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals($RequestedInstance, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($instanceMatches.Count -eq 0) {
            throw "Prism instance '$RequestedInstance' was not found."
        }
        if ($instanceMatches.Count -gt 1) {
            throw "Prism instance '$RequestedInstance' is ambiguous; provide its folder name or full path."
        }
        return $instanceMatches[0]
    }

    $savedInstance = $null
    if ($SavedState.InstancePath) {
        $savedInstancePath = Get-NormalizedPath -Path ([string]$SavedState.InstancePath)
        $savedInstance = $instances | Where-Object {
            $_.FullName.Equals($savedInstancePath, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
    }

    if (-not $CanPrompt) {
        if ($savedInstance) {
            return $savedInstance
        }
        if ($instances.Count -eq 1) {
            return $instances[0]
        }
        throw "Multiple Prism Launcher instances were found. Specify -Instance by name, folder, or full path."
    }

    if ($savedInstance) {
        $instances = @($savedInstance) + @($instances | Where-Object {
            $_.FullName -ne $savedInstance.FullName
        })
    }

    return Select-MenuItem -Prompt "Select Prism Launcher instance" -Item $instances -Label {
        param($Value)
        if ($Value.Name -eq $Value.Id) { $Value.Name } else { "$($Value.Name) [$($Value.Id)]" }
    } -DefaultIndex 0
}

function Save-InstallerState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$InstancePath
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory (".state-{0}.tmp" -f [guid]::NewGuid().ToString("N"))
    try {
        $json = [pscustomobject]@{
            PrismPath    = $RootPath
            InstancePath = $InstancePath
        } | ConvertTo-Json
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

$projectRoot = Get-NormalizedPath -Path $ProjectPath
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "Project path does not exist: $projectRoot"
}
if (-not (Test-MinecraftModProject -Path $projectRoot)) {
    throw "'$projectRoot' does not look like a Minecraft mod Gradle project (Gradle files and a mod descriptor are required)."
}

$canPrompt = Test-InteractiveHost
$selectedArtifact = Get-ModArtifact -RootPath $projectRoot -RequestedArtifact $Artifact -CanPrompt $canPrompt
$normalizedStatePath = Get-NormalizedPath -Path $StatePath
$savedState = Get-SavedState -Path $normalizedStatePath
$prismRoot = Get-PrismRoot -RequestedPath $PrismPath -SavedState $savedState -CanPrompt $canPrompt
$selectedInstance = Get-PrismInstance -RootPath $prismRoot -RequestedInstance $Instance `
    -SavedState $savedState -CanPrompt $canPrompt

$minecraftDirectory = Join-Path $selectedInstance.FullName "minecraft"
$modsDirectory = Join-Path $minecraftDirectory "mods"
$destinationPath = Join-Path $modsDirectory $selectedArtifact.Name
$installed = $false

if ($PSCmdlet.ShouldProcess($destinationPath, "Install '$($selectedArtifact.Name)' into '$($selectedInstance.Name)'")) {
    [System.IO.Directory]::CreateDirectory($modsDirectory) | Out-Null
    Copy-Item -LiteralPath $selectedArtifact.FullName -Destination $destinationPath -Force -ErrorAction Stop
    $installed = $true
}

$stateMatches = $savedState -and
    ([string]$savedState.PrismPath).Equals($prismRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
    ([string]$savedState.InstancePath).Equals(
        $selectedInstance.FullName,
        [System.StringComparison]::OrdinalIgnoreCase
    )
$defaultPersisted = [bool]$stateMatches
if ($installed -and -not $NoPersist -and -not $stateMatches -and
    $PSCmdlet.ShouldProcess($normalizedStatePath, "Save default Prism Launcher instance")) {
    Save-InstallerState -Path $normalizedStatePath -RootPath $prismRoot `
        -InstancePath $selectedInstance.FullName
    $defaultPersisted = $true
}

if ($installed) {
    Write-Host "Installed '$($selectedArtifact.Name)' to '$modsDirectory'." -ForegroundColor Green
}

[pscustomobject]@{
    ProjectPath      = $projectRoot
    PrismPath        = $prismRoot
    InstanceName     = $selectedInstance.Name
    InstancePath     = $selectedInstance.FullName
    ArtifactPath     = $selectedArtifact.FullName
    DestinationPath  = $destinationPath
    Installed        = $installed
    DefaultPersisted = $defaultPersisted
}
