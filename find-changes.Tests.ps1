BeforeAll {
    $script:FindChangesPath = Join-Path $PSScriptRoot "find-changes.ps1"
    $script:PowerShellPath = Join-Path $PSHOME "pwsh.exe"
}

Describe "find-changes.ps1" {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("find-changes-test-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
    }

    AfterEach {
        if ($script:TestRoot -and
            (Test-Path -LiteralPath $script:TestRoot) -and
            $script:TestRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It "categorizes changed, clean, and non-repository directories" {
        $reposRoot = Join-Path $script:TestRoot "repos"
        $changedRepo = Join-Path $reposRoot "repo-changed"
        $cleanRepo = Join-Path $reposRoot "repo-clean"
        $plainDirectory = Join-Path $reposRoot "plain-directory"

        New-Item -ItemType Directory -Path $reposRoot | Out-Null
        git init $changedRepo *> $null
        git -C $changedRepo config user.name "Codex Test"
        git -C $changedRepo config user.email "codex@example.invalid"
        Set-Content -LiteralPath (Join-Path $changedRepo "file.txt") -Value "v1"
        git -C $changedRepo add file.txt
        git -C $changedRepo commit -m "initial" *> $null
        Set-Content -LiteralPath (Join-Path $changedRepo "file.txt") -Value "v2"

        git init $cleanRepo *> $null
        git -C $cleanRepo config user.name "Codex Test"
        git -C $cleanRepo config user.email "codex@example.invalid"
        Set-Content -LiteralPath (Join-Path $cleanRepo "file.txt") -Value "v1"
        git -C $cleanRepo add file.txt
        git -C $cleanRepo commit -m "initial" *> $null
        New-Item -ItemType Directory -Path $plainDirectory | Out-Null

        $output = & $script:PowerShellPath `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $script:FindChangesPath `
            $reposRoot `
            -ThrottleLimit 2 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match "(?s)Changed repositories \(1\).*repo-changed"
        $output | Should -Match "(?m)^\s+M\s+file\.txt\r?$"
        $output | Should -Match "(?s)No changes \(1\).*repo-clean"
        $output | Should -Match "(?s)Not repositories \(1\).*plain-directory"
        $output | Should -Match "Failures \(0\)"
    }

    It "summarizes an empty directory without failing" {
        $output = & $script:PowerShellPath `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $script:FindChangesPath `
            $script:TestRoot 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match "Scanned 0 directories"
        $output | Should -Match "Changed repositories \(0\)"
        $output | Should -Match "Not repositories \(0\)"
        $output | Should -Match "Failures \(0\)"
    }
}
