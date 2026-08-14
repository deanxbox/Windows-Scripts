# specs.ps1
# Displays system specifications in a clean formatted layout.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "", Justification = "GPU filter parameters are consumed by a nested helper in this script.")]
[CmdletBinding()]
param(
    [switch]$NoClear,
    [switch]$NoClipboard,
    [switch]$IncludeIntegratedGpu,
    [string[]]$ExcludeGpuNamePattern = @("AMD Radeon\(TM\) Graphics")
)

function Write-Header {
    param([string]$Title)
    $width = 50
    $line = "-" * $width
    Write-Host ""
    Write-Host $line -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host $line -ForegroundColor DarkGray
}

function Write-Row {
    param([string]$Label, [string]$Value, [int]$Pad = 22)
    Write-Host "  $($Label.PadRight($Pad))" -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

function Get-MemoryTypeName {
    param([object[]]$Memory)

    $typeMap = @{
        20 = "DDR"
        21 = "DDR2"
        24 = "DDR3"
        26 = "DDR4"
        27 = "LPDDR"
        28 = "LPDDR2"
        29 = "LPDDR3"
        30 = "LPDDR4"
        34 = "DDR5"
        35 = "LPDDR5"
    }

    $types = @($Memory |
        ForEach-Object {
            if ($_.SMBIOSMemoryType -and $typeMap.ContainsKey([int]$_.SMBIOSMemoryType)) {
                $typeMap[[int]$_.SMBIOSMemoryType]
            } elseif ($_.MemoryType -and $typeMap.ContainsKey([int]$_.MemoryType)) {
                $typeMap[[int]$_.MemoryType]
            }
        } |
        Where-Object { $_ } |
        Select-Object -Unique)

    if ($types.Count -gt 0) { return ($types -join "/") }
    return "Unknown"
}

function Test-GpuExcluded {
    param([string]$Name)

    if ($IncludeIntegratedGpu) { return $false }
    foreach ($pattern in $ExcludeGpuNamePattern) {
        if ($Name -match $pattern) { return $true }
    }
    return $false
}

if (-not $NoClear) {
    Clear-Host
}

$width = 50
Write-Host ("=" * $width) -ForegroundColor Cyan
Write-Host "  SYSTEM SPECIFICATIONS" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ("=" * $width) -ForegroundColor Cyan

# -- CPU ---------------------------------------------------------------------
Write-Header "CPU"
$cpu = Get-CimInstance Win32_Processor
Write-Row "Name"     $cpu.Name.Trim()
Write-Row "Cores"    "$($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T"
Write-Row "Base Clock" "$($cpu.MaxClockSpeed) MHz"

# -- RAM ---------------------------------------------------------------------
Write-Header "RAM"
$ram = Get-CimInstance Win32_PhysicalMemory
$totalGB = [Math]::Round(($ram | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
$speed = ($ram | Select-Object -First 1).ConfiguredClockSpeed
$sticks = $ram.Count
$memoryType = Get-MemoryTypeName -Memory $ram
Write-Row "Total"    "${totalGB}GB"
if ($sticks -gt 0) {
    Write-Row "Config" "$sticks x $([Math]::Round($totalGB / $sticks, 1))GB @ ${speed} MT/s"
} else {
    Write-Row "Config" "Unknown"
}
Write-Row "Type"     $memoryType

# -- GPU ---------------------------------------------------------------------
Write-Header "GPU(s)"
$gpus = Get-CimInstance Win32_VideoController | Where-Object { -not (Test-GpuExcluded $_.Name) }
foreach ($gpu in $gpus) {
    Write-Row $gpu.Name "Driver $($gpu.DriverVersion)" 30
}

# -- Motherboard -------------------------------------------------------------
Write-Header "Motherboard"
$mb = Get-CimInstance Win32_BaseBoard
Write-Row "Manufacturer" $mb.Manufacturer
Write-Row "Model"        $mb.Product

# -- Storage -----------------------------------------------------------------
Write-Header "Storage"
$disks = Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -ne "USB" }
foreach ($disk in $disks) {
    $sizeGB = [Math]::Round($disk.Size / 1GB, 1)
    Write-Row $disk.Model "${sizeGB} GB" 30
}

# -- OS ----------------------------------------------------------------------
Write-Header "OS"
$os = Get-CimInstance Win32_OperatingSystem
Write-Row "Name"    $os.Caption
Write-Row "Version" "$($os.Version) (Build $($os.BuildNumber))"
Write-Row "Arch"    $os.OSArchitecture

Write-Host ""
Write-Host ("=" * $width) -ForegroundColor Cyan

# -- Quick Share ---------------------------------------------------------------
$gpuNames     = ($gpus | ForEach-Object { $_.Name }) -join ', '
$storageItems = ($disks | ForEach-Object {
    "$([Math]::Round($_.Size / 1GB))GB $($_.Model)"
}) -join ', '
$summary = "CPU: $($cpu.Name.Trim()) ($($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T)" +
           " | RAM: ${totalGB}GB $memoryType @ ${speed} MT/s" +
           " | GPU: $gpuNames" +
           " | MB: $($mb.Manufacturer) $($mb.Product)" +
           " | Storage: $storageItems" +
           " | OS: $($os.Caption)"

Write-Host ""
Write-Host "  QUICK SHARE" -ForegroundColor Yellow
Write-Host ("=" * $width) -ForegroundColor Cyan
Write-Host ""
Write-Host $summary -ForegroundColor White
Write-Host ""
if (-not $NoClipboard) {
    try {
        Set-Clipboard -Value $summary
        Write-Host "  (copied to clipboard)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  (clipboard unavailable)" -ForegroundColor DarkGray
    }
}

Write-Host ""
