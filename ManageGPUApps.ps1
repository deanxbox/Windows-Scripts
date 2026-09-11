# ManageGPUApps.ps1
# Adds, removes, and lists apps in the Windows GPU Preferences config.
#
# Usage:
#   .\ManageGPUApps.ps1                - open the app-management menu
#   .\ManageGPUApps.ps1 -AddProgram    - jump straight to add-program wizard
#   .\ManageGPUApps.ps1 -RemoveProgram - jump straight to remove-program wizard
#   .\ManageGPUApps.ps1 -WhatIf        - preview registry/config writes

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "", Justification = "NoPause is consumed by a nested helper in this script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSShouldProcess", "", Justification = "Nested helpers delegate confirmation to the outer advanced script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Helper functions are private to this script and are not exported commands.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Nested helpers delegate confirmation to the outer advanced script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "", Justification = "Helper functions are private to this script and return collections.")]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$AddProgram,
    [switch]$RemoveProgram,
    [switch]$NoPause
)

$configPath   = Join-Path $PSScriptRoot "gpu-prefs-apps.json"
$regPath      = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
$script:total = 0

# ── Config ─────────────────────────────────────────────────────────────────────

function Load-Config {
    if (Test-Path -LiteralPath $configPath) {
        try {
            return Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Could not read config '$configPath': $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ apps = @() }
}

function Save-Config($config) {
    if ($PSCmdlet.ShouldProcess($configPath, "Save GPU preferences app config")) {
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction Stop
        Write-Host "  Saved: $configPath" -ForegroundColor DarkGray
    }
}

function Wait-BeforeExit {
    if (-not $NoPause) {
        Read-Host "Press Enter to close"
    }
}

# ── GPU detection ──────────────────────────────────────────────────────────────

function Get-AvailableGPUs {
    $result = [System.Collections.Generic.List[PSCustomObject]]::new()
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
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

# ── Registry application ───────────────────────────────────────────────────────

function Initialize-GPUPreferenceRegistry {
    if (-not (Test-Path $regPath)) {
        if ($PSCmdlet.ShouldProcess($regPath, "Create Windows GPU preferences registry key")) {
            New-Item -Path $regPath -Force | Out-Null
        }
    }
}

function Set-GPUPref($exePath, $gpuPref) {
    $file = [System.IO.Path]::GetFileName($exePath)
    $dir  = [System.IO.Path]::GetDirectoryName($exePath)
    try {
        if ($PSCmdlet.ShouldProcess($exePath, "Set Windows GPU preference")) {
            Set-ItemProperty -Path $regPath -Name $exePath -Value $gpuPref -Type String -ErrorAction Stop
            Write-Host "  OK  $file"
            Write-Host "      $dir"
            $script:total++
        }
    } catch {
        Write-Host "  !!  (registry write failed) $file" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Find-Exes($dir) {
    Get-ChildItem -LiteralPath $dir -Filter "*.exe" -File -ErrorAction SilentlyContinue
}

function Apply-AppEntry($app, $gpuPref) {
    Write-Host ""
    Write-Host "-- $($app.name) --"

    # Standard: scan each listed directory for all *.exe files
    if ($app.dirs) {
        foreach ($d in @($app.dirs)) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($d)
            if (Test-Path -LiteralPath $expanded -PathType Leaf) {
                # A direct exe path was given instead of a directory - accept it as-is.
                Set-GPUPref $expanded $gpuPref
            } elseif (Test-Path -LiteralPath $expanded -PathType Container) {
                Find-Exes $expanded | ForEach-Object { Set-GPUPref $_.FullName $gpuPref }
            } else {
                Write-Host "  --  (directory not found) $expanded" -ForegroundColor DarkGray
            }
        }
    }

    # Squirrel-style: root-level exes + all exes under every app-* subdir (recursive)
    if ($app.base) {
        $base = [System.Environment]::ExpandEnvironmentVariables($app.base)
        if (Test-Path -LiteralPath $base -PathType Container) {
            Find-Exes $base | ForEach-Object { Set-GPUPref $_.FullName $gpuPref }
            Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'app-*' -or $_.Name -match '^\d+(\.\d+)+$' } |
                ForEach-Object {
                    Get-ChildItem -LiteralPath $_.FullName -Filter "*.exe" -File -Recurse -ErrorAction SilentlyContinue |
                        ForEach-Object { Set-GPUPref $_.FullName $gpuPref }
                }
        } else {
            Write-Host "  --  (directory not found) $base" -ForegroundColor DarkGray
        }
    }
}

# ── Add new program wizard ─────────────────────────────────────────────────────

function Add-NewProgram($config, $gpuPref = $null) {
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
    Write-Host "  [1] Standard  - pins all .exe files found in a directory"
    Write-Host "  [2] Updating  - pins all .exe files in base dir + versioned app-* subfolders"
    $typeChoice = (Read-Host "  Choice [1/2]").Trim()

    if ($typeChoice -eq '1') {
        $dirs = @()
        Write-Host "  Enter the directory (or directories) containing the app's exe files, or a direct .exe path."
        Write-Host "  Environment variables like %APPDATA% are supported. Leave blank when done."
        while ($true) {
            $d = (Read-Host "  Directory").Trim()
            if (-not $d) { break }
            $dirs += $d
        }
        if ($dirs.Count -eq 0) {
            Write-Host "  No directories entered. Cancelled." -ForegroundColor Yellow
            return $config
        }
        $newEntry = [PSCustomObject]@{ name = $name; dirs = $dirs }

    } elseif ($typeChoice -eq '2') {
        Write-Host "  Enter the base install folder (contains Update.exe and app-* subfolders)."
        $base = (Read-Host "  Base folder (e.g. %LOCALAPPDATA%\Discord)").Trim()
        if (-not $base) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            return $config
        }
        $newEntry = [PSCustomObject]@{ name = $name; base = $base }

    } else {
        Write-Host "  Invalid choice. Cancelled." -ForegroundColor Yellow
        return $config
    }

    # Test-apply immediately so the user sees whether the paths resolve before committing
    if ($gpuPref) {
        Write-Host ""
        $before = $script:total
        Apply-AppEntry $newEntry $gpuPref
        $pinned = $script:total - $before

        if ($pinned -eq 0) {
            Write-Host ""
            Write-Host "  No executables were found - the paths may be wrong." -ForegroundColor Yellow
            $doSave = (Read-Host "  Save to config anyway? [Y/N]").Trim()
            if ($doSave -notin 'Y', 'y') {
                Write-Host "  Discarded." -ForegroundColor DarkGray
                return $config
            }
        }
    }

    $config.apps = @($config.apps) + $newEntry
    Save-Config $config
    Write-Host "  '$name' added to config." -ForegroundColor Green
    return $config, $newEntry
}

# ── Remove program wizard ─────────────────────────────────────────────────────

function Remove-Program($config) {
    Write-Host ""
    Write-Host "Remove a Program" -ForegroundColor Cyan
    Write-Host "----------------"
    Write-Host ""

    $apps = @($config.apps)
    if ($apps.Count -eq 0) {
        Write-Host "  No programs in config." -ForegroundColor DarkGray
        return $config
    }

    for ($i = 0; $i -lt $apps.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $apps[$i].name)
    }
    Write-Host "  [0] Cancel"
    Write-Host ""

    while ($true) {
        $raw = (Read-Host "  Remove which?").Trim()
        if ($raw -eq '0') {
            Write-Host "  Cancelled." -ForegroundColor DarkGray
            return $config
        }
        if ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $apps.Count) {
                $name    = $apps[$idx].name
                $confirm = (Read-Host "  Remove '$name'? [Y/N]").Trim()
                if ($confirm -in 'Y', 'y') {
                    $kept = [System.Collections.Generic.List[object]]::new()
                    for ($j = 0; $j -lt $apps.Count; $j++) {
                        if ($j -ne $idx) { $kept.Add($apps[$j]) }
                    }
                    $config.apps = $kept.ToArray()
                    Save-Config $config
                    Write-Host "  '$name' removed." -ForegroundColor Green
                } else {
                    Write-Host "  Cancelled." -ForegroundColor DarkGray
                }
                return $config
            }
        }
        Write-Host "  Invalid choice." -ForegroundColor Yellow
    }
}

function Show-ProgramList($config) {
    Write-Host ""
    Write-Host "Configured Programs" -ForegroundColor Cyan
    Write-Host "-------------------"

    $apps = @($config.apps)
    if ($apps.Count -eq 0) {
        Write-Host "  No programs in config." -ForegroundColor DarkGray
        return
    }

    foreach ($app in $apps) {
        Write-Host ""
        Write-Host "  $($app.name)"
        foreach ($dir in @($app.dirs)) {
            Write-Host "    dirs: $dir" -ForegroundColor DarkGray
        }
        if ($app.base) {
            Write-Host "    base: $($app.base)" -ForegroundColor DarkGray
        }
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────

if ($AddProgram -and $RemoveProgram) {
    throw "Use either -AddProgram or -RemoveProgram, not both."
}

$config = Load-Config

if ($AddProgram) {
    Initialize-GPUPreferenceRegistry
    $gpuPref = Select-GPUPreference
    Add-NewProgram $config $gpuPref | Out-Null
    Write-Host ""
    Wait-BeforeExit
    exit
}

if ($RemoveProgram) {
    Remove-Program $config | Out-Null
    Write-Host ""
    Wait-BeforeExit
    exit
}

while ($true) {
    Write-Host ""
    Write-Host "[A] Add  [R] Remove  [L] List  [Q] Quit" -ForegroundColor Cyan
    $choice = (Read-Host "Choice").Trim()

    if ($choice -in 'A', 'a') {
        Initialize-GPUPreferenceRegistry
        $gpuPref = Select-GPUPreference
        $result = @(Add-NewProgram $config $gpuPref)
        $config = $result[0]
    } elseif ($choice -in 'R', 'r') {
        $config = Remove-Program $config
    } elseif ($choice -in 'L', 'l') {
        Show-ProgramList $config
    } elseif ($choice -in 'Q', 'q') {
        break
    } else {
        Write-Host "  Invalid choice. Enter A, R, L, or Q." -ForegroundColor Yellow
    }
}

Write-Host ""
Wait-BeforeExit
