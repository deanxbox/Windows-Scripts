# projectdump.ps1
# Recursively dumps all relevant project files into clipboard for AI analysis.
# Usage: projectdump.ps1 [path] [-MaxFileSizeKB 500] [-NoClip]

param(
    [string]$Path = ".",
    [int]$MaxFileSizeKB = 500,
    [switch]$NoClip
)

# -- Ignored directory names (anywhere in the tree) --------------------------
$ignoredDirs = @(
    'bin', 'obj', 'build', 'dist', 'out', 'output', 'target',
    'release', 'debug', '.gradle', '.mvn',
    'node_modules', 'vendor', 'packages', '.nuget',
    'venv', '.venv', 'env', '.env', '__pycache__',
    'site-packages',
    '.git', '.svn', '.hg',
    '.idea', '.vs', '.vscode',
    '.cache', '.tmp', 'tmp', 'temp', 'logs', 'log',
    'generated-sources', 'generated-test-sources',
    'run', 'runs', 'remappedSrc',
    'assets', 'public', 'static', 'media', 'images', 'fonts'
)

# -- Ignored file extensions -------------------------------------------------
$ignoredExtensions = @(
    '.exe', '.dll', '.so', '.dylib', '.lib', '.a', '.o', '.obj',
    '.class', '.jar', '.war', '.ear', '.nar',
    '.pyc', '.pyd', '.pyo',
    '.zip', '.tar', '.gz', '.bz2', '.7z', '.rar', '.xz', '.tgz',
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.svg', '.webp',
    '.mp3', '.mp4', '.wav', '.ogg', '.flac', '.avi', '.mov', '.mkv',
    '.ttf', '.otf', '.woff', '.woff2', '.eot',
    '.db', '.sqlite', '.sqlite3', '.mdb', '.ldb',
    '.bin', '.dat', '.raw', '.dump',
    '.lock',
    '.min.js', '.min.css', '.map',
    '.nupkg', '.snupkg'
)

# -- Ignored specific filenames ----------------------------------------------
$ignoredFiles = @(
    'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml',
    'Pipfile.lock', 'poetry.lock', 'composer.lock', 'Gemfile.lock',
    'gradle-wrapper.jar', '.DS_Store', 'Thumbs.db',
    '.gitattributes'
)

$rootPath = Resolve-Path $Path
$lines    = [System.Collections.Generic.List[string]]::new()
$included = 0
$skipped  = 0

$lines.Add("=" * 80)
$lines.Add("PROJECT DUMP: $rootPath")
$lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("=" * 80)
$lines.Add("")
$lines.Add("DIRECTORY STRUCTURE")
$lines.Add("-" * 40)

# -- Tree via stack (no nested functions, no scope issues) -------------------
$stack = [System.Collections.Generic.Stack[object]]::new()
$stack.Push(@{ Dir = $rootPath.Path; Prefix = "" })

while ($stack.Count -gt 0) {
    $frame  = $stack.Pop()
    $dir    = $frame.Dir
    $prefix = $frame.Prefix

    $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notmatch '^\.' -or $_.Name -eq '.gitignore' } |
             Sort-Object Name

    # Dirs first, then files
    $items = @($items | Where-Object { $_.PSIsContainer }) + @($items | Where-Object { -not $_.PSIsContainer })

    for ($i = 0; $i -lt $items.Count; $i++) {
        $item      = $items[$i]
        $isLast    = ($i -eq $items.Count - 1)
        if ($isLast) { $connector = "+-- " } else { $connector = "|-- " }

        if ($item.PSIsContainer) {
            if ($ignoredDirs -contains $item.Name.ToLower()) {
                $lines.Add("${prefix}${connector}$($item.Name)/ [skipped]")
                continue
            }
            $lines.Add("${prefix}${connector}$($item.Name)/")
            if ($isLast) { $newPrefix = $prefix + "    " } else { $newPrefix = $prefix + "|   " }
            # Push in reverse order so stack processes in correct order
            $stack.Push(@{ Dir = $item.FullName; Prefix = $newPrefix })
        } else {
            $lines.Add("${prefix}${connector}$($item.Name)")
        }
    }
}

$lines.Add("")
$lines.Add("=" * 80)
$lines.Add("FILE CONTENTS")
$lines.Add("=" * 80)
$lines.Add("")

# -- File contents -----------------------------------------------------------
$allFiles = Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue

foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Substring($rootPath.Path.Length).TrimStart('\', '/')
    $pathParts    = $relativePath -split '[/\\]'

    # Skip if inside an ignored directory
    $skipDueToDir = $false
    foreach ($part in $pathParts[0..($pathParts.Count - 2)]) {
        if ($ignoredDirs -contains $part.ToLower()) {
            $skipDueToDir = $true
            break
        }
    }
    if ($skipDueToDir) { $skipped++; continue }

    # Skip ignored filenames
    if ($ignoredFiles -contains $file.Name) { $skipped++; continue }

    # Skip ignored extensions
    $skipExt = $false
    foreach ($ignored in $ignoredExtensions) {
        if ($file.Name.ToLower().EndsWith($ignored)) { $skipExt = $true; break }
    }
    if ($skipExt) { $skipped++; continue }

    # Skip oversized files
    $sizeKB = $file.Length / 1KB
    if ($sizeKB -gt $MaxFileSizeKB) {
        $lines.Add("-- $relativePath")
        $lines.Add("   [SKIPPED: file too large ($([Math]::Round($sizeKB))KB > ${MaxFileSizeKB}KB)]")
        $lines.Add("")
        $skipped++
        continue
    }

    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop

        # Binary sniff
        if ($null -ne $content -and $content.Length -gt 0) {
            $sample       = $content.Substring(0, [Math]::Min(1000, $content.Length))
            $nonPrintable = ($sample.ToCharArray() | Where-Object { [int]$_ -lt 9 -or ([int]$_ -gt 13 -and [int]$_ -lt 32) }).Count
            if (($nonPrintable / $sample.Length) -gt 0.15) {
                $lines.Add("-- $relativePath")
                $lines.Add("   [SKIPPED: binary file]")
                $lines.Add("")
                $skipped++
                continue
            }
        }

        $lines.Add("-- $relativePath")
        $lines.Add("   Size: $([Math]::Round($sizeKB, 1))KB | Last modified: $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))")
        $lines.Add("")

        if ([string]::IsNullOrWhiteSpace($content)) {
            $lines.Add("   [empty file]")
        } else {
            $lines.Add($content.TrimEnd())
        }

        $lines.Add("")
        $lines.Add("-" * 60)
        $lines.Add("")
        $included++
    }
    catch {
        $lines.Add("-- $relativePath")
        $lines.Add("   [SKIPPED: could not read - $($_.Exception.Message)]")
        $lines.Add("")
        $skipped++
    }
}

$lines.Add("=" * 80)
$lines.Add("END OF PROJECT DUMP")
$lines.Add("Files included: $included | Files skipped: $skipped")
$lines.Add("=" * 80)

$result = $lines -join "`r`n"

if (-not $NoClip) {
    $result | Set-Clipboard
    Write-Host "Copied to clipboard -- $included files included, $skipped skipped" -ForegroundColor Green
    Write-Host "  Root: $rootPath" -ForegroundColor DarkGray
    Write-Host "  Total size: $([Math]::Round($result.Length / 1KB, 1))KB" -ForegroundColor DarkGray
} else {
    Write-Output $result
}