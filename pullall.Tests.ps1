BeforeAll {
    $script:PullAllPath = Join-Path $PSScriptRoot "pullall.ps1"
    $script:PowerShellPath = Join-Path $PSHOME "pwsh.exe"
}

Describe "pullall.ps1" {
    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pullall-test-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
    }

    AfterEach {
        if ($script:TestRoot -and
            (Test-Path -LiteralPath $script:TestRoot) -and
            $script:TestRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It "prints only the final categorized summary" {
        $origin = Join-Path $script:TestRoot "origin.git"
        $seed = Join-Path $script:TestRoot "seed"
        $reposRoot = Join-Path $script:TestRoot "repos"
        $updatedRepo = Join-Path $reposRoot "repo-updated"
        $currentRepo = Join-Path $reposRoot "repo-current"
        $failedRepo = Join-Path $reposRoot "repo-failed"
        $plainDirectory = Join-Path $reposRoot "plain-directory"

        git init --bare $origin *> $null
        git clone $origin $seed *> $null
        Set-Content -LiteralPath (Join-Path $seed "file.txt") -Value "v1"
        git -C $seed -c user.name="Codex Test" -c user.email="codex@example.invalid" add file.txt
        git -C $seed -c user.name="Codex Test" -c user.email="codex@example.invalid" commit -m "initial" *> $null
        git -C $seed push origin HEAD *> $null

        New-Item -ItemType Directory -Path $reposRoot | Out-Null
        git clone $origin $updatedRepo *> $null

        Set-Content -LiteralPath (Join-Path $seed "file.txt") -Value "v2"
        git -C $seed -c user.name="Codex Test" -c user.email="codex@example.invalid" commit -am "update" *> $null
        git -C $seed push origin HEAD *> $null
        git clone $origin $currentRepo *> $null

        git init $failedRepo *> $null
        New-Item -ItemType Directory -Path $plainDirectory | Out-Null

        $output = & $script:PowerShellPath `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $script:PullAllPath `
            $reposRoot `
            -ThrottleLimit 2 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match "(?s)Updated repositories \(1\).*repo-updated"
        $output | Should -Match "(?m)^\s+M\s+file\.txt\r?$"
        $output | Should -Match "(?s)Already up to date \(1\).*repo-current"
        $output | Should -Match "(?s)Not repositories \(1\).*plain-directory"
        $output | Should -Match "(?s)Failures \(1\).*repo-failed"
        $output | Should -Not -Match "Fast-forward"
    }

    It "summarizes an empty directory without failing" {
        $output = & $script:PowerShellPath `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $script:PullAllPath `
            $script:TestRoot 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Match "Scanned 0 directories"
        $output | Should -Match "Updated repositories \(0\)"
        $output | Should -Match "Not repositories \(0\)"
        $output | Should -Match "Failures \(0\)"
    }
}
