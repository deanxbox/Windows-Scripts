# Compress-Item.ps1
# Compresses files or directories with 7-Zip, Zstandard, and Windows bsdtar.
# Level maps to each format's native level: Fastest, Fast, Normal, Max, or Ultra.
# Numeric levels are 1/3/5/7/9 for zip, 7z, and gzip; 1/3/9/19/22 for zstd; 0/1/5/7/9 for xz.

[CmdletBinding(SupportsShouldProcess = $true)]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias("FullName", "LiteralPath")]
    [ValidateNotNullOrEmpty()]
    [string[]]$Path,

    [string]$Destination,

    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [ValidateSet("zip", "7z", "zstd", "tar.zst", "tar.gz", "tar.xz")]
    [string]$Format = "zip",

    [ValidateSet("Fastest", "Fast", "Normal", "Max", "Ultra")]
    [string]$Level = "Normal",

    [ValidateRange(0, 1024)]
    [int]$Threads = 0
)

begin {
    $inputPaths = [System.Collections.Generic.List[string]]::new()
    $canPrompt = [Environment]::UserInteractive -and
        $null -ne $Host.UI -and
        -not [Console]::IsInputRedirected -and
        -not ([Environment]::GetCommandLineArgs() -contains "-NonInteractive") -and
        -not $PSBoundParameters.ContainsKey("WhatIf") -and
        -not ($PSBoundParameters.ContainsKey("Confirm") -and -not $PSBoundParameters["Confirm"])

    if ($canPrompt -and -not $PSBoundParameters.ContainsKey("Format")) {
        $formats = @("zip", "7z", "zstd", "tar.zst", "tar.gz", "tar.xz")
        Write-Host "Select archive format:"
        for ($index = 0; $index -lt $formats.Count; $index++) {
            Write-Host ("  {0}. {1}" -f ($index + 1), $formats[$index])
        }

        $formatChoice = Read-Host "Format [1: zip]"
        if (-not [string]::IsNullOrWhiteSpace($formatChoice)) {
            $formatIndex = 0
            if (-not [int]::TryParse($formatChoice, [ref]$formatIndex) -or
                $formatIndex -lt 1 -or
                $formatIndex -gt $formats.Count) {
                throw "Format selection must be a number from 1 to $($formats.Count)."
            }
           $Format = $formats[$formatIndex - 1]
       }
   }

    if ($canPrompt -and -not $PSBoundParameters.ContainsKey("Level")) {
        $levels = @("Fastest", "Fast", "Normal", "Max", "Ultra")
        Write-Host "Select compression level:"
        for ($index = 0; $index -lt $levels.Count; $index++) {
            Write-Host ("  {0}. {1}" -f ($index + 1), $levels[$index])
        }
        $levelChoice = Read-Host "Level [3: Normal]"
        if (-not [string]::IsNullOrWhiteSpace($levelChoice)) {
            $levelIndex = 0
            if (-not [int]::TryParse($levelChoice, [ref]$levelIndex) -or
                $levelIndex -lt 1 -or
                $levelIndex -gt $levels.Count) {
                throw "Level selection must be a number from 1 to $($levels.Count)."
            }
            $Level = $levels[$levelIndex - 1]
        }
    }

    function Get-NormalizedFullPath {
        param([Parameter(Mandatory)][string]$InputPath)

        if ([System.IO.Path]::IsPathFullyQualified($InputPath)) {
            return [System.IO.Path]::GetFullPath($InputPath)
        }

        return [System.IO.Path]::GetFullPath($InputPath, (Get-Location).Path)
    }

    function Get-InputSize {
        param([Parameter(Mandatory)][System.IO.FileSystemInfo[]]$Items)

        $bytes = 0L
        foreach ($item in $Items) {
            if ($item.PSIsContainer) {
                $bytes += (Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force -ErrorAction Stop |
                    Measure-Object -Property Length -Sum).Sum
            }
            else {
                $bytes += $item.Length
            }
        }

        return $bytes
    }

    function Format-ByteSize {
        param([Parameter(Mandatory)][long]$Bytes)

        if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
        if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
        if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
        return "$Bytes B"
    }

    function Get-CompressionProcessUsage {
        param(
            [Parameter(Mandatory)][System.Diagnostics.Process[]]$Processes,
            [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
            [Parameter(Mandatory)][ref]$LastSampleMilliseconds,
            [Parameter(Mandatory)][ref]$LastCpuTicks,
            [Parameter(Mandatory)][ref]$CurrentOperation
        )

        $elapsedMilliseconds = $Stopwatch.Elapsed.TotalMilliseconds
        if ($elapsedMilliseconds - $LastSampleMilliseconds.Value -lt 500) {
            return
        }

        $cpuTicks = 0L
        $memoryBytes = 0L
        foreach ($nativeProcess in $Processes) {
            $process = Get-Process -Id $nativeProcess.Id -ErrorAction SilentlyContinue
            if ($process) {
                $cpuTicks += $process.TotalProcessorTime.Ticks
                $memoryBytes += $process.WorkingSet64
            }
            elseif ($nativeProcess.HasExited) {
                try {
                    $cpuTicks += $nativeProcess.TotalProcessorTime.Ticks
                }
                catch {
                    Write-Verbose "Process usage was unavailable after the compression process exited."
                }
            }
        }

        $sampleMilliseconds = $elapsedMilliseconds - $LastSampleMilliseconds.Value
        $cpuPercent = if ($sampleMilliseconds -gt 0) {
            (($cpuTicks - $LastCpuTicks.Value) / [TimeSpan]::TicksPerMillisecond) /
                $sampleMilliseconds /
                [Environment]::ProcessorCount *
                100
        }
        else {
            0
        }
        $CurrentOperation.Value = "CPU: {0:N1}% | Memory: {1}" -f (
            [Math]::Max(0, $cpuPercent)
        ), (Format-ByteSize $memoryBytes)
        $LastCpuTicks.Value = $cpuTicks
        $LastSampleMilliseconds.Value = $elapsedMilliseconds
    }

    function Invoke-NativeProcess {
        param(
            [Parameter(Mandatory)][string]$Executable,
            [Parameter(Mandatory)][string[]]$Arguments,
            [string]$WorkingDirectory
        )

        $processInfo = [System.Diagnostics.ProcessStartInfo]::new($Executable)
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        if ($WorkingDirectory) {
            $processInfo.WorkingDirectory = $WorkingDirectory
        }
        foreach ($argument in $Arguments) {
            $processInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $processInfo
        $started = $false
        $output = [System.Text.StringBuilder]::new()
        $progressText = ""
        $percentComplete = -1
        $currentOperation = "CPU: 0.0% | Memory: 0 B"
        $progressStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lastProgressMilliseconds = 0.0
        $lastSampleMilliseconds = 0.0
        $lastCpuTicks = 0L

        try {
            [void]$process.Start()
            $started = $true
            $standardOutputBuffer = [char[]]::new(4096)
            $standardErrorBuffer = [char[]]::new(4096)
            $standardOutputTask = $process.StandardOutput.ReadAsync(
                $standardOutputBuffer,
                0,
                $standardOutputBuffer.Length
            )
            $standardErrorTask = $process.StandardError.ReadAsync(
                $standardErrorBuffer,
                0,
                $standardErrorBuffer.Length
            )

            Write-Progress -Activity "Compressing" -Status "Starting..." -PercentComplete 0 `
                -CurrentOperation $currentOperation

            while (-not $process.HasExited -or $standardOutputTask -or $standardErrorTask) {
                foreach ($streamName in "Output", "Error") {
                    $taskVariable = Get-Variable "standard${streamName}Task"
                    $bufferVariable = Get-Variable "standard${streamName}Buffer"
                    $readTask = $taskVariable.Value
                    if ($readTask -and $readTask.IsCompleted) {
                        $characterCount = $readTask.GetAwaiter().GetResult()
                        if ($characterCount -eq 0) {
                            $taskVariable.Value = $null
                            continue
                        }

                        $text = [string]::new($bufferVariable.Value, 0, $characterCount)
                        [void]$output.Append($text)
                        $progressText = ($progressText + $text)
                        $progressMatches = [regex]::Matches(
                            $progressText,
                            "(?<!\d)(?<Percent>\d{1,3}(?:\.\d+)?)%"
                        )
                        if ($progressMatches.Count -gt 0) {
                            $percentComplete = [Math]::Min(
                                100,
                                [double]$progressMatches[
                                    $progressMatches.Count - 1
                                ].Groups["Percent"].Value
                            )
                        }
                        if ($progressText.Length -gt 64) {
                            $progressText = $progressText.Substring($progressText.Length - 64)
                        }

                        $taskVariable.Value = if ($streamName -eq "Output") {
                            $process.StandardOutput.ReadAsync(
                                $bufferVariable.Value,
                                0,
                                $bufferVariable.Value.Length
                            )
                        }
                        else {
                            $process.StandardError.ReadAsync(
                                $bufferVariable.Value,
                                0,
                                $bufferVariable.Value.Length
                            )
                        }
                    }
                }

                if ($progressStopwatch.Elapsed.TotalMilliseconds - $lastProgressMilliseconds -ge 200) {
                    Get-CompressionProcessUsage `
                        -Processes @($process) `
                        -Stopwatch $progressStopwatch `
                        -LastSampleMilliseconds ([ref]$lastSampleMilliseconds) `
                        -LastCpuTicks ([ref]$lastCpuTicks) `
                        -CurrentOperation ([ref]$currentOperation)
                    $status = if ($percentComplete -ge 0) {
                       "{0:N1}% complete" -f $percentComplete
                   }
                   else {
                       "Working..."
                   }
                    Write-Progress -Activity "Compressing" -Status "$status ($currentOperation)" `
                        -PercentComplete $percentComplete -CurrentOperation $currentOperation
                    $lastProgressMilliseconds = $progressStopwatch.Elapsed.TotalMilliseconds
                }

                if (-not $process.HasExited -or
                    ($standardOutputTask -and -not $standardOutputTask.IsCompleted) -or
                    ($standardErrorTask -and -not $standardErrorTask.IsCompleted)) {
                    Start-Sleep -Milliseconds 50
                }
            }

            $process.WaitForExit()
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output   = $output.ToString()
            }
        }
        finally {
            Write-Progress -Activity "Compressing" -Completed
            $progressStopwatch.Stop()
            if ($started -and -not $process.HasExited) {
                try {
                    $process.Kill($true)
                }
                catch {
                    Write-Verbose "The compression process exited before cleanup completed."
                }
            }
            $process.Dispose()
        }
    }

    function Invoke-NativePipeline {
        param(
            [Parameter(Mandatory)][string]$SourceExecutable,
            [Parameter(Mandatory)][string[]]$SourceArguments,
            [Parameter(Mandatory)][string]$DestinationExecutable,
            [Parameter(Mandatory)][string[]]$DestinationArguments,
            [Parameter(Mandatory)][long]$InputBytes
        )

        $sourceInfo = [System.Diagnostics.ProcessStartInfo]::new($SourceExecutable)
        $sourceInfo.UseShellExecute = $false
        $sourceInfo.RedirectStandardOutput = $true
        $sourceInfo.RedirectStandardError = $true
        foreach ($argument in $SourceArguments) {
            $sourceInfo.ArgumentList.Add($argument)
        }

        $destinationInfo = [System.Diagnostics.ProcessStartInfo]::new($DestinationExecutable)
        $destinationInfo.UseShellExecute = $false
        $destinationInfo.RedirectStandardInput = $true
        $destinationInfo.RedirectStandardOutput = $true
        $destinationInfo.RedirectStandardError = $true
        foreach ($argument in $DestinationArguments) {
            $destinationInfo.ArgumentList.Add($argument)
        }

        $sourceProcess = [System.Diagnostics.Process]::new()
        $destinationProcess = [System.Diagnostics.Process]::new()
        $sourceProcess.StartInfo = $sourceInfo
        $destinationProcess.StartInfo = $destinationInfo
        $sourceStarted = $false
        $destinationStarted = $false
        $bytesCopied = 0L
        $currentOperation = "CPU: 0.0% | Memory: 0 B"
        $progressStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lastProgressMilliseconds = 0.0
        $lastSampleMilliseconds = 0.0
        $lastCpuTicks = 0L

        try {
            [void]$destinationProcess.Start()
            $destinationStarted = $true
            [void]$sourceProcess.Start()
            $sourceStarted = $true
            $sourceError = $sourceProcess.StandardError.ReadToEndAsync()
            $destinationOutput = $destinationProcess.StandardOutput.ReadToEndAsync()
            $destinationError = $destinationProcess.StandardError.ReadToEndAsync()

            Write-Progress -Activity "Compressing" -Status "Starting..." -PercentComplete 0 `
                -CurrentOperation $currentOperation
            $buffer = [byte[]]::new(81920)
            while (($bytesRead = $sourceProcess.StandardOutput.BaseStream.Read(
                $buffer,
                0,
                $buffer.Length
            )) -gt 0) {
                $destinationProcess.StandardInput.BaseStream.Write($buffer, 0, $bytesRead)
                $bytesCopied += $bytesRead

                if ($progressStopwatch.Elapsed.TotalMilliseconds - $lastProgressMilliseconds -ge 200) {
                    Get-CompressionProcessUsage `
                        -Processes @($sourceProcess, $destinationProcess) `
                        -Stopwatch $progressStopwatch `
                        -LastSampleMilliseconds ([ref]$lastSampleMilliseconds) `
                        -LastCpuTicks ([ref]$lastCpuTicks) `
                        -CurrentOperation ([ref]$currentOperation)
                    $percentComplete = if ($InputBytes -eq 0) {
                        0
                    }
                    else {
                        [Math]::Min(100, ($bytesCopied / $InputBytes) * 100)
                    }
                    Write-Progress -Activity "Compressing" `
                        -Status ("{0:N1}% complete ({1})" -f $percentComplete, $currentOperation) `
                        -PercentComplete $percentComplete `
                        -CurrentOperation $currentOperation
                    $lastProgressMilliseconds = $progressStopwatch.Elapsed.TotalMilliseconds
                }
            }
            Write-Progress -Activity "Compressing" -Status "100.0% complete" -PercentComplete 100 `
                -CurrentOperation $currentOperation
            try {
                $destinationProcess.StandardInput.Close()
            }
            catch [System.IO.IOException] {
                Write-Verbose "The compressor closed stdin after consuming the tar stream."
            }
            while (-not $sourceProcess.HasExited -or -not $destinationProcess.HasExited) {
                if ($progressStopwatch.Elapsed.TotalMilliseconds - $lastProgressMilliseconds -ge 200) {
                    Get-CompressionProcessUsage `
                        -Processes @($sourceProcess, $destinationProcess) `
                        -Stopwatch $progressStopwatch `
                        -LastSampleMilliseconds ([ref]$lastSampleMilliseconds) `
                        -LastCpuTicks ([ref]$lastCpuTicks) `
                        -CurrentOperation ([ref]$currentOperation)
                    Write-Progress -Activity "Compressing" -Status "Finalizing... ($currentOperation)" `
                        -PercentComplete 100 -CurrentOperation $currentOperation
                    $lastProgressMilliseconds = $progressStopwatch.Elapsed.TotalMilliseconds
                }
                Start-Sleep -Milliseconds 50
            }
            $sourceProcess.WaitForExit()
            $destinationProcess.WaitForExit()

            return [pscustomobject]@{
                SourceExitCode      = $sourceProcess.ExitCode
                DestinationExitCode = $destinationProcess.ExitCode
                Output              = $destinationOutput.GetAwaiter().GetResult()
                Error               = (@(
                    $sourceError.GetAwaiter().GetResult()
                    $destinationError.GetAwaiter().GetResult()
                ) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join [Environment]::NewLine
            }
        }
        finally {
            Write-Progress -Activity "Compressing" -Completed
            $progressStopwatch.Stop()
            if ($sourceStarted -and -not $sourceProcess.HasExited) {
                try {
                    $sourceProcess.Kill($true)
                }
                catch {
                    Write-Verbose "The tar process exited before cleanup completed."
                }
            }
            if ($destinationStarted -and -not $destinationProcess.HasExited) {
                try {
                    $destinationProcess.Kill($true)
                }
                catch {
                    Write-Verbose "The compressor process exited before cleanup completed."
                }
            }
            $sourceProcess.Dispose()
            $destinationProcess.Dispose()
        }
    }
}

process {
    foreach ($inputPath in $Path) {
        $inputPaths.Add($inputPath)
    }
}

end {
    $items = foreach ($inputPath in $inputPaths) {
        $resolvedPath = Resolve-Path -LiteralPath $inputPath -ErrorAction SilentlyContinue
        if (-not $resolvedPath) {
            throw "Path does not exist: $inputPath"
        }

        Get-Item -LiteralPath $resolvedPath.Path -Force -ErrorAction Stop
    }

    if ($items.Count -eq 0) {
        throw "At least one input path is required."
    }

    if ($items | Where-Object { $_.PSIsContainer -and -not $_.Parent }) {
        throw "Compressing a filesystem root is not supported."
    }

    if ($Format -eq "zstd" -and ($items.Count -ne 1 -or $items[0].PSIsContainer)) {
        throw "Format 'zstd' only supports one input file. Use 'tar.zst' for directories or multiple inputs."
    }

    $effectiveThreads = if ($Threads -eq 0) {
        [Math]::Max(1, [Environment]::ProcessorCount)
    }
    else {
        $Threads
    }

    $extensions = @{
        zip       = ".zip"
        "7z"      = ".7z"
        zstd      = ".zst"
        "tar.zst" = ".tar.zst"
        "tar.gz"  = ".tar.gz"
        "tar.xz"  = ".tar.xz"
    }
    $levelNumbers = @{
        zip       = @{ Fastest = 1; Fast = 3; Normal = 5; Max = 7; Ultra = 9 }
        "7z"      = @{ Fastest = 1; Fast = 3; Normal = 5; Max = 7; Ultra = 9 }
        zstd      = @{ Fastest = 1; Fast = 3; Normal = 9; Max = 19; Ultra = 22 }
        "tar.zst" = @{ Fastest = 1; Fast = 3; Normal = 9; Max = 19; Ultra = 22 }
        "tar.gz"  = @{ Fastest = 1; Fast = 3; Normal = 5; Max = 7; Ultra = 9 }
        "tar.xz"  = @{ Fastest = 0; Fast = 1; Normal = 5; Max = 7; Ultra = 9 }
    }
    $numericLevel = $levelNumbers[$Format][$Level]

    $archiveBaseName = if ($items.Count -eq 1) {
        $items[0].Name.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }
    else {
        "archive"
    }
    if (-not $archiveBaseName) {
        $archiveBaseName = "archive"
    }

    if ($canPrompt -and
        -not $PSBoundParameters.ContainsKey("Destination") -and
        -not $PSBoundParameters.ContainsKey("Name")) {
        $nameChoice = Read-Host "Output name [$archiveBaseName]"
        if (-not [string]::IsNullOrWhiteSpace($nameChoice)) {
            $Name = $nameChoice
        }
    }
    $archiveName = if ($Name) {
        $Name + $extensions[$Format]
    }
    else {
        $archiveBaseName + $extensions[$Format]
    }

    if ($Destination) {
        $destinationIsDirectory = (Test-Path -LiteralPath $Destination -PathType Container) -or
            $Destination.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or
            $Destination.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)
        $destinationPath = if ($destinationIsDirectory) {
            Join-Path (Get-NormalizedFullPath -InputPath $Destination) $archiveName
        }
        else {
            if ($PSBoundParameters.ContainsKey("Name")) {
                Write-Warning "-Name is ignored because -Destination specifies the archive file path."
            }
            Get-NormalizedFullPath -InputPath $Destination
        }
    }
    else {
        $sourceParent = if ($items[0].PSIsContainer) {
            $items[0].Parent.FullName
        }
        else {
            $items[0].DirectoryName
        }
        if (-not $sourceParent) {
            throw "A destination is required when compressing a filesystem root."
        }

        $destinationPath = Join-Path $sourceParent $archiveName
    }

    foreach ($item in $items) {
        if ($destinationPath.Equals($item.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Destination cannot overwrite an input path: $destinationPath"
        }

        if ($item.PSIsContainer) {
            $sourcePrefix = $item.FullName.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
            if ($destinationPath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Destination cannot be inside an input directory: $destinationPath"
            }
        }
    }

    if (Test-Path -LiteralPath $destinationPath) {
        throw "Destination already exists: $destinationPath"
    }

    $requiredTools = switch ($Format) {
        { $_ -in "zip", "7z" } { @("7z"); break }
        "zstd" { @("zstd"); break }
        "tar.zst" { @("tar", "zstd"); break }
        { $_ -in "tar.gz", "tar.xz" } { @("tar", "7z"); break }
    }
    $tools = @{}
    foreach ($toolName in $requiredTools) {
        $command = Get-Command $toolName -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $command) {
            throw "Required tool '$toolName' was not found on PATH for format '$Format'."
        }
        $tools[$toolName] = $command.Source
    }

    if (-not $PSCmdlet.ShouldProcess($destinationPath, "Create $Format archive")) {
        return
    }

    $destinationDirectory = [System.IO.Path]::GetDirectoryName($destinationPath)
    if (-not [System.IO.Directory]::Exists($destinationDirectory)) {
        [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    }

    $temporaryPath = Join-Path $destinationDirectory (
        ".{0}.{1}.tmp" -f [System.IO.Path]::GetFileName($destinationPath), [guid]::NewGuid().ToString("N")
    )
    $inputBytes = Get-InputSize -Items $items
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ""
    Write-Host "Compressing Items" -ForegroundColor Cyan
    Write-Host "-----------------"
    Write-Host ("  Format:  {0} ({1})" -f $Format, $Level) -ForegroundColor DarkGray
    Write-Host ("  Input:   {0} across {1} item(s)" -f (Format-ByteSize $inputBytes), $items.Count) -ForegroundColor DarkGray
    Write-Host ("  Threads: {0}" -f $effectiveThreads) -ForegroundColor DarkGray

    try {
        $toolOutput = ""
        switch ($Format) {
            { $_ -in "zip", "7z" } {
                $archiveRoot = if ($items[0].PSIsContainer) {
                    $items[0].Parent.FullName
                }
                else {
                    $items[0].DirectoryName
                }
                foreach ($item in $items) {
                    while (-not (
                        $item.FullName.Equals($archiveRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $item.FullName.StartsWith(
                            $archiveRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    )) {
                        $parent = [System.IO.Directory]::GetParent($archiveRoot)
                        if (-not $parent) {
                            break
                        }
                        $archiveRoot = $parent.FullName
                    }
                }

                $relativePaths = foreach ($item in $items) {
                    $relativePath = [System.IO.Path]::GetRelativePath($archiveRoot, $item.FullName)
                    if (-not $relativePath.StartsWith(".")) { ".\$relativePath" } else { $relativePath }
                }
                $arguments = @(
                    "a",
                    "-t$Format",
                    $temporaryPath,
                    "-mx=$numericLevel",
                    "-mmt=$effectiveThreads",
                    "-bsp1",
                    "-y"
                )
                if ($Format -eq "7z") {
                    $arguments += "-ms=on"
                }
                $arguments += $relativePaths

                $processResult = Invoke-NativeProcess `
                    -Executable $tools["7z"] `
                    -Arguments $arguments `
                    -WorkingDirectory $archiveRoot
                $toolOutput = $processResult.Output
                $exitCode = $processResult.ExitCode
                break
            }
            "zstd" {
                $arguments = @(
                    "-f",
                    "-T$effectiveThreads",
                    "--long=27",
                    "-$numericLevel",
                    $items[0].FullName,
                    "-o",
                    $temporaryPath
                )
                $processResult = Invoke-NativeProcess `
                    -Executable $tools["zstd"] `
                    -Arguments $arguments
                $toolOutput = $processResult.Output
                $exitCode = $processResult.ExitCode
                break
            }
            default {
                $tarArguments = @("-cf", "-")
                foreach ($item in $items) {
                    $parentPath = if ($item.PSIsContainer) { $item.Parent.FullName } else { $item.DirectoryName }
                    $tarArguments += @("-C", $parentPath, ".\$($item.Name)")
                }

                if ($Format -eq "tar.zst") {
                    $compressorExecutable = $tools["zstd"]
                    $compressorArguments = @(
                        "-q",
                        "-f",
                        "-T$effectiveThreads",
                        "--long=27",
                        "-$numericLevel",
                        "-o",
                        $temporaryPath
                    )
                }
                else {
                    $sevenZipType = if ($Format -eq "tar.gz") { "gzip" } else { "xz" }
                    $compressorExecutable = $tools["7z"]
                    $compressorArguments = @(
                        "a",
                        "-t$sevenZipType",
                        $temporaryPath,
                        "-si",
                        "-mx=$numericLevel",
                        "-mmt=$effectiveThreads",
                        "-bsp1",
                        "-y"
                    )
                }

                $pipelineResult = Invoke-NativePipeline `
                    -SourceExecutable $tools["tar"] `
                    -SourceArguments $tarArguments `
                    -DestinationExecutable $compressorExecutable `
                    -DestinationArguments $compressorArguments `
                    -InputBytes $inputBytes
                $toolOutput = (@($pipelineResult.Output, $pipelineResult.Error) |
                    Where-Object { $_ } |
                    ForEach-Object { $_.Trim() }) -join [Environment]::NewLine
                $exitCode = if ($pipelineResult.SourceExitCode -ne 0) {
                    $pipelineResult.SourceExitCode
                }
                else {
                    $pipelineResult.DestinationExitCode
                }
                break
            }
        }

        if ($exitCode -ne 0) {
            $message = $toolOutput.Trim()
            if (-not $message) {
                $message = "Compression tool exited with code $exitCode."
            }
            throw $message
        }

        if (-not [System.IO.File]::Exists($temporaryPath) -or
            [System.IO.FileInfo]::new($temporaryPath).Length -eq 0) {
            throw "Compression tool did not create a non-empty archive."
        }

        [System.IO.File]::Move($temporaryPath, $destinationPath)
    }
    catch {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        throw "Compression failed: $($_.Exception.Message)"
    }
    finally {
        $stopwatch.Stop()
    }

    $outputBytes = [System.IO.FileInfo]::new($destinationPath).Length
    $ratio = if ($inputBytes -eq 0) { 0 } else { [Math]::Round(($outputBytes / $inputBytes) * 100, 1) }

    Write-Host ("  Output:  {0}" -f (Format-ByteSize $outputBytes)) -ForegroundColor Green
    Write-Host ("  Ratio:   {0:N1}%" -f $ratio) -ForegroundColor Green
    Write-Host ("  Elapsed: {0:N2}s" -f $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
   Write-Host ("  Saved:   {0}" -f $destinationPath) -ForegroundColor Green
   Write-Host ""

    $replayPaths = ($items.FullName | ForEach-Object { "`"$_`"" }) -join ", "
    $replayCommand = "compressitem -Path $replayPaths -Format $Format -Level $Level -Threads $effectiveThreads -Destination `"$destinationPath`""
    Write-Host "In the future, run this command:" -ForegroundColor Cyan
    Write-Host "  $replayCommand" -ForegroundColor White
    Write-Host ""

    [pscustomobject]@{
        InputPaths     = [string[]]$items.FullName
        DestinationPath = $destinationPath
        Format          = $Format
        Level           = $Level
        Threads         = $effectiveThreads
        InputBytes      = $inputBytes
        OutputBytes     = $outputBytes
       RatioPercent    = $ratio
       ElapsedSeconds  = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        ReplayCommand   = $replayCommand
    }
}
