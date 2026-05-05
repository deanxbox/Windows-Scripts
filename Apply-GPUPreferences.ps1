# Apply-GPUPreferences.ps1
# Manually pins specified apps to the RTX 4060 Ti via Windows GPU Preferences registry.
# Run any time to reapply - no scheduled task, no background process.

$regPath = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
$gpuPref = "SpecificAdapter=10DE&2805&51741462;GpuPreference=1073741824;"

if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$total = 0

function Set-GPUPref($path) {
    if (Test-Path $path) {
        Set-ItemProperty -Path $regPath -Name $path -Value $gpuPref -Type String
        Write-Host "  OK  $([System.IO.Path]::GetFileName($path))"
        Write-Host "      $([System.IO.Path]::GetDirectoryName($path))"
        $script:total++
    } else {
        Write-Host "  --  (not found) $path" -ForegroundColor DarkGray
    }
}

# ── Brave Browser ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "-- Brave Browser --"
Set-GPUPref "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"

# ── Discord ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "-- Discord --"

$discordBase = "$env:LOCALAPPDATA\Discord"
Set-GPUPref "$discordBase\Update.exe"

Get-ChildItem -Path $discordBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue | ForEach-Object {
    $appDir = $_.FullName
    Set-GPUPref "$appDir\Discord.exe"
    Get-ChildItem -Path "$appDir\modules" -Directory -Filter "discord_utils-*" -ErrorAction SilentlyContinue | ForEach-Object {
        Set-GPUPref "$($_.FullName)\discord_utils\DiscordSystemHelper.exe"
    }
}

# ── Medal ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "-- Medal --"

$medalBase = "$env:LOCALAPPDATA\Medal"
Set-GPUPref "$medalBase\Medal.exe"

Get-ChildItem -Path $medalBase -Directory -Filter "app-*" -ErrorAction SilentlyContinue | ForEach-Object {
    Set-GPUPref "$($_.FullName)\Medal.exe"
}

# ── Spotify ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "-- Spotify --"

$spotifyBase = "$env:APPDATA\Spotify"
Set-GPUPref "$spotifyBase\Spotify.exe"
Set-GPUPref "$spotifyBase\SpotifyLauncher.exe"

# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Done - $total executable(s) pinned to RTX 4060 Ti."
Write-Host ""
Read-Host "Press Enter to close"