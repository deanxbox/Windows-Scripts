# updateprofile.ps1
# Scans the Scripts folder and adds any new scripts to your PowerShell profile
# as callable functions. Run this whenever you drop in a new script.
#
# Function naming: filename lowercased with hyphens removed.
#   e.g. Set-PowerProfile.ps1  ->  setpowerprofile
#        pullall.ps1            ->  pullall

$scriptsDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$profilePath = $PROFILE
$selfName    = Split-Path -Leaf $MyInvocation.MyCommand.Path

# Ensure profile file exists
if (-not (Test-Path $profilePath)) {
    New-Item -Path $profilePath -ItemType File -Force | Out-Null
}

$profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if (-not $profileContent) { $profileContent = "" }

$added   = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()

Write-Host ""
Write-Host "Updating Profile" -ForegroundColor Cyan
Write-Host "----------------"
Write-Host ""

Get-ChildItem -Path $scriptsDir -Filter "*.ps1" |
    Where-Object { $_.Name -ne $selfName } |
    Sort-Object BaseName |
    ForEach-Object {
        $file     = $_
        $funcName = $file.BaseName.ToLower() -replace '-', ''

        # Write $env:USERPROFILE literally (escaped) so the profile stays portable
        $entry = "function $funcName { & `"`$env:USERPROFILE\Scripts\$($file.Name)`" @args }"

        # Match by filename — avoids false positives from function name collisions
        if ($profileContent -match [regex]::Escape($file.Name)) {
            Write-Host ("  skip  {0,-22} ({1})" -f $funcName, $file.Name) -ForegroundColor DarkGray
            $skipped.Add($file.Name)
        } else {
            Add-Content -Path $profilePath -Value $entry -Encoding UTF8
            $profileContent += "`n$entry"   # keep in-memory copy in sync
            Write-Host ("  add   {0,-22} ({1})" -f $funcName, $file.Name) -ForegroundColor Green
            $added.Add($file.Name)
        }
    }

Write-Host ""

if ($added.Count -gt 0) {
    Write-Host "$($added.Count) function(s) added to profile." -ForegroundColor Green
    Write-Host ""
    $reload = (Read-Host "Reload profile in this session now? [Y/N]").Trim()
    if ($reload -in 'Y', 'y') {
        . $PROFILE
        Write-Host "Profile reloaded." -ForegroundColor Green
    }
} else {
    Write-Host "Profile is already up to date." -ForegroundColor Green
}

Write-Host ""
Read-Host "Press Enter to close"
