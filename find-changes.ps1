# find-changes.ps1
# Finds uncommitted changes in every immediate child git repository.
# Usage: find-changes [path] [-ThrottleLimit 8]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "", Justification = "This script intentionally renders a colorized console summary.")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseUsingScopeModifierInNewRunspaces", "", Justification = "Start-Job receives values through param/ArgumentList rather than closure capture.")]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateScript({
        if (Test-Path -LiteralPath $_ -PathType Container) { return $true }
        throw "Directory does not exist: $_"
    })]
    [string]$Path = ".",

    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = 8
)

function Get-StatusResultKind {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    if (-not $Result.Success) { return "Error" }
    if ($Result.Output) { return "Changes" }
    return "Clean"
}

function Get-ProgressStatus {
    param(
        [int]$Processed,
        [int]$Total,
        [int]$Failures,
        [int]$Changes
    )

    $status = "$Processed of $Total directories"
    $extras = @()
    if ($Failures -gt 0) { $extras += "$Failures failed" }
    if ($Changes -gt 0) { $extras += "$Changes changed" }
    if ($extras.Count -gt 0) { $status += " ($($extras -join ', '))" }
    return $status
}

function Write-SummaryList {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [ConsoleColor]$Color
    )

    Write-Host ""
    Write-Host "$Title ($($Items.Count))" -ForegroundColor $Color
    if ($Items.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor DarkGray
        return
    }

    foreach ($item in $Items) {
        Write-Host "  - $item"
    }
}

function Write-ChangedRepositoryList {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    Write-Host ""
    Write-Host "Changed repositories ($($Items.Count))" -ForegroundColor Green
    if ($Items.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor DarkGray
        return
    }

    foreach ($item in $Items) {
        Write-Host "  - $($item.Name)"
        foreach ($file in @($item.Files)) {
            Write-Host "      $file" -ForegroundColor DarkGray
        }
    }
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$directories = @(Get-ChildItem -LiteralPath $resolvedPath -Directory | Sort-Object Name)
$repos = [System.Collections.Generic.List[object]]::new()
$nonRepos = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$processedCount = 0
$liveFailures = 0
$liveChanges = 0

foreach ($directory in $directories) {
    if (Test-Path -LiteralPath (Join-Path $directory.FullName ".git")) {
        $repos.Add($directory)
    }
    else {
        $nonRepos.Add($directory.Name)
        $processedCount++
        Write-Progress `
            -Id 1 `
            -Activity "Scanning and checking directories" `
            -Status (Get-ProgressStatus $processedCount $directories.Count $liveFailures $liveChanges) `
            -PercentComplete (($processedCount / [Math]::Max(1, $directories.Count)) * 100)
    }
}

$repoQueue = [System.Collections.Generic.Queue[object]]::new()
foreach ($repo in $repos) {
    $repoQueue.Enqueue($repo)
}

$runningJobs = [System.Collections.Generic.List[object]]::new()

try {
    while ($repoQueue.Count -gt 0 -or $runningJobs.Count -gt 0) {
        while ($repoQueue.Count -gt 0 -and $runningJobs.Count -lt $ThrottleLimit) {
            $repo = $repoQueue.Dequeue()
            try {
                $job = Start-Job -ScriptBlock {
                    param($RepoPath, $RepoName)

                    $output = git -C $RepoPath status --porcelain 2>&1
                    $success = $LASTEXITCODE -eq 0
                    [PSCustomObject]@{
                        Name    = $RepoName
                        Output  = $output -join "`n"
                        Success = $success
                        Files   = if ($success) { @($output) } else { @() }
                    }
                } -ArgumentList $repo.FullName, $repo.Name -ErrorAction Stop

                $runningJobs.Add([PSCustomObject]@{ Job = $job; Name = $repo.Name })
            }
            catch {
                $result = [PSCustomObject]@{
                    Name    = $repo.Name
                    Output  = $_.Exception.Message
                    Success = $false
                    Files   = @()
                }
                $results.Add($result)
                switch (Get-StatusResultKind $result) {
                    "Error" { $liveFailures++ }
                    "Changes" { $liveChanges++ }
                }
                $processedCount++
            }
        }

        foreach ($entry in @($runningJobs)) {
            if ($entry.Job.State -notin 'Completed', 'Failed') { continue }

            $received = @(Receive-Job $entry.Job -ErrorAction SilentlyContinue)
            $reason = $entry.Job.ChildJobs[0].JobStateInfo.Reason
            Remove-Job $entry.Job -Force
            [void]$runningJobs.Remove($entry)

            if ($received.Count -gt 0) {
                $result = $received[-1]
            }
            else {
                $message = if ($reason) { $reason.Message } else { "Job returned no result." }
                $result = [PSCustomObject]@{
                    Name    = $entry.Name
                    Output  = $message
                    Success = $false
                    Files   = @()
                }
            }

            $results.Add($result)
            switch (Get-StatusResultKind $result) {
                "Error" { $liveFailures++ }
                "Changes" { $liveChanges++ }
            }

            $processedCount++
            Write-Progress `
                -Id 1 `
                -Activity "Scanning and checking directories" `
                -Status (Get-ProgressStatus $processedCount $directories.Count $liveFailures $liveChanges) `
                -PercentComplete (($processedCount / [Math]::Max(1, $directories.Count)) * 100)
        }

        if ($runningJobs.Count -gt 0) {
            Start-Sleep -Milliseconds 100
        }
    }
}
finally {
    foreach ($entry in @($runningJobs)) {
        Stop-Job $entry.Job -ErrorAction SilentlyContinue
        Remove-Job $entry.Job -Force -ErrorAction SilentlyContinue
    }
    Write-Progress -Id 1 -Activity "Scanning and checking directories" -Completed
}

$changed = @($results | Where-Object { (Get-StatusResultKind $_) -eq "Changes" } | Sort-Object Name)
$clean = @($results | Where-Object { (Get-StatusResultKind $_) -eq "Clean" } | Sort-Object Name)
$failures = @($results | Where-Object { (Get-StatusResultKind $_) -eq "Error" } | Sort-Object Name)

Write-Host "Scanned $($directories.Count) directories in $resolvedPath." -ForegroundColor Cyan
Write-ChangedRepositoryList -Items $changed
Write-SummaryList -Title "No changes" -Items @($clean | ForEach-Object Name) -Color DarkCyan
Write-SummaryList -Title "Not repositories" -Items $nonRepos.ToArray() -Color Yellow

Write-Host ""
Write-Host "Failures ($($failures.Count))" -ForegroundColor Red
if ($failures.Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor DarkGray
}
else {
    foreach ($failure in $failures) {
        Write-Host "  - $($failure.Name)" -ForegroundColor Red
        if ($failure.Output) {
            foreach ($line in @($failure.Output -split "`r?`n")) {
                Write-Host "      $line" -ForegroundColor DarkRed
            }
        }
    }
}
