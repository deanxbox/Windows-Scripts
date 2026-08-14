# updateprofile.ps1
# Scans the Scripts folder and adds any new scripts to your PowerShell profile
# as callable functions. Run this whenever you drop in a new script.
#
# Function naming: filename lowercased with hyphens removed.
#   e.g. Set-PowerProfile.ps1  ->  setpowerprofile
#        pullall.ps1            ->  pullall

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateScript({
        if (Test-Path -LiteralPath $_ -PathType Container) { return $true }
        throw "Scripts directory does not exist: $_"
    })]
    [string]$ScriptsDir = $PSScriptRoot,

    [string]$ProfilePath = $PROFILE,

    [switch]$NoReload,
    [switch]$NoPause
)

$scriptsDir  = (Resolve-Path -LiteralPath $ScriptsDir).Path
$profilePath = $ProfilePath
$selfName    = Split-Path -Leaf $MyInvocation.MyCommand.Path

# Ensure profile file exists
if (-not (Test-Path -LiteralPath $profilePath)) {
    if ($PSCmdlet.ShouldProcess($profilePath, "Create PowerShell profile")) {
        New-Item -Path $profilePath -ItemType File -Force | Out-Null
    }
}

$profileContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
if (-not $profileContent) { $profileContent = "" }

$added   = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
$wouldAdd = [System.Collections.Generic.List[string]]::new()

Write-Host ""
Write-Host "Updating Profile" -ForegroundColor Cyan
Write-Host "----------------"
Write-Host ""

function Get-ProfileScriptPath {
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )

    $homeScripts = Join-Path $env:USERPROFILE "Scripts"
    $resolvedHomeScripts = if (Test-Path -LiteralPath $homeScripts) {
        (Resolve-Path -LiteralPath $homeScripts).Path
    } else {
        $homeScripts
    }

    if ($scriptsDir -ieq $resolvedHomeScripts) {
        return "`$env:USERPROFILE\Scripts\$FileName"
    }

    return (Join-Path $scriptsDir $FileName)
}

Get-ChildItem -LiteralPath $scriptsDir -Filter "*.ps1" |
    Where-Object { $_.Name -ne $selfName -and $_.Name -notlike "*.Tests.ps1" } |
    Sort-Object BaseName |
    ForEach-Object {
        $file     = $_
        $funcName = $file.BaseName.ToLower() -replace '-', ''

        $scriptPath = Get-ProfileScriptPath -FileName $file.Name
        $entry = "function $funcName { & `"$scriptPath`" @args }"

        # Match by filename - avoids false positives from function name collisions
        if ($profileContent -match [regex]::Escape($file.Name)) {
            Write-Host ("  skip  {0,-22} ({1})" -f $funcName, $file.Name) -ForegroundColor DarkGray
            $skipped.Add($file.Name)
        } else {
            if ($PSCmdlet.ShouldProcess($profilePath, "Add function '$funcName' for $($file.Name)")) {
                Add-Content -LiteralPath $profilePath -Value $entry -Encoding UTF8
                $profileContent += "`n$entry"   # keep in-memory copy in sync
                Write-Host ("  add   {0,-22} ({1})" -f $funcName, $file.Name) -ForegroundColor Green
                $added.Add($file.Name)
            } else {
                Write-Host ("  would add {0,-18} ({1})" -f $funcName, $file.Name) -ForegroundColor Yellow
                $wouldAdd.Add($file.Name) | Out-Null
            }
        }
    }

Write-Host ""

if ($added.Count -gt 0) {
    Write-Host "$($added.Count) function(s) added to profile." -ForegroundColor Green
    Write-Host ""
    if (-not $NoReload) {
        $reload = (Read-Host "Reload profile in this session now? [Y/N]").Trim()
        if ($reload -in 'Y', 'y') {
            . $profilePath
            Write-Host "Profile reloaded." -ForegroundColor Green
        }
    }
} else {
    if ($wouldAdd.Count -gt 0) {
        Write-Host "$($wouldAdd.Count) function(s) would be added to profile." -ForegroundColor Yellow
    } else {
        Write-Host "Profile is already up to date." -ForegroundColor Green
    }
}

Write-Host ""
if (-not $NoPause) {
    Read-Host "Press Enter to close"
}
