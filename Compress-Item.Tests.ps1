BeforeAll {
    $script:CompressSourcePath = Join-Path $PSScriptRoot "Compress-Item.ps1"
    $script:PowerShellPath = Join-Path $PSHOME "pwsh.exe"

    function ConvertTo-SingleQuotedPowerShellLiteral {
        param([Parameter(Mandatory)][string]$Value)

        return "'" + $Value.Replace("'", "''") + "'"
    }

    function Invoke-CompressProcess {
        param(
            [Parameter(Mandatory)][string[]]$Path,
            [string]$Destination,
            [string]$Name,
            [string]$Format = "zip",
            [string]$Level = "Normal",
            [int]$Threads = 4,
            [string[]]$AvailableTools = @("7z", "zstd", "tar"),
            [switch]$Pipeline
        )

        foreach ($tool in $AvailableTools) {
            $wrapper = switch ($tool) {
                "7z" {
                    @'
@echo off
> "%COMPRESS_FAKE_LOG_DIRECTORY%\7z.args" echo %*
if "%~4"=="-si" more >nul
> "%~3" echo fake archive
'@
                }
                "zstd" {
                    @'
@echo off
setlocal EnableDelayedExpansion
> "%COMPRESS_FAKE_LOG_DIRECTORY%\zstd.args" echo %*
set "output="
set "takeNext="
for %%A in (%*) do (
    if defined takeNext if not defined output set "output=%%~A"
    if "%%~A"=="-o" set "takeNext=1"
)
"%SystemRoot%\System32\more.com" > "!output!"
'@
                }
                "tar" {
                    @'
@echo off
> "%COMPRESS_FAKE_LOG_DIRECTORY%\tar.args" echo %*
echo fake tar stream
'@
                }
            }
            $wrapper | Set-Content -LiteralPath (Join-Path $script:FakeBinDirectory "$tool.cmd") -Encoding ascii
        }

        $pathLiterals = $Path | ForEach-Object { ConvertTo-SingleQuotedPowerShellLiteral $_ }
        $scriptLiteral = ConvertTo-SingleQuotedPowerShellLiteral $script:CompressPath
        $destinationArgument = if ($Destination) {
            "-Destination " + (ConvertTo-SingleQuotedPowerShellLiteral $Destination)
        }
        else {
            ""
        }
        $nameArgument = if ($Name) {
            "-Name " + (ConvertTo-SingleQuotedPowerShellLiteral $Name)
        }
        else {
            ""
        }
        $invocation = if ($Pipeline) {
            "@($($pathLiterals -join ', ')) | & $scriptLiteral -Format '$Format' -Level '$Level' -Threads $Threads $destinationArgument $nameArgument"
        }
        else {
            "& $scriptLiteral -Path @($($pathLiterals -join ', ')) -Format '$Format' -Level '$Level' -Threads $Threads $destinationArgument $nameArgument"
        }

        $command = "`$result = $invocation; `$result | ConvertTo-Json -Compress"
        $originalPath = $env:PATH
        $originalLogDirectory = $env:COMPRESS_FAKE_LOG_DIRECTORY

        try {
            $env:PATH = $script:FakeBinDirectory
            $env:COMPRESS_FAKE_LOG_DIRECTORY = $script:FakeLogDirectory
            $output = & $script:PowerShellPath -NoProfile -NonInteractive `
                -ExecutionPolicy Bypass -Command $command 2>&1
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = @($output)
                Result   = if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
                    $output[-1] | ConvertFrom-Json
                }
            }
        }
        finally {
            $env:PATH = $originalPath
            $env:COMPRESS_FAKE_LOG_DIRECTORY = $originalLogDirectory
        }
    }
}

Describe "Compress-Item.ps1" {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("compress-test-" + [guid]::NewGuid().ToString("N"))
        $script:ScriptRoot = Join-Path $script:TestRoot "script"
        $script:FakeBinDirectory = Join-Path $script:TestRoot "fake bin"
        $script:FakeLogDirectory = Join-Path $script:TestRoot "logs"
        $script:CompressPath = Join-Path $script:ScriptRoot "Compress-Item.ps1"

        New-Item -ItemType Directory -Path $script:ScriptRoot, $script:FakeBinDirectory, $script:FakeLogDirectory |
            Out-Null
        Copy-Item -LiteralPath $script:CompressSourcePath -Destination $script:CompressPath
    }

    AfterEach {
        if ($script:TestRoot -and
            (Test-Path -LiteralPath $script:TestRoot) -and
            $script:TestRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It "declares the requested parameter validation" {
        $command = Get-Command $script:CompressSourcePath

        $command.Parameters["Path"].ParameterType | Should -Be ([string[]])
        $command.Parameters["Path"].Attributes.ValueFromPipeline | Should -Contain $true
        $command.Parameters["Name"].ParameterType | Should -Be ([string])
        $command.Parameters["Format"].Attributes.ValidValues | Should -Contain "tar.zst"
        $command.Parameters["Level"].Attributes.ValidValues | Should -Be @("Fastest", "Fast", "Normal", "Max", "Ultra")
        $command.Parameters["Threads"].Attributes.MinRange | Should -Be 0
    }

    It "resolves relative input paths and destination directories" {
        $inputDirectory = Join-Path $script:TestRoot "world"
        $destinationDirectory = Join-Path $script:TestRoot "output"
        New-Item -ItemType Directory -Path $inputDirectory, $destinationDirectory | Out-Null
        Set-Content -LiteralPath (Join-Path $inputDirectory "level.dat") -Value "data"

        Push-Location $script:TestRoot
        try {
            $process = Invoke-CompressProcess -Path ".\world" -Destination $destinationDirectory -Format zip
        }
        finally {
            Pop-Location
        }

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $process.Result.InputPaths | Should -Be $inputDirectory
        $process.Result.DestinationPath | Should -Be (Join-Path $destinationDirectory "world.zip")
        Test-Path -LiteralPath $process.Result.DestinationPath | Should -BeTrue
    }

    It "combines a custom name with a destination directory without prompting" {
        $source = Join-Path $script:TestRoot "world"
        $destinationDirectory = Join-Path $script:TestRoot "output"
        New-Item -ItemType Directory -Path $source, $destinationDirectory | Out-Null
        Set-Content -LiteralPath (Join-Path $source "level.dat") -Value "data"

        $process = Invoke-CompressProcess `
            -Path $source `
            -Destination $destinationDirectory `
            -Name "custom-backup" `
            -Format zip

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $process.Result.DestinationPath | Should -Be (Join-Path $destinationDirectory "custom-backup.zip")
        Test-Path -LiteralPath $process.Result.DestinationPath | Should -BeTrue
    }

    It "ignores a custom name when destination specifies a file path" {
        $source = Join-Path $script:TestRoot "save.dat"
        $destination = Join-Path $script:TestRoot "fixed.zip"
        Set-Content -LiteralPath $source -Value "data"

        $process = Invoke-CompressProcess `
            -Path $source `
            -Destination $destination `
            -Name "ignored" `
            -Format zip

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $process.Result.DestinationPath | Should -Be $destination
        ($process.Output -join "`n") | Should -Match "-Name is ignored"
        Test-Path -LiteralPath $destination | Should -BeTrue
    }

    It "maps zip level and threads to 7-Zip" {
        $source = Join-Path $script:TestRoot "save.dat"
        Set-Content -LiteralPath $source -Value "data"

        $process = Invoke-CompressProcess -Path $source -Format zip -Level Ultra -Threads 6
        $arguments = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "7z.args") -Raw

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $arguments | Should -Match "(^|\s)-tzip(\s|$)"
        $arguments | Should -Match "(^|\s)-mx=9(\s|$)"
        $arguments | Should -Match "(^|\s)-mmt=6(\s|$)"
        $arguments | Should -Match "(^|\s)-bsp1(\s|$)"
    }

    It "uses solid mode for 7z archives" {
        $source = Join-Path $script:TestRoot "world"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "region.mca") -Value "data"

        $process = Invoke-CompressProcess -Path $source -Format 7z
        $arguments = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "7z.args") -Raw

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $arguments | Should -Match "(^|\s)-t7z(\s|$)"
        $arguments | Should -Match "(^|\s)-ms=on(\s|$)"
    }

    It "maps tar.zst to tar with threaded long-distance zstd" {
        $source = Join-Path $script:TestRoot "world"
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source "region.mca") -Value "data"

        $process = Invoke-CompressProcess -Path $source -Format tar.zst -Level Max -Threads 8
        $arguments = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "tar.args") -Raw
        $compressor = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "zstd.args") -Raw

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $arguments | Should -Match "(^|\s)-cf\s+-"
        $compressor | Should -Match "-T8"
        $compressor | Should -Match "--long=27"
        $compressor | Should -Match "-19"
    }

    It "maps tar.xz to tar and threaded 7-Zip xz compression" {
        $source = Join-Path $script:TestRoot "save.dat"
        Set-Content -LiteralPath $source -Value "data"

        $process = Invoke-CompressProcess -Path $source -Format tar.xz -Threads 3
        $arguments = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "tar.args") -Raw
        $compressor = Get-Content -LiteralPath (Join-Path $script:FakeLogDirectory "7z.args") -Raw

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $arguments | Should -Match "(^|\s)-cf\s+-"
        $compressor | Should -Match "-txz"
        $compressor | Should -Match "-mmt=3"
        $compressor | Should -Match "(^|\s)-bsp1(\s|$)"
    }

    It "accepts multiple pipeline inputs for archive formats" {
        $first = Join-Path $script:TestRoot "first.dat"
        $second = Join-Path $script:TestRoot "second.dat"
        $destination = Join-Path $script:TestRoot "combined.zip"
        Set-Content -LiteralPath $first -Value "one"
        Set-Content -LiteralPath $second -Value "two"

        $process = Invoke-CompressProcess -Path $first, $second -Destination $destination -Format zip -Pipeline

        $process.ExitCode | Should -Be 0 -Because ($process.Output -join "`n")
        $process.Result.InputPaths.Count | Should -Be 2
        Test-Path -LiteralPath $destination | Should -BeTrue
    }

    It "rejects directories for raw zstd compression" {
        $source = Join-Path $script:TestRoot "world"
        New-Item -ItemType Directory -Path $source | Out-Null

        $process = Invoke-CompressProcess -Path $source -Format zstd

        $process.ExitCode | Should -Not -Be 0
        ($process.Output -join "`n") | Should -Match "only supports one input file"
    }

    It "reports a missing required tool" {
        $source = Join-Path $script:TestRoot "save.dat"
        Set-Content -LiteralPath $source -Value "data"

        $process = Invoke-CompressProcess -Path $source -Format tar.zst -AvailableTools tar

        $process.ExitCode | Should -Not -Be 0
        ($process.Output -join "`n") | Should -Match "Required tool 'zstd' was not found"
    }

    It "rejects a missing input path" {
        $process = Invoke-CompressProcess -Path (Join-Path $script:TestRoot "missing.dat") -Format zip

        $process.ExitCode | Should -Not -Be 0
        ($process.Output -join "`n") | Should -Match "Path does not exist"
    }
}
