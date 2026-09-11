# Apply-GPUPreferences.ps1
# Pins apps to a selected GPU via Windows GPU Preferences registry.
# Run any time to reapply. Use ManageGPUApps.ps1 to add or remove programs.
#
# Usage:
#   .\Apply-GPUPreferences.ps1         - detect GPUs, pick one, apply all apps
#   .\Apply-GPUPreferences.ps1 -WhatIf - preview registry writes

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "", Justification = "NoPause is consumed by a nested helper in this script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSShouldProcess", "", Justification = "Nested helpers delegate confirmation to the outer advanced script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Helper functions are private to this script and are not exported commands.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Nested helpers delegate confirmation to the outer advanced script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "", Justification = "Helper functions are private to this script and return collections.")]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoPause
)

$configPath   = Join-Path $PSScriptRoot "gpu-prefs-apps.json"
$regPath      = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
$script:total = 0
$script:gpus = @()

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

function Get-GPUPrefDisplayName($prefValue, $gpus) {
    if (-not $prefValue) { return $null }
    if ($prefValue -match 'SpecificAdapter=([0-9A-F&]+)') {
        $adapterId = $Matches[1]
        $match = $gpus | Where-Object { $_.AdapterId -eq $adapterId }
        if ($match) { return $match.Name }
        return "Unknown GPU"
    } elseif ($prefValue -match 'GpuPreference=2') {
        return "High Performance"
    } elseif ($prefValue -match 'GpuPreference=1;?$') {
        return "Power Saving"
    }
    return $null
}

function Select-GPUPreference {
    $script:gpus = Get-AvailableGPUs

    Write-Host ""
    Write-Host "Detected GPU(s):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $script:gpus.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $script:gpus[$i].Name)
    }
    Write-Host "  [H] High Performance  (let Windows choose)"
    Write-Host "  [S] Power Saving"
    Write-Host ""

    while ($true) {
        $raw = (Read-Host "Select GPU preference").Trim()
        if ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $script:gpus.Count) {
                $gpu = $script:gpus[$idx]
                Write-Host ("  -> {0}" -f $gpu.Name) -ForegroundColor Green
                return [PSCustomObject]@{ Pref = "SpecificAdapter=$($gpu.AdapterId);GpuPreference=1073741824;"; Name = $gpu.Name }
            }
        } elseif ($raw -in 'H', 'h') {
            Write-Host "  -> High Performance" -ForegroundColor Green
            return [PSCustomObject]@{ Pref = "GpuPreference=2;"; Name = "High Performance" }
        } elseif ($raw -in 'S', 's') {
            Write-Host "  -> Power Saving" -ForegroundColor Green
            return [PSCustomObject]@{ Pref = "GpuPreference=1;"; Name = "Power Saving" }
        }
        Write-Host "  Invalid. Enter a number, H, or S." -ForegroundColor Yellow
    }
}

# ── Registry application ───────────────────────────────────────────────────────

function Set-GPUPref($exePath, $gpuPref) {
    $file = [System.IO.Path]::GetFileName($exePath)
    $dir  = [System.IO.Path]::GetDirectoryName($exePath)
    try {
        if ($PSCmdlet.ShouldProcess($exePath, "Set Windows GPU preference")) {
            $existing = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).PSObject.Properties[$exePath].Value
            $oldName  = Get-GPUPrefDisplayName $existing $script:gpus
            Set-ItemProperty -Path $regPath -Name $exePath -Value $gpuPref.Pref -Type String -ErrorAction Stop
            $changed = $oldName -and $oldName -ne $gpuPref.Name
            $suffix = if ($changed) { "  [$oldName > $($gpuPref.Name)]" } else { "  [$($gpuPref.Name) (unchanged)]" }
            $suffixColor = if ($changed) { 'Cyan' } else { 'DarkGray' }
            Write-Host "  OK  $file" -ForegroundColor Green
            Write-Host "      $dir" -NoNewline
            Write-Host $suffix -ForegroundColor $suffixColor
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
    Write-Host "-- $($app.name) --" -ForegroundColor Cyan

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

# ── Program selection ─────────────────────────────────────────────────────────

function Show-Checklist {
    param([array]$Items)

    $n       = $Items.Count
    $checked = [bool[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $checked[$i] = $true }   # all selected by default
    $pos = 0

    Write-Host ""
    Write-Host "  Up/Down: move   Space: toggle   A: all   N: none   Enter: apply" -ForegroundColor DarkGray
    Write-Host ""

    # Draw the list once, then redraw on every keypress.
    # Lines are truncated to window width so no wrapping occurs and cursor-up is exact.
    # Use [char]27 for ESC — backtick-e only works in PowerShell 6+.
    $esc = [char]27

    $drawList = {
        $maxW = [Math]::Max(1, [Console]::WindowWidth - 1)
        for ($i = 0; $i -lt $n; $i++) {
            $mark  = if ($checked[$i]) { 'x' } else { ' ' }
            $arrow = if ($i -eq $pos) { '>' } else { ' ' }
            $color = if ($i -eq $pos) { 'White' } else { 'Gray' }
            $line  = "  $arrow [$mark] $($Items[$i].name)"
            Write-Host -NoNewline "`r${esc}[2K"
            Write-Host $line.Substring(0, [Math]::Min($line.Length, $maxW)) -ForegroundColor $color
        }
    }

    try {
        [Console]::CursorVisible = $false
        & $drawList

        while ($true) {
            $key = [Console]::ReadKey($true)

            if     ($key.Key -eq [ConsoleKey]::UpArrow)   { if ($pos -gt 0) { $pos-- } }
            elseif ($key.Key -eq [ConsoleKey]::DownArrow) { if ($pos -lt $n - 1) { $pos++ } }
            elseif ($key.Key -eq [ConsoleKey]::Spacebar)  { $checked[$pos] = -not $checked[$pos] }
            elseif ($key.Key -eq [ConsoleKey]::A)         { for ($i = 0; $i -lt $n; $i++) { $checked[$i] = $true } }
            elseif ($key.Key -eq [ConsoleKey]::N)         { for ($i = 0; $i -lt $n; $i++) { $checked[$i] = $false } }
            elseif ($key.Key -eq [ConsoleKey]::Enter)     { break }

            Write-Host -NoNewline "${esc}[$n`A"
            & $drawList
        }
    } finally {
        [Console]::CursorVisible = $true
    }

    Write-Host ""
    return @(for ($i = 0; $i -lt $n; $i++) { if ($checked[$i]) { $Items[$i] } })
}

function Select-AppScope($config) {
    $apps = @($config.apps)
    if ($apps.Count -eq 0) { return @() }

    Write-Host ""
    Write-Host "Apply to:" -ForegroundColor Cyan
    Write-Host "  [1] All programs  (default)"
    Write-Host "  [2] Choose programs"
    Write-Host ""

    while ($true) {
        $raw = (Read-Host "Select [1]").Trim()
        if ($raw -eq '' -or $raw -eq '1') {
            return $apps
        } elseif ($raw -eq '2') {
            $sel = @(Show-Checklist $apps)
            if ($sel.Count -eq 0) {
                Write-Host "  No programs selected. Nothing to apply." -ForegroundColor Yellow
            }
            return $sel
        }
        Write-Host "  Enter 1 or 2." -ForegroundColor Yellow
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────

if (-not (Test-Path $regPath)) {
    if ($PSCmdlet.ShouldProcess($regPath, "Create Windows GPU preferences registry key")) {
        New-Item -Path $regPath -Force | Out-Null
    }
}

$config = Load-Config

$gpuPref     = Select-GPUPreference
$appsToApply = @(Select-AppScope $config)

foreach ($app in $appsToApply) {
    Apply-AppEntry $app $gpuPref
}

Write-Host ""
Write-Host ("Done - {0} executable(s) pinned." -f $script:total) -ForegroundColor Green

Write-Host ""
Wait-BeforeExit
