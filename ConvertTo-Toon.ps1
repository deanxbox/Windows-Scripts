# ConvertTo-Toon.ps1
# Converts JSON files to TOON with bounded-memory streaming and parallel file workers.

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias("FullName", "LiteralPath")]
    [string]$Path,

    [switch]$Recurse,

    [string]$OutputDirectory,

    [switch]$Force,

    [ValidateRange(0, 64)]
    [int]$ThrottleLimit = 0
)

begin {
    function Get-NormalizedFullPath {
        param(
            [Parameter(Mandatory)]
            [string]$InputPath
        )

        if ([System.IO.Path]::IsPathFullyQualified($InputPath)) {
            return [System.IO.Path]::GetFullPath($InputPath)
        }

        return [System.IO.Path]::GetFullPath($InputPath, (Get-Location).Path)
    }

    function Test-PathWithinRoot {
        param(
            [Parameter(Mandatory)]
            [string]$CandidatePath,

            [Parameter(Mandatory)]
            [string]$RootPath
        )

        $normalizedCandidate = (Get-NormalizedFullPath -InputPath $CandidatePath).
            TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $normalizedRoot = (Get-NormalizedFullPath -InputPath $RootPath).
            TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

        if ($normalizedCandidate.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
        return $normalizedCandidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    }

    function Get-JsonSourceFile {
        param(
            [Parameter(Mandatory)]
            [System.IO.FileSystemInfo]$InputItem,

            [switch]$IncludeDescendants,

            [string]$ExcludedRoot
        )

        if (-not $InputItem.PSIsContainer) {
            return @($InputItem)
        }

        $parameters = @{
            LiteralPath = $InputItem.FullName
            Filter      = "*.json"
            File        = $true
        }

        if ($IncludeDescendants) {
            $parameters.Recurse = $true
        }

        $files = @(Get-ChildItem @parameters)
        if ($ExcludedRoot) {
            $files = @(
                $files | Where-Object {
                    -not (Test-PathWithinRoot -CandidatePath $_.FullName -RootPath $ExcludedRoot)
                }
            )
        }

        return @($files | Sort-Object FullName)
    }

    function Get-ToonDestinationPath {
        param(
            [Parameter(Mandatory)]
            [System.IO.FileInfo]$SourceFile,

            [Parameter(Mandatory)]
            [System.IO.FileSystemInfo]$InputItem,

            [string]$DestinationRoot
        )

        $toonName = [System.IO.Path]::ChangeExtension($SourceFile.Name, ".toon")
        if (-not $DestinationRoot) {
            return Join-Path $SourceFile.DirectoryName $toonName
        }

        if (-not $InputItem.PSIsContainer) {
            return Join-Path $DestinationRoot $toonName
        }

        $relativeSourcePath = [System.IO.Path]::GetRelativePath($InputItem.FullName, $SourceFile.FullName)
        $relativeDirectory = [System.IO.Path]::GetDirectoryName($relativeSourcePath)
        if ([string]::IsNullOrEmpty($relativeDirectory)) {
            return Join-Path $DestinationRoot $toonName
        }

        return Join-Path (Join-Path $DestinationRoot $relativeDirectory) $toonName
    }

    function Get-ToonCliCommand {
        $localBin = Join-Path $PSScriptRoot "node_modules\.bin"
        $localCandidates = @(
            (Join-Path $localBin "toon.ps1"),
            (Join-Path $localBin "toon.cmd"),
            (Join-Path $localBin "toon.exe")
        )

        foreach ($candidate in $localCandidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [pscustomobject]@{
                    Executable      = $candidate
                    PrefixArguments = [string[]]@()
                    Mode            = "Local"
                }
            }
        }

        $npxCommand = Get-Command "npx" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($npxCommand) {
            return [pscustomobject]@{
                Executable      = $npxCommand.Source
                PrefixArguments = [string[]]@("--yes", "@toon-format/cli@4.1.1")
                Mode            = "NpxFallback"
            }
        }

        throw "No TOON CLI was found. Run 'npm install' in $PSScriptRoot, or install Node.js/npm with npx on PATH."
    }

    $workerScript = {
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$WorkItem,

            [Parameter(Mandatory)]
            [string]$Executable,

            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [string[]]$PrefixArguments,

            [Parameter(Mandatory)]
            [bool]$AllowOverwrite
        )

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $succeeded = $false
        $errorMessage = ""

        try {
            $parentDirectory = [System.IO.Path]::GetDirectoryName($WorkItem.DestinationPath)
            if (-not [System.IO.Directory]::Exists($parentDirectory)) {
                [System.IO.Directory]::CreateDirectory($parentDirectory) | Out-Null
            }

            $arguments = [System.Collections.Generic.List[string]]::new()
            foreach ($prefixArgument in $PrefixArguments) {
                $arguments.Add($prefixArgument)
            }
            $arguments.Add($WorkItem.SourcePath)
            $arguments.Add("-o")
            $arguments.Add($WorkItem.TemporaryPath)

            $argumentArray = $arguments.ToArray()
            $cliOutput = & $Executable @argumentArray 2>&1 | Out-String
            $cliExitCode = $LASTEXITCODE

            if ($cliExitCode -ne 0) {
                $message = $cliOutput.Trim()
                if (-not $message) {
                    $message = "The TOON CLI exited with code $cliExitCode."
                }

                throw $message
            }

            if (-not [System.IO.File]::Exists($WorkItem.TemporaryPath)) {
                throw "The TOON CLI did not create the expected temporary output file: $($WorkItem.TemporaryPath)"
            }

            if ([System.IO.File]::Exists($WorkItem.DestinationPath)) {
                if (-not $AllowOverwrite) {
                    throw "Destination already exists. Use -Force to replace it: $($WorkItem.DestinationPath)"
                }

                [System.IO.File]::Move($WorkItem.TemporaryPath, $WorkItem.DestinationPath, $true)
            }
            else {
                [System.IO.File]::Move($WorkItem.TemporaryPath, $WorkItem.DestinationPath)
            }

            $succeeded = $true
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        finally {
            $stopwatch.Stop()
            if ([System.IO.File]::Exists($WorkItem.TemporaryPath)) {
                [System.IO.File]::Delete($WorkItem.TemporaryPath)
            }
        }

        [pscustomobject]@{
            Index                = $WorkItem.Index
            SourcePath           = $WorkItem.SourcePath
            DestinationPath      = $WorkItem.DestinationPath
            Succeeded            = $succeeded
            Error                = $errorMessage
            DurationMilliseconds = [long][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        }
    }
}

process {
    $resolvedInput = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolvedInput) {
        throw "Path does not exist: $Path"
    }

    $inputItem = Get-Item -LiteralPath $resolvedInput.Path
    if (-not $inputItem.PSIsContainer -and
        -not $inputItem.Extension.Equals(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Input file must have a .json extension: $($inputItem.FullName)"
    }

    $cliCommand = Get-ToonCliCommand
    $destinationRoot = if ($OutputDirectory) {
        Get-NormalizedFullPath -InputPath $OutputDirectory
    }
    else {
        $null
    }

    $excludedRoot = if ($inputItem.PSIsContainer -and
        $destinationRoot -and
        (Test-PathWithinRoot -CandidatePath $destinationRoot -RootPath $inputItem.FullName)) {
        $destinationRoot
    }
    else {
        $null
    }

    $sourceFiles = @(
        Get-JsonSourceFile -InputItem $inputItem -IncludeDescendants:$Recurse -ExcludedRoot $excludedRoot
    )

    if ($sourceFiles.Count -eq 0) {
        throw "No JSON files were found in: $($inputItem.FullName)"
    }

    $workItems = for ($index = 0; $index -lt $sourceFiles.Count; $index++) {
        $sourceFile = $sourceFiles[$index]
        $destinationPath = Get-ToonDestinationPath `
            -SourceFile $sourceFile `
            -InputItem $inputItem `
            -DestinationRoot $destinationRoot
        $temporaryName = ".{0}.{1}.tmp" -f [System.IO.Path]::GetFileName($destinationPath), [guid]::NewGuid().ToString("N")

        [pscustomobject]@{
            Index           = $index
            SourcePath      = $sourceFile.FullName
            DestinationPath = $destinationPath
            TemporaryPath   = Join-Path ([System.IO.Path]::GetDirectoryName($destinationPath)) $temporaryName
        }
    }

    $duplicateDestinations = @(
        $workItems |
            Group-Object { $_.DestinationPath.ToUpperInvariant() } |
            Where-Object Count -gt 1
    )
    if ($duplicateDestinations.Count -gt 0) {
        $paths = $duplicateDestinations |
            ForEach-Object { $_.Group[0].DestinationPath } |
            Sort-Object
        throw "Multiple JSON files map to the same TOON destination: $($paths -join ', ')"
    }

    $processorCount = [System.Environment]::ProcessorCount
    $effectiveThrottle = if ($ThrottleLimit -eq 0) {
        [Math]::Max(1, [Math]::Min($sourceFiles.Count, [Math]::Min($processorCount, 8)))
    }
    else {
        [Math]::Min($ThrottleLimit, $sourceFiles.Count)
    }

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $effectiveThrottle)
    $runspacePool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()

    try {
        foreach ($workItem in $workItems) {
            $powerShell = [powershell]::Create()
            $powerShell.RunspacePool = $runspacePool
            [void]$powerShell.AddScript($workerScript).
                AddArgument($workItem).
                AddArgument($cliCommand.Executable).
                AddArgument([string[]]$cliCommand.PrefixArguments).
                AddArgument([bool]$Force)

            $jobs.Add([pscustomobject]@{
                PowerShell = $powerShell
                Handle     = $powerShell.BeginInvoke()
                WorkItem   = $workItem
            })
        }

        $results = foreach ($job in $jobs) {
            try {
                $workerOutput = @($job.PowerShell.EndInvoke($job.Handle))
                if ($workerOutput.Count -eq 0) {
                    [pscustomobject]@{
                        Index                = $job.WorkItem.Index
                        SourcePath           = $job.WorkItem.SourcePath
                        DestinationPath      = $job.WorkItem.DestinationPath
                        Succeeded            = $false
                        Error                = "The conversion worker returned no result."
                        DurationMilliseconds = 0L
                    }
                }
                else {
                    $workerOutput[-1]
                }
            }
            catch {
                [pscustomobject]@{
                    Index                = $job.WorkItem.Index
                    SourcePath           = $job.WorkItem.SourcePath
                    DestinationPath      = $job.WorkItem.DestinationPath
                    Succeeded            = $false
                    Error                = $_.Exception.Message
                    DurationMilliseconds = 0L
                }
            }
            finally {
                $job.PowerShell.Dispose()
            }
        }
    }
    finally {
        $runspacePool.Close()
        $runspacePool.Dispose()
    }

    $orderedResults = @($results | Sort-Object Index)
    $hadFailure = $false
    foreach ($result in $orderedResults) {
        if (-not $result.Succeeded) {
            $hadFailure = $true
        }

        [pscustomobject]@{
            SourcePath           = $result.SourcePath
            DestinationPath      = $result.DestinationPath
            Succeeded            = $result.Succeeded
            Error                = $result.Error
            DurationMilliseconds = $result.DurationMilliseconds
        }
    }

    if ($hadFailure) {
        exit 1
    }
}
