# Set-PowerProfile.ps1
# Switches power settings between predefined profiles.
# Edit the $profiles array below to add or adjust profiles.
#
# Timeouts are in minutes. 0 = Never.
# AC = plugged in.  DC = on battery.
# Processor values are percentages.
# Use -WhatIf to preview changes without calling powercfg.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "", Justification = "NoPause is consumed by a nested helper in this script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSShouldProcess", "", Justification = "Nested helpers delegate confirmation to the outer advanced script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "", Justification = "Helper functions are private to this script and are not exported commands.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Nested helpers delegate confirmation to the outer advanced script.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "", Justification = "Helper functions are private to this script and return a settings object.")]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Alias("Profile")]
    [ValidateSet("Default", "Always On", "Always On Minimal")]
    [string]$ProfileName,

    [switch]$NoPause
)

# ── Profiles ───────────────────────────────────────────────────────────────────

$profiles = @(
    [PSCustomObject]@{
        Name           = "Default"
        Desc           = "Display off: 30 min  |  Sleep: 1 hr  |  CPU: normal"
        MonitorAC      = 30 ;  SleepAC = 60
        MonitorDC      = 30 ;  SleepDC = 60
        ProcessorMinAC = 0  ;  ProcessorMaxAC = 100
        ProcessorMinDC = 0  ;  ProcessorMaxDC = 100
    },
    [PSCustomObject]@{
        Name           = "Always On"
        Desc           = "Display off: Never   |  Sleep: Never  |  CPU: normal"
        MonitorAC      = 0  ;  SleepAC = 0
        MonitorDC      = 0  ;  SleepDC = 0
        ProcessorMinAC = 0  ;  ProcessorMaxAC = 100
        ProcessorMinDC = 0  ;  ProcessorMaxDC = 100
    },
    [PSCustomObject]@{
        Name           = "Always On Minimal"
        Desc           = "Display off: Never   |  Sleep: Never  |  CPU max: 50%"
        MonitorAC      = 0  ;  SleepAC = 0
        MonitorDC      = 0  ;  SleepDC = 0
        ProcessorMinAC = 0  ;  ProcessorMaxAC = 50
        ProcessorMinDC = 0  ;  ProcessorMaxDC = 50
    }
)

# ── Helpers ────────────────────────────────────────────────────────────────────

function Format-Timeout($min) {
    if ($min -eq 0)                        { return "Never"          }
    if ($min -ge 60 -and $min % 60 -eq 0) { return "$($min / 60) hr" }
    return "$min min"
}

function Wait-BeforeExit {
    if (-not $NoPause) {
        Read-Host "Press Enter to close"
    }
}

function Get-PowerCfgACValue {
    param(
        [Parameter(Mandatory)]
        [string]$Subgroup,

        [Parameter(Mandatory)]
        [string]$Setting
    )

    $out = powercfg /query SCHEME_CURRENT $Subgroup $Setting 2>&1 | Out-String
    if ($out -match 'Current AC Power Setting Index:\s+(0x[\da-fA-F]+)') {
        return [Convert]::ToInt32($Matches[1], 16)
    }
    return $null
}

# ── Detect current AC settings ─────────────────────────────────────────────────

function Get-CurrentACSettings {
    try {
        $monSec       = Get-PowerCfgACValue -Subgroup "SUB_VIDEO" -Setting "VIDEOIDLE"
        $sleepSec     = Get-PowerCfgACValue -Subgroup "SUB_SLEEP" -Setting "STANDBYIDLE"
        $processorMin = Get-PowerCfgACValue -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMIN"
        $processorMax = Get-PowerCfgACValue -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMAX"

        if ($null -eq $monSec -or $null -eq $sleepSec) { return $null }

        return [PSCustomObject]@{
            MonitorAC      = [int]($monSec   / 60)
            SleepAC        = [int]($sleepSec / 60)
            ProcessorMinAC = $processorMin
            ProcessorMaxAC = $processorMax
        }
    } catch { return $null }
}

function Get-ActiveProfileIndex($current) {
    if (-not $current) { return -1 }
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        if ($p.MonitorAC -eq $current.MonitorAC -and
            $p.SleepAC   -eq $current.SleepAC -and
            $p.ProcessorMinAC -eq $current.ProcessorMinAC -and
            $p.ProcessorMaxAC -eq $current.ProcessorMaxAC) { return $i }
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
    Write-Host ("    Current: Display off {0}  |  Sleep {1}  |  CPU {2}-{3}%" -f `
        (Format-Timeout $current.MonitorAC), (Format-Timeout $current.SleepAC),
        $current.ProcessorMinAC, $current.ProcessorMaxAC) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "    [0] Cancel" -ForegroundColor DarkGray
Write-Host ""

if (-not $isAdmin -and -not $WhatIfPreference) {
    Write-Host "  ! Not running as Administrator - changes may fail." -ForegroundColor Red
    Write-Host ""
}

# ── Selection ──────────────────────────────────────────────────────────────────

$selected = if ($ProfileName) {
    $profiles | Where-Object { $_.Name -eq $ProfileName } | Select-Object -First 1
} else {
    $null
}

if (-not $selected) {
    while ($true) {
        $inputValue = Read-Host "Select profile"
        if ($null -eq $inputValue) {
            throw "No profile selection was provided."
        }

        $raw = $inputValue.Trim()
        if ($raw -eq '0') {
            Write-Host ""
            Write-Host "Cancelled." -ForegroundColor DarkGray
            Write-Host ""
            Wait-BeforeExit
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
}

# ── Apply ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Applying '$($selected.Name)'..." -ForegroundColor Cyan

$failures = [System.Collections.Generic.List[string]]::new()

function Set-PowerCfgTimeout {
    param(
        [Parameter(Mandatory)]
        [string]$Argument,

        [Parameter(Mandatory)]
        [int]$Minutes,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ($PSCmdlet.ShouldProcess("current power scheme", "Set $Label to $(Format-Timeout $Minutes)")) {
        & powercfg /change $Argument $Minutes
        if ($LASTEXITCODE -ne 0) {
            $failures.Add($Label) | Out-Null
        }
    }
}

function Set-PowerCfgIndex {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AC", "DC")]
        [string]$PowerMode,

        [Parameter(Mandatory)]
        [string]$Subgroup,

        [Parameter(Mandatory)]
        [string]$Setting,

        [Parameter(Mandatory)]
        [int]$Value,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $argument = if ($PowerMode -eq "AC") { "/setacvalueindex" } else { "/setdcvalueindex" }

    if ($PSCmdlet.ShouldProcess("current power scheme", "Set $Label to $Value")) {
        & powercfg $argument SCHEME_CURRENT $Subgroup $Setting $Value
        if ($LASTEXITCODE -ne 0) {
            $failures.Add($Label) | Out-Null
        }
    }
}

function Apply-CurrentPowerScheme {
    if ($PSCmdlet.ShouldProcess("current power scheme", "Re-apply active power scheme")) {
        & powercfg /setactive SCHEME_CURRENT
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("active power scheme refresh") | Out-Null
        }
    }
}

Set-PowerCfgTimeout -Argument "monitor-timeout-ac" -Minutes $selected.MonitorAC -Label "AC display timeout"
Set-PowerCfgTimeout -Argument "monitor-timeout-dc" -Minutes $selected.MonitorDC -Label "DC display timeout"
Set-PowerCfgTimeout -Argument "standby-timeout-ac" -Minutes $selected.SleepAC -Label "AC sleep timeout"
Set-PowerCfgTimeout -Argument "standby-timeout-dc" -Minutes $selected.SleepDC -Label "DC sleep timeout"
Set-PowerCfgIndex -PowerMode "AC" -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMIN" -Value $selected.ProcessorMinAC -Label "AC minimum processor state"
Set-PowerCfgIndex -PowerMode "AC" -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMAX" -Value $selected.ProcessorMaxAC -Label "AC maximum processor state"
Set-PowerCfgIndex -PowerMode "DC" -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMIN" -Value $selected.ProcessorMinDC -Label "DC minimum processor state"
Set-PowerCfgIndex -PowerMode "DC" -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMAX" -Value $selected.ProcessorMaxDC -Label "DC maximum processor state"
Apply-CurrentPowerScheme

# ── Confirm ────────────────────────────────────────────────────────────────────

Write-Host ""
if ($WhatIfPreference) {
    Write-Host "Preview complete. No settings were changed." -ForegroundColor Yellow
} elseif ($failures.Count -eq 0) {
    Write-Host "Done." -ForegroundColor Green
} else {
    Write-Host "Completed with $($failures.Count) failure(s): $($failures -join ', ')" -ForegroundColor Red
}
Write-Host ("  Display off:  {0}" -f (Format-Timeout $selected.MonitorAC))
Write-Host ("  Sleep:        {0}" -f (Format-Timeout $selected.SleepAC))
Write-Host ("  CPU state:    {0}-{1}%" -f $selected.ProcessorMinAC, $selected.ProcessorMaxAC)
Write-Host ""
Wait-BeforeExit
