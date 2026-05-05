# Set-PowerProfile.ps1
# Switches power settings between predefined profiles.
# Edit the $profiles array below to add or adjust profiles.
#
# Timeouts are in minutes. 0 = Never.
# AC = plugged in.  DC = on battery.

# ── Profiles ───────────────────────────────────────────────────────────────────

$profiles = @(
    [PSCustomObject]@{
        Name      = "Default"
        Desc      = "Display off: 30 min  |  Sleep: 1 hr"
        MonitorAC = 30 ;  SleepAC = 60
        MonitorDC = 30 ;  SleepDC = 60
    },
    [PSCustomObject]@{
        Name      = "Always On"
        Desc      = "Display off: Never   |  Sleep: Never"
        MonitorAC = 0  ;  SleepAC = 0
        MonitorDC = 0  ;  SleepDC = 0
    }
)

# ── Helpers ────────────────────────────────────────────────────────────────────

function Format-Timeout($min) {
    if ($min -eq 0)                        { return "Never"          }
    if ($min -ge 60 -and $min % 60 -eq 0) { return "$($min / 60) hr" }
    return "$min min"
}

# ── Detect current AC settings ─────────────────────────────────────────────────

function Get-CurrentACSettings {
    try {
        $monOut   = powercfg /query SCHEME_CURRENT SUB_VIDEO   VIDEOIDLE   2>&1 | Out-String
        $sleepOut = powercfg /query SCHEME_CURRENT SUB_SLEEP   STANDBYIDLE 2>&1 | Out-String

        $monSec   = if ($monOut   -match 'Current AC Power Setting Index:\s+(0x[\da-fA-F]+)') { [Convert]::ToInt32($Matches[1], 16) } else { $null }
        $sleepSec = if ($sleepOut -match 'Current AC Power Setting Index:\s+(0x[\da-fA-F]+)') { [Convert]::ToInt32($Matches[1], 16) } else { $null }

        if ($null -eq $monSec -or $null -eq $sleepSec) { return $null }

        return [PSCustomObject]@{
            MonitorAC = [int]($monSec   / 60)
            SleepAC   = [int]($sleepSec / 60)
        }
    } catch { return $null }
}

function Get-ActiveProfileIndex($current) {
    if (-not $current) { return -1 }
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if ($profiles[$i].MonitorAC -eq $current.MonitorAC -and
            $profiles[$i].SleepAC   -eq $current.SleepAC) { return $i }
    }
    return -1
}

# ── Admin check ────────────────────────────────────────────────────────────────

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ── Menu ───────────────────────────────────────────────────────────────────────

$current     = Get-CurrentACSettings
$activeIndex = Get-ActiveProfileIndex $current

Write-Host ""
Write-Host "Choose a Power Profile" -ForegroundColor Cyan
Write-Host "----------------------"
Write-Host ""

for ($i = 0; $i -lt $profiles.Count; $i++) {
    $p      = $profiles[$i]
    $active = ($i -eq $activeIndex)
    $marker = if ($active) { "*" } else { " " }
    $color  = if ($active) { "Yellow" } else { "Gray" }
    Write-Host ("  $marker [{0}] {1,-14} ({2})" -f ($i + 1), $p.Name, $p.Desc) -ForegroundColor $color
}

# Show current settings if they don't match any profile
if ($activeIndex -eq -1 -and $current) {
    Write-Host ""
    Write-Host ("    Current: Display off {0}  |  Sleep {1}" -f `
        (Format-Timeout $current.MonitorAC), (Format-Timeout $current.SleepAC)) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "    [0] Cancel" -ForegroundColor DarkGray
Write-Host ""

if (-not $isAdmin) {
    Write-Host "  ! Not running as Administrator - changes may fail." -ForegroundColor Red
    Write-Host ""
}

# ── Selection ──────────────────────────────────────────────────────────────────

$selected = $null
while ($true) {
    $raw = (Read-Host "Select profile").Trim()
    if ($raw -eq '0') {
        Write-Host ""
        Write-Host "Cancelled." -ForegroundColor DarkGray
        Write-Host ""
        Read-Host "Press Enter to close"
        exit
    }
    if ($raw -match '^\d+$') {
        $idx = [int]$raw - 1
        if ($idx -ge 0 -and $idx -lt $profiles.Count) {
            $selected = $profiles[$idx]
            break
        }
    }
    Write-Host "  Invalid. Enter a number or 0 to cancel." -ForegroundColor Yellow
}

# ── Apply ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Applying '$($selected.Name)'..." -ForegroundColor Cyan

powercfg /change monitor-timeout-ac $selected.MonitorAC
powercfg /change monitor-timeout-dc $selected.MonitorDC
powercfg /change standby-timeout-ac $selected.SleepAC
powercfg /change standby-timeout-dc $selected.SleepDC

# ── Confirm ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ("  Display off:  {0}" -f (Format-Timeout $selected.MonitorAC))
Write-Host ("  Sleep:        {0}" -f (Format-Timeout $selected.SleepAC))
Write-Host ""
Read-Host "Press Enter to close"
