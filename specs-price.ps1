# specs-price.ps1
# Displays detected hardware with best-effort local-currency prices from public retailer searches.

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

    $width = 70
    $line = "-" * $width
    Write-Host ""
    Write-Host $line -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host $line -ForegroundColor DarkGray
}

function Write-Row {
    param(
        [string]$Label,
        [string]$Value,
        [int]$Pad = 18,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    Write-Host "  $($Label.PadRight($Pad))" -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

function Get-VendorColor {
    param([string]$Name)

    switch -Regex ($Name) {
        '(?i)\b(AMD|Radeon)\b'                  { return [ConsoleColor]::Red }
        '(?i)\b(Intel|Intel\(R\)|Arc)\b'        { return [ConsoleColor]::Blue }
        '(?i)\b(NVIDIA|GeForce|RTX|GTX)\b'      { return [ConsoleColor]::Green }
        '(?i)\bSamsung\b'                       { return [ConsoleColor]::Cyan }
        '(?i)\b(Western Digital|WD|SanDisk)\b'  { return [ConsoleColor]::Magenta }
        '(?i)\bSeagate\b'                       { return [ConsoleColor]::Yellow }
        '(?i)\b(Crucial|Micron)\b'              { return [ConsoleColor]::DarkCyan }
        '(?i)\bKingston\b'                      { return [ConsoleColor]::DarkYellow }
        '(?i)\b(SK hynix|Hynix)\b'              { return [ConsoleColor]::DarkGreen }
        default                                 { return [ConsoleColor]::White }
    }
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

function Get-PriceCurrency {
    $region = [System.Globalization.RegionInfo]::CurrentRegion
    $currencyCode = $region.ISOCurrencySymbol
    $currencySymbol = (Get-Culture).NumberFormat.CurrencySymbol
    $rate = [decimal]1
    $exchangeRateAvailable = $true

    if ($currencyCode -ne "USD") {
        try {
            $rates = Invoke-RestMethod -Uri "https://open.er-api.com/v6/latest/USD" -TimeoutSec 8 -ErrorAction Stop
            $rateProperty = $rates.rates.PSObject.Properties[$currencyCode]
            if ($rates.result -ne "success" -or $null -eq $rateProperty -or [decimal]$rateProperty.Value -le 0) {
                throw "No exchange rate was returned for $currencyCode."
            }
            $rate = [decimal]$rateProperty.Value
        } catch {
            $currencyCode = "USD"
            $currencySymbol = '$'
            $exchangeRateAvailable = $false
        }
    }

    [pscustomobject]@{
        Code                  = $currencyCode
        Symbol                = $currencySymbol
        UsdRate               = $rate
        ExchangeRateAvailable = $exchangeRateAvailable
    }
}

# Retailer set modeled on the storefronts PCPartPicker's US price-comparison
# tracks (Newegg, Amazon, Best Buy, B&H Photo, Adorama). Each entry needs a
# browser-like User-Agent/Accept-Language or the retailer blocks the request
# with 403; even so a source can still fail/time out, which is handled
# per-source so it never blocks the others.
$browserHeaders = @{
    "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    "Accept-Language" = "en-US,en;q=0.9"
}
$priceSources = @(
    [pscustomobject]@{
        Name       = "Newegg"
        Uri        = "https://www.newegg.com/p/pl?d={0}"
        PriceRegex = '<li class="price-current"[^>]*>.*?\$\s*<strong>(?<price>[\d,]+)</strong><sup>(?<fraction>\.\d{2})</sup>'
    },
    [pscustomobject]@{
        Name       = "Amazon"
        Uri        = "https://www.amazon.com/s?k={0}"
        PriceRegex = 'class="a-offscreen">\$(?<price>[\d,]+\.\d{2})<'
    },
    [pscustomobject]@{
        Name       = "B&H Photo"
        Uri        = "https://www.bhphotovideo.com/c/search?q={0}"
        PriceRegex = '"price"\s*:\s*"?\$?(?<price>[\d,]+\.\d{2})"?'
    },
    [pscustomobject]@{
        Name       = "Best Buy"
        Uri        = "https://www.bestbuy.com/site/searchpage.jsp?st={0}"
        PriceRegex = 'data-testid="[^"]*price[^"]*"[^>]*>\s*\$(?<price>[\d,]+(?:\.\d{2})?)'
    },
    [pscustomobject]@{
        Name       = "Adorama"
        Uri        = "https://www.adorama.com/l/?searchinfo={0}"
        PriceRegex = 'class="price"[^>]*>\s*\$(?<price>[\d,]+\.\d{2})'
    }
)

function Write-TransientStatus {
    param([string]$Text)

    try {
        $width = [Console]::WindowWidth
        if ($width -le 0) { $width = 78 }
    } catch {
        $width = 78
    }
    $line = "  $Text"
    if ($line.Length -gt $width - 1) { $line = $line.Substring(0, $width - 1) }
    Write-Host -NoNewline ("`r" + $line.PadRight($width - 1)) -ForegroundColor DarkGray
}

function Clear-TransientStatus {
    try {
        $width = [Console]::WindowWidth
        if ($width -le 0) { $width = 78 }
    } catch {
        $width = 78
    }
    Write-Host -NoNewline ("`r" + (" " * ($width - 1)) + "`r")
}

function Get-SingleSourcePrice {
    param($Source, [string]$Query, [hashtable]$Headers)

    try {
        $uri = $Source.Uri -f [Uri]::EscapeDataString($Query)
        $content = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 8 -Headers $Headers -ErrorAction Stop).Content

        $priceMatches = [regex]::Matches(
            $content,
            $Source.PriceRegex,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
        )
        if ($priceMatches.Count -eq 0) { return $null }

        # A search page's first hit is often an ad/accessory/unrelated listing.
        # Taking the median of the first several matches is more representative
        # of the actual product's going price than a single first match.
        $sample = [decimal[]]($priceMatches | Select-Object -First 8 | ForEach-Object {
                $fraction = if ($_.Groups["fraction"].Success) { $_.Groups["fraction"].Value } else { "" }
                [decimal]::Parse($_.Groups["price"].Value.Replace(",", "") + $fraction, [Globalization.CultureInfo]::InvariantCulture)
            } | Sort-Object)
        if ($sample.Count -eq 0) { return $null }
        $mid = [Math]::Floor(($sample.Count - 1) / 2)
        $median = if ($sample.Count % 2 -eq 0) { ($sample[$mid] + $sample[$mid + 1]) / 2 } else { $sample[$mid] }

        [pscustomobject]@{ Source = $Source.Name; Price = $median }
    } catch {
        $null
    }
}

function Get-RetailerPrice {
    param([string]$Query, [string]$Label)

    if ($Label) { Write-TransientStatus "Getting $Label information from $($priceSources.Name -join ', ')..." }

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $results = $priceSources | ForEach-Object {
            Get-SingleSourcePrice -Source $_ -Query $Query -Headers $browserHeaders
        }
    } else {
        # Keep the lookup self-contained because -Parallel runspaces do not
        # inherit functions from this script's scope.
        $results = $priceSources | ForEach-Object -ThrottleLimit ([Math]::Max($priceSources.Count, 1)) -Parallel {
            $source = $_
            try {
                $uri = $source.Uri -f [Uri]::EscapeDataString($using:Query)
                $content = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 8 -Headers $using:browserHeaders -ErrorAction Stop).Content
                $priceMatches = [regex]::Matches(
                    $content,
                    $source.PriceRegex,
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
                )
                if ($priceMatches.Count -eq 0) { return }

                $sample = [decimal[]]($priceMatches | Select-Object -First 8 | ForEach-Object {
                        $fraction = if ($_.Groups["fraction"].Success) { $_.Groups["fraction"].Value } else { "" }
                        [decimal]::Parse($_.Groups["price"].Value.Replace(",", "") + $fraction, [Globalization.CultureInfo]::InvariantCulture)
                    } | Sort-Object)
                if ($sample.Count -eq 0) { return }
                $mid = [Math]::Floor(($sample.Count - 1) / 2)
                $median = if ($sample.Count % 2 -eq 0) { ($sample[$mid] + $sample[$mid + 1]) / 2 } else { $sample[$mid] }

                [pscustomobject]@{ Source = $source.Name; Price = $median }
            } catch {
                $null
            }
        }
    }

    if ($Label) { Clear-TransientStatus }
    $results | Where-Object { $_ }
}

# Preserve the original single-source helper for existing callers.
function Get-ApproximatePrice {
    param([string]$Query)

    try {
        $content = (Invoke-WebRequest -Uri "https://www.newegg.com/p/pl?d=$([Uri]::EscapeDataString($Query))" -UseBasicParsing -TimeoutSec 8 -Headers $browserHeaders -ErrorAction Stop).Content
        $match = [regex]::Match(
            $content,
            '<li class="price-current"[^>]*>.*?\$\s*<strong>(?<price>[\d,]+)</strong><sup>(?<fraction>\.\d{2})</sup>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
        )
        if ($match.Success) {
            return [decimal]::Parse(
                $match.Groups["price"].Value.Replace(",", "") + $match.Groups["fraction"].Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
    } catch {
        return $null
    }
}

function Format-Price {
    param(
        $Price,
        [string]$CurrencySymbol,
        [string]$CurrencyCode
    )

    if ($null -eq $Price) { return "N/A" }
    return $CurrencySymbol + ([decimal]$Price).ToString("N2", [Globalization.CultureInfo]::InvariantCulture) + " $CurrencyCode"
}

function Get-SpecificGpuModel {
    param([string]$GenericName)

    # Best-effort lookup of a board-partner SKU/model code (e.g. "ZT-B50710D2-10P")
    # beyond the generic chip name reported by Win32_VideoController. Not every
    # system/driver exposes this; returns $null if nothing more specific is found.
    try {
        $escaped = [regex]::Escape($GenericName)
        $driver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -and $_.DeviceName -match $escaped } |
            Select-Object -First 1
        if (-not $driver) { return $null }

        foreach ($candidate in @($driver.FriendlyName, $driver.DeviceName)) {
            if ($candidate -and $candidate -ne $GenericName -and $candidate -notmatch "^$escaped$") {
                $extra = ($candidate -replace [regex]::Escape($GenericName), "").Trim(" -()")
                if ($extra) { return $extra }
            }
        }
    } catch {
        return $null
    }
    return $null
}

if (-not $NoClear) {
    Clear-Host
}

$width = 70
Write-Host ("=" * $width) -ForegroundColor Cyan
Write-Host "  APPROXIMATE COMPONENT VALUE" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ("=" * $width) -ForegroundColor Cyan

$cpu = Get-CimInstance Win32_Processor
$gpus = Get-CimInstance Win32_VideoController | Where-Object { -not (Test-GpuExcluded $_.Name) }
$ram = @(Get-CimInstance Win32_PhysicalMemory)
$mb = Get-CimInstance Win32_BaseBoard
$disks = @(Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -ne "USB" })

$totalGB = [Math]::Round(($ram | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
$memoryType = Get-MemoryTypeName -Memory $ram
$sticks = $ram.Count
$ramModels = @($ram | ForEach-Object {
        "$($_.Manufacturer) $($_.PartNumber)".Trim()
    } | Where-Object { $_ } | Select-Object -Unique)
$ramName = "${totalGB}GB $memoryType ($sticks x $([Math]::Round($totalGB / [Math]::Max($sticks, 1), 1))GB)"
if ($ramModels.Count -gt 0) {
    $ramName += " - $($ramModels -join ', ')"
}
$ramQuery = if ($ramModels.Count -gt 0) {
    "$($ramModels[0]) $sticks module memory kit"
} else {
    "${totalGB}GB $memoryType memory kit"
}

$components = @(
    [pscustomobject]@{
        Label = "CPU"
        Name  = $cpu.Name.Trim()
        Query = $cpu.Name.Trim()
        Color = Get-VendorColor "$($cpu.Name) $($cpu.Manufacturer)"
    }
)

$gpuNumber = 0
foreach ($gpu in $gpus) {
    $gpuNumber++
    # Best-effort: Win32_VideoController only exposes the generic chip name
    # (e.g. "NVIDIA GeForce RTX 5070 Ti"). Some systems expose a more specific
    # board-partner model/SKU string (e.g. "ZT-B50710D2-10P") via the PnP
    # signed driver's DeviceName/FriendlyName. This is not available on every
    # system/driver, so we fall back to the generic name when nothing more
    # specific is found.
    $gpuModel = Get-SpecificGpuModel -GenericName $gpu.Name
    $gpuDisplayName = if ($gpuModel) { "$($gpu.Name) ($gpuModel)" } else { $gpu.Name }
    $gpuQuery = if ($gpuModel) { "$($gpu.Name) $gpuModel" } else { $gpu.Name }
    $components += [pscustomobject]@{
        Label = "GPU $gpuNumber"
        Name  = $gpuDisplayName
        Query = $gpuQuery
        Color = Get-VendorColor $gpu.Name
    }
}

$components += [pscustomobject]@{
    Label = "RAM"
    Name  = $ramName
    Query = $ramQuery
    Color = Get-VendorColor ($ramModels -join " ")
}
$components += [pscustomobject]@{
    Label = "Motherboard"
    Name  = "$($mb.Manufacturer) $($mb.Product)".Trim()
    Query = "$($mb.Manufacturer) $($mb.Product) motherboard".Trim()
    Color = Get-VendorColor $mb.Manufacturer
}

$diskNumber = 0
foreach ($disk in $disks) {
    $diskNumber++
    $sizeGB = [Math]::Round($disk.Size / 1GB, 1)
    $components += [pscustomobject]@{
        Label = "Storage $diskNumber"
        Name  = "$($disk.Model) (${sizeGB}GB)"
        Query = "$($disk.Model) internal drive"
        Color = Get-VendorColor $disk.Model
    }
}

Write-TransientStatus "Detecting local currency and exchange rate..."
$currency = Get-PriceCurrency
Clear-TransientStatus
$sourceNames = $priceSources.Name -join ", "
$currencyNote = if (-not $currency.ExchangeRateAvailable) {
    "(USD $([char]0x2014) exchange rate unavailable)"
} elseif ($currency.Code -eq "USD") {
    "USD (local currency; conversion not required)"
} else {
    "$($currency.Code) (converted from scraped USD prices)"
}

Write-Header "COMPONENT PRICES ($($currency.Code))"
Write-Host "  Currency: $currencyNote" -ForegroundColor DarkGray

$total = [decimal]0
$unpriced = @()
$summaryLines = @(
    "Currency: $currencyNote"
    "Sources queried: $sourceNames"
    ""
)
$priceRecords = @()
foreach ($component in $components) {
    $prices = @(Get-RetailerPrice -Query $component.Query -Label $component.Label)
    $price = if ($prices.Count -gt 0) {
        [decimal](($prices | Measure-Object -Property Price -Average).Average) * $currency.UsdRate
    } else {
        $null
    }
    $priceText = Format-Price $price -CurrencySymbol $currency.Symbol -CurrencyCode $currency.Code
    $sourcesText = if ($prices.Count -gt 0) { " avg ($($prices.Source -join ', '))" } else { "" }
    Write-Row $component.Label "$($component.Name)  [$priceText$sourcesText]" -Color $component.Color
    $summaryLines += "$($component.Label): $($component.Name) - $priceText$sourcesText"

    if ($null -eq $price) {
        $unpriced += "$($component.Label): $($component.Name)"
    } else {
        $total += $price
    }
    $priceRecords += [pscustomobject]@{
        Label = $component.Label
        Name  = $component.Name
        Price = if ($null -eq $price) { $null } else { [double]$price }
    }
}

Write-Host "  Sources queried: $sourceNames. Figures are best-effort estimates, not live quotes." -ForegroundColor DarkGray

Write-Header "TOTAL"
$totalText = Format-Price $total -CurrencySymbol $currency.Symbol -CurrencyCode $currency.Code
Write-Row "TOTAL (approx)" $totalText -Color Cyan
if ($unpriced.Count -gt 0) {
    Write-Host "  Excluded from total (price unavailable): $($unpriced -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "  All detected components were included." -ForegroundColor DarkGray
}

$summaryLines += ""
$summaryLines += "TOTAL (approx): $totalText"
if ($unpriced.Count -gt 0) {
    $summaryLines += "Excluded from total: $($unpriced -join ', ')"
}

# -- Price history (save today's run + optional comparisons) -----------------
$historyPath = Join-Path $PSScriptRoot "specs-price-history.json"
$todayKey = (Get-Date).ToString("yyyy-MM-dd")
$history = @()
if (Test-Path $historyPath) {
    try {
        $loaded = Get-Content -Path $historyPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($loaded) { $history = @($loaded) }
    } catch {
        Write-Host "  (existing price history file could not be read; starting a fresh history)" -ForegroundColor DarkGray
        $history = @()
    }
}

$todayRecord = [pscustomobject]@{
    Date       = $todayKey
    Currency   = $currency.Code
    Total      = [double]$total
    Components = @($priceRecords)
}
$history = @($history | Where-Object { $_.Date -ne $todayKey })
$history += $todayRecord
try {
    $history | ConvertTo-Json -Depth 6 | Set-Content -Path $historyPath -Encoding utf8
} catch {
    Write-Host "  (unable to save price history: $($_.Exception.Message))" -ForegroundColor DarkGray
}

$comparisonSummaryLines = @()
# Note: an earlier version pre-checked $Host.UI.RawUI.WindowSize.Width and
# skipped this whole section if that check failed/threw (e.g. in several
# real terminal hosts where WindowSize isn't reliably reported) - which
# silently disabled the date-comparison prompt even when running
# interactively. Just attempt Read-Host directly instead; a genuinely
# non-interactive host will fail on the first Read-Host call below and the
# existing try/catch breaks out of the loop cleanly.
Write-Header "COMPARE WITH AN EARLIER DATE"
while ($true) {
        $dateInput = $null
        try {
            $dateInput = Read-Host "  Enter a date as DD/MM/YYYY to compare, or press Enter/'q' to quit"
        } catch {
            break
        }
        if ([string]::IsNullOrWhiteSpace($dateInput) -or $dateInput.Trim() -in @("q", "quit")) {
            break
        }

        $parsedDate = $null
        try {
            $parsedDate = [datetime]::ParseExact($dateInput.Trim(), "dd/MM/yyyy", $null)
        } catch {
            Write-Host "  Invalid date format. Please use DD/MM/YYYY." -ForegroundColor Yellow
            continue
        }

        $compareKey = $parsedDate.ToString("yyyy-MM-dd")
        $record = $history | Where-Object { $_.Date -eq $compareKey } | Select-Object -First 1
        if (-not $record) {
            Write-Host "  No price data is available for $($parsedDate.ToString('dd/MM/yyyy'))." -ForegroundColor Yellow
            $comparisonSummaryLines += "No price data available for $($parsedDate.ToString('dd/MM/yyyy'))."
            continue
        }

        Write-Host ""
        Write-Host "  Comparison vs $($parsedDate.ToString('dd/MM/yyyy')) ($($record.Currency)):" -ForegroundColor Yellow
        $comparisonSummaryLines += "Comparison vs $($parsedDate.ToString('dd/MM/yyyy')) ($($record.Currency)):"

        foreach ($component in $priceRecords) {
            $old = $record.Components | Where-Object { $_.Label -eq $component.Label } | Select-Object -First 1
            if (-not $old -or $null -eq $old.Price -or $null -eq $component.Price) {
                continue
            }
            $diff = $component.Price - $old.Price
            $pct = if ($old.Price -ne 0) { ($diff / $old.Price) * 100 } else { 0 }
            $deltaColor = if ($diff -lt 0) { "Green" } elseif ($diff -gt 0) { "Red" } else { "White" }
            $line = "    $($component.Label): {0:N2} -> {1:N2} ({2}{3:N2}, {2}{4:N1}%)" -f `
                $old.Price, $component.Price, $(if ($diff -ge 0) { "+" } else { "" }), $diff, $pct
            Write-Host $line -ForegroundColor $deltaColor
            $comparisonSummaryLines += $line.Trim()
        }

        if ($null -ne $record.Total) {
            $totalDiff = $total - $record.Total
            $totalPct = if ($record.Total -ne 0) { ($totalDiff / $record.Total) * 100 } else { 0 }
            $totalColor = if ($totalDiff -lt 0) { "Green" } elseif ($totalDiff -gt 0) { "Red" } else { "White" }
            $totalLine = "    TOTAL: {0:N2} -> {1:N2} ({2}{3:N2}, {2}{4:N1}%)" -f `
                $record.Total, $total, $(if ($totalDiff -ge 0) { "+" } else { "" }), $totalDiff, $totalPct
            Write-Host $totalLine -ForegroundColor $totalColor
            $comparisonSummaryLines += $totalLine.Trim()
        }
        Write-Host ""
    }

if ($comparisonSummaryLines.Count -gt 0) {
    $summaryLines += ""
    $summaryLines += "--- Historical comparisons ---"
    $summaryLines += $comparisonSummaryLines
}

$summary = $summaryLines -join [Environment]::NewLine

if (-not $NoClipboard) {
    try {
        Set-Clipboard -Value $summary
        Write-Host "  (summary copied to clipboard)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  (clipboard unavailable)" -ForegroundColor DarkGray
    }
}

Write-Host ""
