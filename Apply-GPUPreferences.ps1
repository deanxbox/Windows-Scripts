# Apply-GPUPreferences.ps1
# Pins apps to a selected GPU via Windows GPU Preferences registry.
# Run any time to reapply. Edit gpu-prefs-apps.json to add or remove programs.
#
# Usage:
#   .\Apply-GPUPreferences.ps1               - detect GPUs, pick one, apply all apps
#   .\Apply-GPUPreferences.ps1 -AddProgram   - jump straight to add-program wizard

param(
    [switch]$AddProgram
)

$configPath   = Join-Path $PSScriptRoot "gpu-prefs-apps.json"
$regPath      = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
$script:total = 0

# ── Config ─────────────────────────────────────────────────────────────────────

function Load-Config {
    if (Test-Path $configPath) {
        return Get-Content $configPath -Raw | ConvertFrom-Json
    }
    return [PSCustomObject]@{ apps = @() }
}

function Save-Config($config) {
    $config | ConvertTo-Json -Depth 8 | Set-Content $configPath -Encoding UTF8
    Write-Host "  Saved: $configPath" -ForegroundColor DarkGray
}

# ── GPU detection ──────────────────────────────────────────────────────────────

function Get-AvailableGPUs {
    $result = [System.Collections.Generic.List[PSCustomObject]]::new()
    Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -like 'PCI*' } |
        ForEach-Object {
            # PNPDeviceID format: PCI\VEN_XXXX&DEV_XXXX&SUBSYS_XXXXXXXX&REV_XX\...
            if ($_.PNPDeviceID -match 'VEN_([0-9A-F]+)&DEV_([0-9A-F]+)&SUBSYS_([0-9A-F]+)') {
                $result.Add([PSCustomObject]@{
                    Name      = $_.Name
                    AdapterId = "$($Matches[1])&$($Matches[2])&$($Matches[3])"
                })
            }
        }
    return $result.ToArray()
}

function Select-GPUPreference {
    $gpus = Get-AvailableGPUs

    Write-Host ""
    Write-Host "Detected GPU(s):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $gpus.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $gpus[$i].Name)
    }
    Write-Host "  [H] High Performance  (let Windows choose)"
    Write-Host "  [S] Power Saving"
    Write-Host ""

    while ($true) {
        $raw = (Read-Host "Select GPU preference").Trim()
        if ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $gpus.Count) {
                $gpu = $gpus[$idx]
                Write-Host ("  -> {0}" -f $gpu.Name) -ForegroundColor Green
                return "SpecificAdapter=$($gpu.AdapterId);GpuPreference=1073741824;"
            }
        } elseif ($raw -in 'H', 'h') {
            Write-Host "  -> High Performance" -ForegroundColor Green
            return "GpuPreference=2;"
        } elseif ($raw -in 'S', 's') {
            Write-Host "  -> Power Saving" -ForegroundColor Green
            return "GpuPreference=1;"
        }
        Write-Host "  Invalid. Enter a number, H, or S." -ForegroundColor Yellow
    }
}

# ── Glob path expansion ────────────────────────────────────────────────────────
# Resolves a pattern like "app-*\modules\discord_utils-*\DiscordHelper.exe"
# relative to $Base, supporting wildcards at any directory level.

function Expand-GlobPath {
    param([string]$Base, [string]$Pattern)

    $parts   = $Pattern -split '\\'
    $current = [System.Collections.Generic.List[string]]::new()
    $current.Add($Base)

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part   = $parts[$i]
        $isLast = ($i -eq $parts.Count - 1)
        $next   = [System.Collections.Generic.List[string]]::new()

        foreach ($dir in $current) {
            if (-not (Test-Path $dir -PathType Container)) { continue }

            if ($part -match '[*?]') {
                Get-ChildItem -Path $dir -Filter $part -ErrorAction SilentlyContinue |
                    Where-Object { if ($isLast) { -not $_.PSIsContainer } else { $_.PSIsContainer } } |
                    ForEach-Object { $next.Add($_.FullName) }
            } else {
                $full = Join-Path $dir $part
                if (Test-Path $full) { $next.Add($full) }
            }
        }

        $current = $next
        if ($current.Count -eq 0) { break }
    }

    return , $current.ToArray()
}

# ── Registry application ───────────────────────────────────────────────────────

function Set-GPUPref($exePath, $gpuPref) {
    if (Test-Path $exePath) {
        Set-ItemProperty -Path $regPath -Name $exePath -Value $gpuPref -Type String
        Write-Host "  OK  $([System.IO.Path]::GetFileName($exePath))"
        Write-Host "      $([System.IO.Path]::GetDirectoryName($exePath))"
        $script:total++
    } else {
        Write-Host "  --  (not found) $exePath" -ForegroundColor DarkGray
    }
}

function Apply-AppEntry($app, $gpuPref) {
    Write-Host ""
    Write-Host "-- $($app.name) --"

    # Fixed / direct paths (env vars expanded)
    if ($app.paths) {
        foreach ($p in @($app.paths)) {
            Set-GPUPref ([System.Environment]::ExpandEnvironmentVariables($p)) $gpuPref
        }
    }

    # Glob patterns relative to a versioned base directory
    if ($app.base -and $app.patterns) {
        $base = [System.Environment]::ExpandEnvironmentVariables($app.base)
        foreach ($pattern in @($app.patterns)) {
            foreach ($resolved in (Expand-GlobPath -Base $base -Pattern $pattern)) {
                Set-GPUPref $resolved $gpuPref
            }
        }
    }
}

# ── Add new program wizard ─────────────────────────────────────────────────────

function Add-NewProgram($config) {
    Write-Host ""
    Write-Host "Add a New Program" -ForegroundColor Cyan
    Write-Host "-----------------"

    $name = (Read-Host "  Program name (blank to cancel)").Trim()
    if (-not $name) {
        Write-Host "  Cancelled." -ForegroundColor DarkGray
        return $config
    }

    Write-Host ""
    Write-Host "  Install type:"
    Write-Host "  [1] Standard  — fixed exe path(s)"
    Write-Host "  [2] Updating  — scans versioned app-* subfolders (Discord, Medal, etc.)"
    $typeChoice = (Read-Host "  Choice [1/2]").Trim()

    if ($typeChoice -eq '1') {
        $paths = @()
        Write-Host "  Enter exe path(s). Environment variables like %APPDATA% are supported."
        Write-Host "  Leave blank when done."
        while ($true) {
            $p = (Read-Host "  Exe path").Trim()
            if (-not $p) { break }
            $paths += $p
        }
        if ($paths.Count -eq 0) {
            Write-Host "  No paths entered. Cancelled." -ForegroundColor Yellow
            return $config
        }
        $newEntry = [PSCustomObject]@{ name = $name; paths = $paths }

    } elseif ($typeChoice -eq '2') {
        Write-Host "  Base install folder — the parent that contains Update.exe and app-* subfolders."
        $base = (Read-Host "  Base folder (e.g. %LOCALAPPDATA%\Discord)").Trim()
        if (-not $base) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            return $config
        }
        $exeName = (Read-Host "  Main exe filename (e.g. Discord.exe)").Trim()
        if (-not $exeName) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            return $config
        }
        $patterns = @("Update.exe", "app-*\$exeName")
        $newEntry = [PSCustomObject]@{ name = $name; base = $base; patterns = $patterns }
        Write-Host "  Patterns: $($patterns -join ', ')" -ForegroundColor DarkGray
        Write-Host "  Tip: open gpu-prefs-apps.json to add deeper module patterns if needed." -ForegroundColor DarkGray

    } else {
        Write-Host "  Invalid choice. Cancelled." -ForegroundColor Yellow
        return $config
    }

    $config.apps = @($config.apps) + $newEntry
    Save-Config $config
    Write-Host "  '$name' added to config." -ForegroundColor Green
    return $config, $newEntry
}

# ── Main ───────────────────────────────────────────────────────────────────────

if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$config = Load-Config

if ($AddProgram) {
    $result = Add-NewProgram $config
    Write-Host ""
    Read-Host "Press Enter to close"
    exit
}

$gpuPref = Select-GPUPreference

foreach ($app in @($config.apps)) {
    Apply-AppEntry $app $gpuPref
}

Write-Host ""
Write-Host ("Done — {0} executable(s) pinned." -f $script:total) -ForegroundColor Green

# Offer to add a new program
Write-Host ""
$addNew = (Read-Host "Add a new program to the list? [Y/N]").Trim()
if ($addNew -in 'Y', 'y') {
    $result   = Add-NewProgram $config
    $config   = $result[0]
    $newEntry = $result[1]
    if ($newEntry) {
        Write-Host ""
        Write-Host "Applying to new entry..." -ForegroundColor Cyan
        Apply-AppEntry $newEntry $gpuPref
        Write-Host ""
        Write-Host ("Done — {0} total executable(s) pinned." -f $script:total) -ForegroundColor Green
    }
}

Write-Host ""
Read-Host "Press Enter to close"
