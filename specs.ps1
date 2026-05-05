# specs.ps1
# Displays system specifications in a clean formatted layout.

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

Clear-Host

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
Write-Row "Total"    "${totalGB}GB"
Write-Row "Config"   "$sticks x $([Math]::Round($totalGB/$sticks))GB @ ${speed} MT/s"
Write-Row "Type"     "DDR5"

# -- GPU ---------------------------------------------------------------------
Write-Header "GPU(s)"
$gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notlike "AMD Radeon(TM) Graphics" }
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
Write-Host ""