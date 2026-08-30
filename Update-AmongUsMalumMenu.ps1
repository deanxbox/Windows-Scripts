<#
.SYNOPSIS
Finds an Among Us installation and installs or updates MalumMenu.

.DESCRIPTION
Detects Steam and Epic Games installations of Among Us, allows a custom game
directory to be selected, and installs the correct MalumMenu release asset.
The script runs an interactive menu until Quit is selected.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost',
    '',
    Justification = 'This script intentionally provides an interactive console menu.'
)]
[CmdletBinding()]
param()

$script:ReleaseUri = 'https://api.github.com/repos/scp222thj/MalumMenu/releases/latest'

function ConvertTo-MalumMenuVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    try {
        $parsed = [version]($Version -replace '^v', '')
        return [version]::new(
            $parsed.Major,
            $parsed.Minor,
            [Math]::Max(0, $parsed.Build),
            [Math]::Max(0, $parsed.Revision)
        )
    }
    catch {
        throw "Invalid version '$Version': $($_.Exception.Message)"
    }
}

function Test-AmongUsDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    return (Test-Path -LiteralPath $Path -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Path 'Among Us.exe') -PathType Leaf)
}

function Get-SteamAmongUsDirectory {
    [CmdletBinding()]
    param()

    $steamPath = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ([string]::IsNullOrWhiteSpace($steamPath)) {
        $steamPath = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
    }
    if ([string]::IsNullOrWhiteSpace($steamPath)) {
        return
    }

    $libraryRoots = [System.Collections.Generic.List[string]]::new()
    $libraryRoots.Add($steamPath)
    $libraryFile = Join-Path $steamPath 'steamapps\libraryfolders.vdf'

    if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
        try {
            foreach ($line in Get-Content -LiteralPath $libraryFile -ErrorAction Stop) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $libraryPath = $matches[1].Replace('\\', '\')
                    if ($libraryRoots -notcontains $libraryPath) {
                        $libraryRoots.Add($libraryPath)
                    }
                }
            }
        }
        catch {
            Write-Warning "Could not read Steam library file '$libraryFile': $($_.Exception.Message)"
        }
    }

    foreach ($libraryRoot in $libraryRoots) {
        $gamePath = Join-Path $libraryRoot 'steamapps\common\Among Us'
        if (Test-Path -LiteralPath $gamePath -PathType Container) {
            [pscustomobject]@{
                Path     = (Resolve-Path -LiteralPath $gamePath).Path
                Platform = 'Steam'
            }
        }
    }
}

function Get-EpicAmongUsDirectory {
    [CmdletBinding()]
    param()

    $manifestDirectory = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) {
        return
    }

    try {
        $manifestFiles = @(Get-ChildItem -LiteralPath $manifestDirectory -Filter '*.item' -File -ErrorAction Stop)
    }
    catch {
        Write-Warning "Could not enumerate Epic manifests in '$manifestDirectory': $($_.Exception.Message)"
        return
    }

    foreach ($manifestFile in $manifestFiles) {
        try {
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $names = @([string]$manifest.DisplayName, [string]$manifest.AppName)
            if ($names -match 'Among\s+Us' -and
                -not [string]::IsNullOrWhiteSpace([string]$manifest.InstallLocation) -and
                (Test-Path -LiteralPath $manifest.InstallLocation -PathType Container)) {
                [pscustomobject]@{
                    Path     = (Resolve-Path -LiteralPath $manifest.InstallLocation).Path
                    Platform = 'Epic'
                }
            }
        }
        catch {
            Write-Warning "Could not read Epic manifest '$($manifestFile.FullName)': $($_.Exception.Message)"
        }
    }
}

function Add-GameDirectoryCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Candidate,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('Steam', 'Epic', 'Unknown')]
        [string]$Platform
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not ($Candidate.Path -contains $resolvedPath)) {
        $Candidate.Add([pscustomobject]@{
                Path     = $resolvedPath
                Platform = $Platform
            })
    }
}

function Read-CustomGameDirectory {
    [CmdletBinding()]
    param(
        [switch]$AllowMultiple
    )

    $directories = [System.Collections.Generic.List[object]]::new()
    do {
        do {
            $path = (Read-Host 'Enter the Among Us game directory (blank to cancel)').Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($path)) {
                return $directories
            }
            if (-not (Test-AmongUsDirectory -Path $path)) {
                Write-Warning "That directory does not exist or does not contain 'Among Us.exe'."
            }
        } until (Test-AmongUsDirectory -Path $path)

        $directories.Add([pscustomobject]@{
                Path     = (Resolve-Path -LiteralPath $path).Path
                Platform = 'Unknown'
            })

        if (-not $AllowMultiple) {
            break
        }
        $addAnother = Read-Host 'Add another directory? [Y/N]'
    } while ($addAnother -match '^[Yy]$')

    return $directories
}

function Show-GameDirectoryList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Candidate,

        [AllowNull()]
        [object]$Active
    )

    Write-Host ''
    Write-Host 'Among Us directories:' -ForegroundColor Cyan
    if ($Candidate.Count -eq 0) {
        Write-Host '  (none)' -ForegroundColor Yellow
        return
    }

    for ($index = 0; $index -lt $Candidate.Count; $index++) {
        $directory = $Candidate[$index]
        $activeMarker = if ($null -ne $Active -and $Active.Path -eq $directory.Path) { ' *active*' } else { '' }
        Write-Host "  [$($index + 1)]" -ForegroundColor Magenta -NoNewline
        Write-Host " $($directory.Path) [$($directory.Platform)]" -NoNewline
        Write-Host $activeMarker -ForegroundColor Green
    }
}

function Select-ActiveGameDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Candidate
    )

    Show-GameDirectoryList -Candidate $Candidate
    Write-Host '  [C]' -ForegroundColor Magenta -NoNewline
    Write-Host ' Enter a custom directory' -ForegroundColor Cyan
    $choice = (Read-Host 'Select a directory').Trim()

    if ($choice -match '^[Cc]$') {
        $customDirectory = @(Read-CustomGameDirectory) | Select-Object -First 1
        if ($null -eq $customDirectory) {
            return
        }
        Add-GameDirectoryCandidate -Candidate $Candidate -Path $customDirectory.Path -Platform Unknown
        return $Candidate | Where-Object Path -EQ $customDirectory.Path | Select-Object -First 1
    }

    $number = 0
    if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $Candidate.Count) {
        return $Candidate[$number - 1]
    }

    Write-Warning 'Invalid directory selection.'
}

function Get-MalumMenuRelease {
    [CmdletBinding()]
    param()

    try {
        $release = Invoke-RestMethod -Uri $script:ReleaseUri -Headers @{
            Accept       = 'application/vnd.github+json'
            'User-Agent' = 'Update-AmongUsMalumMenu'
        } -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
            throw 'The release response did not contain tag_name.'
        }

        $steamAsset = @($release.assets | Where-Object name -Match '-Steam-Itch\.zip$')
        $microsoftAsset = @($release.assets | Where-Object name -Match '-MicrosoftStore-EpicGames-XboxApp\.zip$')
        if ($steamAsset.Count -ne 1 -or $microsoftAsset.Count -ne 1) {
            throw 'The release did not contain exactly one zip asset for each supported platform group.'
        }

        $versionText = ([string]$release.tag_name) -replace '^v', ''
        return [pscustomobject]@{
            Version      = ConvertTo-MalumMenuVersion -Version $versionText
            VersionText  = $versionText
            SteamUrl     = [string]$steamAsset[0].browser_download_url
            MicrosoftUrl = [string]$microsoftAsset[0].browser_download_url
        }
    }
    catch {
        throw "Could not retrieve the latest MalumMenu release: $($_.Exception.Message)"
    }
}

function Get-InstalledMalumMenuVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$GamePath
    )

    $dllPath = Join-Path $GamePath 'BepInEx\plugins\MalumMenu.dll'
    if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
        return
    }

    try {
        $versionInfo = (Get-Item -LiteralPath $dllPath -ErrorAction Stop).VersionInfo
        $versionText = [string]$versionInfo.FileVersion
        if ([string]::IsNullOrWhiteSpace($versionText)) {
            $versionText = [string]$versionInfo.ProductVersion
        }
        if ([string]::IsNullOrWhiteSpace($versionText)) {
            throw 'The DLL has no file or product version.'
        }

        return [pscustomobject]@{
            Version     = ConvertTo-MalumMenuVersion -Version $versionText
            VersionText = $versionText
        }
    }
    catch {
        throw "Could not read the installed MalumMenu version from '$dllPath': $($_.Exception.Message)"
    }
}

function Resolve-MalumMenuPlatform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$GameDirectory
    )

    if ($GameDirectory.Platform -eq 'Steam' -or
        $GameDirectory.Path -match '[\\/]steamapps[\\/]common[\\/]Among Us[\\/]?$') {
        return 'Steam'
    }
    if ($GameDirectory.Platform -eq 'Epic') {
        return 'Microsoft'
    }

    $choice = (Read-Host 'Is this a Steam/Itch.io install or Microsoft Store/Epic Games/Xbox App install? [S/M]').Trim()
    if ($choice -match '^[Ss]$') {
        $GameDirectory.Platform = 'Steam'
        return 'Steam'
    }
    if ($choice -match '^[Mm]$') {
        $GameDirectory.Platform = 'Epic'
        return 'Microsoft'
    }

    return
}

function Invoke-MalumMenuInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$GameDirectory
    )

    try {
        if (-not (Test-AmongUsDirectory -Path $GameDirectory.Path)) {
            throw "The selected directory does not contain 'Among Us.exe': $($GameDirectory.Path)"
        }

        $release = Get-MalumMenuRelease
        $platform = Resolve-MalumMenuPlatform -GameDirectory $GameDirectory
        if ([string]::IsNullOrWhiteSpace($platform)) {
            Write-Host 'Install cancelled.' -ForegroundColor Yellow
            return
        }

        $installed = Get-InstalledMalumMenuVersion -GamePath $GameDirectory.Path
        if ($null -eq $installed) {
            $prompt = 'MalumMenu not installed. Install? [Y/N]'
        }
        elseif ($installed.Version -ge $release.Version) {
            $prompt = "MalumMenu up to date ($($installed.VersionText)). Install anyway? [Y/N]"
        }
        else {
            $prompt = "MalumMenu installed ($($installed.VersionText)), but a newer version is available ($($release.VersionText)). Update? [Y/N]"
        }

        if ((Read-Host $prompt).Trim() -notmatch '^[Yy]$') {
            Write-Host 'Install cancelled.' -ForegroundColor Yellow
            return
        }

        $downloadUrl = if ($platform -eq 'Steam') { $release.SteamUrl } else { $release.MicrosoftUrl }
        $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('MalumMenu-' + [guid]::NewGuid().ToString('N'))
        $zipPath = Join-Path $tempDirectory 'MalumMenu.zip'
        $extractPath = Join-Path $tempDirectory 'Extracted'

        try {
            New-Item -ItemType Directory -Path $extractPath -Force -ErrorAction Stop | Out-Null
            Invoke-WebRequest -Uri $downloadUrl -Headers @{ 'User-Agent' = 'Update-AmongUsMalumMenu' } `
                -UseBasicParsing -OutFile $zipPath -ErrorAction Stop
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop

            if (-not (Test-Path -LiteralPath (Join-Path $extractPath 'BepInEx\plugins\MalumMenu.dll') -PathType Leaf)) {
                throw 'The downloaded archive did not contain BepInEx\plugins\MalumMenu.dll.'
            }

            foreach ($item in Get-ChildItem -LiteralPath $extractPath -Force -ErrorAction Stop) {
                Copy-Item -LiteralPath $item.FullName -Destination $GameDirectory.Path -Recurse -Force -ErrorAction Stop
            }

            Write-Host "MalumMenu $($release.VersionText) installed successfully in '$($GameDirectory.Path)'." `
                -ForegroundColor Green
        }
        finally {
            $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
            $tempFullPath = [System.IO.Path]::GetFullPath($tempDirectory)
            if ((Test-Path -LiteralPath $tempFullPath) -and
                $tempFullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                try {
                    Remove-Item -LiteralPath $tempFullPath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "Could not remove temporary directory '$tempFullPath': $($_.Exception.Message)"
                }
            }
        }
    }
    catch {
        Write-Error "MalumMenu install failed: $($_.Exception.Message)"
    }
}

function Invoke-MalumMenuUpdater {
    [CmdletBinding()]
    param()

    $candidate = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in @(Get-SteamAmongUsDirectory) + @(Get-EpicAmongUsDirectory)) {
        Add-GameDirectoryCandidate -Candidate $candidate -Path $directory.Path -Platform $directory.Platform
    }

    if ($candidate.Count -eq 0) {
        Write-Host 'Could not automatically locate Among Us via Steam or Epic Games.' -ForegroundColor Yellow
        foreach ($directory in @(Read-CustomGameDirectory -AllowMultiple)) {
            Add-GameDirectoryCandidate -Candidate $candidate -Path $directory.Path -Platform Unknown
        }
    }

    $activeDirectory = $null
    while ($true) {
        Show-GameDirectoryList -Candidate $candidate -Active $activeDirectory
        Write-Host ''
        Write-Host '[1]' -ForegroundColor Magenta -NoNewline
        Write-Host ' Select Game Directory' -ForegroundColor Cyan
        Write-Host '[2]' -ForegroundColor Magenta -NoNewline
        Write-Host ' Install' -ForegroundColor Cyan
        Write-Host '[A]' -ForegroundColor Magenta -NoNewline
        Write-Host ' Add Custom Directory' -ForegroundColor Cyan
        Write-Host '[Q]' -ForegroundColor Magenta -NoNewline
        Write-Host ' Quit' -ForegroundColor Cyan

        switch ((Read-Host 'Choice').Trim().ToUpperInvariant()) {
            '1' {
                $selection = Select-ActiveGameDirectory -Candidate $candidate
                if ($null -ne $selection) {
                    $activeDirectory = $selection
                }
            }
            '2' {
                if ($null -eq $activeDirectory) {
                    if ($candidate.Count -eq 1) {
                        $activeDirectory = $candidate[0]
                    }
                    elseif ($candidate.Count -gt 1) {
                        Write-Host 'Select a game directory first.' -ForegroundColor Yellow
                        $activeDirectory = Select-ActiveGameDirectory -Candidate $candidate
                    }
                    else {
                        Write-Host 'Add a valid game directory first.' -ForegroundColor Yellow
                    }
                }
                if ($null -ne $activeDirectory) {
                    Invoke-MalumMenuInstall -GameDirectory $activeDirectory
                }
            }
            'A' {
                $customDirectory = @(Read-CustomGameDirectory) | Select-Object -First 1
                if ($null -ne $customDirectory) {
                    Add-GameDirectoryCandidate -Candidate $candidate -Path $customDirectory.Path -Platform Unknown
                }
            }
            'Q' {
                return
            }
            default {
                Write-Warning 'Invalid menu choice.'
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MalumMenuUpdater
}
