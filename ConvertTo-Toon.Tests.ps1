BeforeAll {
    $script:ConverterSourcePath = Join-Path $PSScriptRoot "ConvertTo-Toon.ps1"
    $script:PowerShellPath = Join-Path $PSHOME "pwsh.exe"

    function ConvertTo-SingleQuotedPowerShellLiteral {
        param([Parameter(Mandatory)][string]$Value)

        return "'" + $Value.Replace("'", "''") + "'"
    }

    function Invoke-ConverterProcess {
        param(
            [Parameter(Mandatory)][string]$Path,
            [switch]$Recurse,
            [string]$OutputDirectory,
            [switch]$Force,
            [int]$ThrottleLimit = -1,
            [string]$FakeMode = "Success",
            [switch]$WithoutNpx,
            [switch]$UseLocalCli
        )

        $arguments = @(
            "-Path", (ConvertTo-SingleQuotedPowerShellLiteral $Path)
        )

        if ($Recurse) {
            $arguments += "-Recurse"
        }

        if ($OutputDirectory) {
            $arguments += @(
                "-OutputDirectory",
                (ConvertTo-SingleQuotedPowerShellLiteral $OutputDirectory)
            )
        }

        if ($Force) {
            $arguments += "-Force"
        }

        if ($ThrottleLimit -ge 0) {
            $arguments += @("-ThrottleLimit", $ThrottleLimit)
        }

        $scriptLiteral = ConvertTo-SingleQuotedPowerShellLiteral $script:ConverterPath
        $command = "& $scriptLiteral $($arguments -join ' ') | ForEach-Object { `$_ | ConvertTo-Json -Compress }"
        $originalPath = $env:PATH
        $originalMode = $env:TOON_FAKE_MODE
        $originalLogDirectory = $env:TOON_FAKE_LOG_DIRECTORY

        try {
            $env:TOON_FAKE_MODE = $FakeMode
            $env:TOON_FAKE_LOG_DIRECTORY = $script:FakeLogDirectory

            if ($UseLocalCli) {
                $localBin = Join-Path $script:TestScriptRoot "node_modules\.bin"
                New-Item -ItemType Directory -Path $localBin -Force | Out-Null
                Copy-Item `
                    -LiteralPath (Join-Path $script:FakeBinDirectory "fake-toon.ps1") `
                    -Destination (Join-Path $localBin "fake-toon.ps1") `
                    -Force
                @'
@echo off
set "TOON_FAKE_ACTUAL_MODE=Local"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-toon.ps1" %*
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $localBin "toon.cmd") -Encoding ascii
                @'
$env:TOON_FAKE_ACTUAL_MODE = 'Local'
& (Join-Path $PSScriptRoot 'fake-toon.ps1') @args
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath (Join-Path $localBin "toon.ps1") -Encoding utf8NoBOM
            }

            if ($WithoutNpx) {
                $env:PATH = $script:EmptyPathDirectory
            }
            else {
                $env:PATH = "$($script:FakeBinDirectory);$originalPath"
            }

            $output = & $script:PowerShellPath -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = @($output)
            }
        }
        finally {
            $env:PATH = $originalPath
            $env:TOON_FAKE_MODE = $originalMode
            $env:TOON_FAKE_LOG_DIRECTORY = $originalLogDirectory
        }
    }

    function Get-FakeCliInterval {
        param([Parameter(Mandatory)][string]$Name)

        [pscustomobject]@{
            Start = [long](Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "$Name.start"))
            End   = [long](Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "$Name.end"))
        }
    }
}

Describe "ConvertTo-Toon.ps1" {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("toon-test-" + [guid]::NewGuid().ToString("N"))
        $script:TestScriptRoot = Join-Path $script:TestRoot "script-root"
        $script:FakeBinDirectory = Join-Path $script:TestRoot "fake bin"
        $script:FakeLogDirectory = Join-Path $script:TestRoot "fake logs"
        $script:EmptyPathDirectory = Join-Path $script:TestRoot "empty-bin"
        $script:ConverterPath = Join-Path $script:TestScriptRoot "ConvertTo-Toon.ps1"

        New-Item -ItemType Directory -Path `
            $script:TestScriptRoot, `
            $script:FakeBinDirectory, `
            $script:FakeLogDirectory, `
            $script:EmptyPathDirectory | Out-Null
        Copy-Item -LiteralPath $script:ConverterSourcePath -Destination $script:ConverterPath

        @'
$outputIndex = [Array]::IndexOf($args, '-o')
if ($outputIndex -lt 0 -or $outputIndex + 1 -ge $args.Count) {
    [Console]::Error.WriteLine('Missing output argument.')
    exit 9
}

$source = $args[$outputIndex - 1]
$destination = $args[$outputIndex + 1]
$name = [System.IO.Path]::GetFileNameWithoutExtension($source)
$logDirectory = $env:TOON_FAKE_LOG_DIRECTORY

Set-Content -LiteralPath (Join-Path $logDirectory "$name.start") -Value ([DateTime]::UtcNow.Ticks)
Set-Content -LiteralPath (Join-Path $logDirectory "$name.mode") -Value $env:TOON_FAKE_ACTUAL_MODE
$args | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $logDirectory "$name.args")

try {
    if ($name -like '*slow*') {
        Start-Sleep -Milliseconds 700
    }
    elseif ($name -like '*fast*') {
        Start-Sleep -Milliseconds 50
    }
    else {
        Start-Sleep -Milliseconds 250
    }

    if ($env:TOON_FAKE_MODE -eq 'Failure' -or $name -like '*fail*') {
        Write-Output "Fake TOON conversion failed for $name."
        exit 7
    }

    if ($env:TOON_FAKE_MODE -eq 'NoOutput') {
        exit 0
    }

    Set-Content -LiteralPath $destination -Value "converted: $name" -Encoding utf8NoBOM
    exit 0
}
finally {
    Set-Content -LiteralPath (Join-Path $logDirectory "$name.end") -Value ([DateTime]::UtcNow.Ticks)
}
'@ | Set-Content -LiteralPath (Join-Path $script:FakeBinDirectory "fake-toon.ps1") -Encoding utf8NoBOM

        @'
@echo off
set "TOON_FAKE_ACTUAL_MODE=Fallback"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-toon.ps1" %*
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $script:FakeBinDirectory "npx.cmd") -Encoding ascii
    }

    AfterEach {
        if ($script:TestRoot -and
            (Test-Path -LiteralPath $script:TestRoot) -and
            $script:TestRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It "converts a JSON file beside the source, including paths with spaces" {
        $sourceDirectory = Join-Path $script:TestRoot "source files"
        $sourcePath = Join-Path $sourceDirectory "sample data.json"
        New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
        Set-Content -LiteralPath $sourcePath -Value '{"name":"Ada"}'

        $process = Invoke-ConverterProcess -Path $sourcePath
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 0
        $result.Succeeded | Should -BeTrue
        $result.SourcePath | Should -Be (Resolve-Path -LiteralPath $sourcePath).Path
        $result.DestinationPath | Should -Be (Join-Path $sourceDirectory "sample data.toon")
        Test-Path -LiteralPath $result.DestinationPath | Should -BeTrue
    }

    It "discovers only top-level JSON files without Recurse" {
        $nested = Join-Path $script:TestRoot "nested"
        New-Item -ItemType Directory -Path $nested | Out-Null
        Set-Content -LiteralPath (Join-Path $script:TestRoot "top.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $nested "nested.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $script:TestRoot
        $results = @($process.Output | ConvertFrom-Json)

        $process.ExitCode | Should -Be 0
        $results.Count | Should -Be 1
        $results[0].SourcePath | Should -Be (Join-Path $script:TestRoot "top.json")
    }

    It "discovers nested JSON files with Recurse" {
        $nested = Join-Path $script:TestRoot "nested"
        New-Item -ItemType Directory -Path $nested | Out-Null
        Set-Content -LiteralPath (Join-Path $script:TestRoot "top.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $nested "nested.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $script:TestRoot -Recurse
        $results = @($process.Output | ConvertFrom-Json)

        $process.ExitCode | Should -Be 0
        $results.Count | Should -Be 2
    }

    It "preserves relative directories beneath OutputDirectory" {
        $inputRoot = Join-Path $script:TestRoot "input"
        $nested = Join-Path $inputRoot "nested"
        $outputRoot = Join-Path $script:TestRoot "output"
        New-Item -ItemType Directory -Path $nested | Out-Null
        Set-Content -LiteralPath (Join-Path $nested "item.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $inputRoot -Recurse -OutputDirectory $outputRoot
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 0
        $result.DestinationPath | Should -Be (Join-Path $outputRoot "nested\item.toon")
        Test-Path -LiteralPath $result.DestinationPath | Should -BeTrue
    }

    It "allows OutputDirectory to equal the input directory" {
        $sourcePath = Join-Path $script:TestRoot "item.json"
        Set-Content -LiteralPath $sourcePath -Value '{}'

        $process = Invoke-ConverterProcess -Path $script:TestRoot -OutputDirectory $script:TestRoot
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 0
        $result.Succeeded | Should -BeTrue
        $result.DestinationPath | Should -Be (Join-Path $script:TestRoot "item.toon")
    }

    It "excludes JSON files already inside a nested OutputDirectory" {
        $outputRoot = Join-Path $script:TestRoot "toon-output"
        New-Item -ItemType Directory -Path $outputRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $script:TestRoot "source.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $outputRoot "old.json") -Value '{}'

        $process = Invoke-ConverterProcess `
            -Path $script:TestRoot `
            -Recurse `
            -OutputDirectory $outputRoot
        $results = @($process.Output | ConvertFrom-Json)

        $process.ExitCode | Should -Be 0
        $results.Count | Should -Be 1
        $results[0].SourcePath | Should -Be (Join-Path $script:TestRoot "source.json")
    }

    It "rejects a missing input path" {
        $process = Invoke-ConverterProcess -Path (Join-Path $script:TestRoot "missing.json")

        $process.ExitCode | Should -Not -Be 0
        ($process.Output -join "`n") | Should -Match "Path does not exist"
    }

    It "rejects a non-JSON file input" {
        $sourcePath = Join-Path $script:TestRoot "notes.txt"
        Set-Content -LiteralPath $sourcePath -Value "text"

        $process = Invoke-ConverterProcess -Path $sourcePath

        $process.ExitCode | Should -Not -Be 0
        ($process.Output -join "`n") | Should -Match "must have a .json extension"
    }

    It "rejects a directory containing no JSON files" {
        $process = Invoke-ConverterProcess -Path $script:TestRoot

        $process.ExitCode | Should -Not -Be 0
        ($process.Output -join "`n") | Should -Match "No JSON files were found"
    }

    It "rejects conversion when npx is unavailable" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        Set-Content -LiteralPath $sourcePath -Value '{}'

        $process = Invoke-ConverterProcess -Path $sourcePath -WithoutNpx

        $process.ExitCode | Should -Not -Be 0
        ($process.Output -join "`n") | Should -Match "No TOON CLI was found"
    }

    It "does not overwrite an existing destination without Force" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        $destinationPath = Join-Path $script:TestRoot "sample.toon"
        Set-Content -LiteralPath $sourcePath -Value '{}'
        Set-Content -LiteralPath $destinationPath -Value 'original'

        $process = Invoke-ConverterProcess -Path $sourcePath
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 1
        $result.Succeeded | Should -BeFalse
        $result.Error | Should -Match "already exists"
        Get-Content -LiteralPath $destinationPath -Raw | Should -Match "original"
    }

    It "overwrites an existing destination with Force" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        $destinationPath = Join-Path $script:TestRoot "sample.toon"
        Set-Content -LiteralPath $sourcePath -Value '{}'
        Set-Content -LiteralPath $destinationPath -Value 'original'

        $process = Invoke-ConverterProcess -Path $sourcePath -Force
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 0
        $result.Succeeded | Should -BeTrue
        Get-Content -LiteralPath $destinationPath -Raw | Should -Match "converted"
    }

    It "reports a CLI failure as a structured failed result" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        Set-Content -LiteralPath $sourcePath -Value '{}'

        $process = Invoke-ConverterProcess -Path $sourcePath -FakeMode Failure
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 1
        $result.Succeeded | Should -BeFalse
        $result.Error | Should -Match "Fake TOON conversion failed"
    }

    It "reports success without output creation as a failed result" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        Set-Content -LiteralPath $sourcePath -Value '{}'

        $process = Invoke-ConverterProcess -Path $sourcePath -FakeMode NoOutput
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 1
        $result.Succeeded | Should -BeFalse
        $result.Error | Should -Match "did not create"
    }

    It "runs conversions sequentially with ThrottleLimit 1" {
        $inputRoot = Join-Path $script:TestRoot "input"
        New-Item -ItemType Directory -Path $inputRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $inputRoot "first.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $inputRoot "second.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $inputRoot -ThrottleLimit 1
        $first = Get-FakeCliInterval -Name "first"
        $second = Get-FakeCliInterval -Name "second"

        $process.ExitCode | Should -Be 0
        (($first.End -le $second.Start) -or ($second.End -le $first.Start)) | Should -BeTrue
    }

    It "runs conversions concurrently with ThrottleLimit 2" {
        $inputRoot = Join-Path $script:TestRoot "input"
        New-Item -ItemType Directory -Path $inputRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $inputRoot "first.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $inputRoot "second.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $inputRoot -ThrottleLimit 2
        $first = Get-FakeCliInterval -Name "first"
        $second = Get-FakeCliInterval -Name "second"

        $process.ExitCode | Should -Be 0
        (($first.Start -lt $second.End) -and ($second.Start -lt $first.End)) | Should -BeTrue
    }

    It "uses automatic parallelism when multiple files are available" {
        $inputRoot = Join-Path $script:TestRoot "input"
        New-Item -ItemType Directory -Path $inputRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $inputRoot "first.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $inputRoot "second.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $inputRoot
        $first = Get-FakeCliInterval -Name "first"
        $second = Get-FakeCliInterval -Name "second"

        $process.ExitCode | Should -Be 0
        (($first.Start -lt $second.End) -and ($second.Start -lt $first.End)) | Should -BeTrue
    }

    It "returns parallel results in source discovery order" {
        $inputRoot = Join-Path $script:TestRoot "input"
        New-Item -ItemType Directory -Path $inputRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $inputRoot "a-slow.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $inputRoot "b-fast.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $inputRoot -ThrottleLimit 2
        $results = @($process.Output | ConvertFrom-Json)

        $process.ExitCode | Should -Be 0
        $results[0].SourcePath | Should -Be (Join-Path $inputRoot "a-slow.json")
        $results[1].SourcePath | Should -Be (Join-Path $inputRoot "b-fast.json")
    }

    It "publishes through a temporary destination and removes it after success" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        Set-Content -LiteralPath $sourcePath -Value '{}'

        $process = Invoke-ConverterProcess -Path $sourcePath
        $result = $process.Output | ConvertFrom-Json
        $arguments = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "sample.args") -Raw |
            ConvertFrom-Json
        $outputIndex = [Array]::IndexOf([object[]]$arguments, "-o")
        $cliDestination = $arguments[$outputIndex + 1]

        $process.ExitCode | Should -Be 0
        $cliDestination | Should -Not -Be $result.DestinationPath
        $cliDestination | Should -Match "\.tmp$"
        Test-Path -LiteralPath $result.DestinationPath | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:TestRoot -Filter "*.tmp" -Recurse).Count | Should -Be 0
    }

    It "preserves an existing destination when forced conversion fails" {
        $sourcePath = Join-Path $script:TestRoot "fail.json"
        $destinationPath = Join-Path $script:TestRoot "fail.toon"
        Set-Content -LiteralPath $sourcePath -Value '{}'
        Set-Content -LiteralPath $destinationPath -Value 'original'

        $process = Invoke-ConverterProcess -Path $sourcePath -Force
        $result = $process.Output | ConvertFrom-Json

        $process.ExitCode | Should -Be 1
        $result.Succeeded | Should -BeFalse
        Get-Content -LiteralPath $destinationPath -Raw | Should -Match "original"
        @(Get-ChildItem -LiteralPath $script:TestRoot -Filter "*.tmp" -Recurse).Count | Should -Be 0
    }

    It "prefers the repository-local TOON executable" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        Set-Content -LiteralPath $sourcePath -Value '{}'

        $process = Invoke-ConverterProcess -Path $sourcePath -UseLocalCli

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        (Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "sample.mode")) | Should -Be "Local"
    }

    It "uses npx fallback when the local executable is absent" {
        $sourcePath = Join-Path $script:TestRoot "sample.json"
        Set-Content -LiteralPath $sourcePath -Value '{}'

        $process = Invoke-ConverterProcess -Path $sourcePath
        $arguments = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "sample.args") -Raw |
            ConvertFrom-Json

        $process.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "sample.mode")) | Should -Be "Fallback"
        $arguments[0] | Should -Be "--yes"
        $arguments[1] | Should -Be "@toon-format/cli@4.1.1"
    }

    It "reports timing and independent failures for parallel work" {
        $inputRoot = Join-Path $script:TestRoot "input"
        New-Item -ItemType Directory -Path $inputRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $inputRoot "a-fail.json") -Value '{}'
        Set-Content -LiteralPath (Join-Path $inputRoot "b-fail.json") -Value '{}'

        $process = Invoke-ConverterProcess -Path $inputRoot -ThrottleLimit 2
        $results = @($process.Output | ConvertFrom-Json)

        $process.ExitCode | Should -Be 1
        $results.Count | Should -Be 2
        @($results | Where-Object { -not $_.Succeeded }).Count | Should -Be 2
        @($results | Where-Object { $_.DurationMilliseconds -ge 0 }).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $script:TestRoot -Filter "*.tmp" -Recurse).Count | Should -Be 0
    }
}
