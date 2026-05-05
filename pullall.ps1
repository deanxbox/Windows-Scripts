# pullall.ps1
# Concurrently pulls all git repos in a directory with live progress display.
# Usage: pullall [path]

param(
    [string]$Path = "."
)

$repos = Get-ChildItem -Path $Path -Directory | Where-Object { Test-Path "$($_.FullName)\.git" }

if (-not $repos) {
    Write-Host "No git repos found in $Path" -ForegroundColor Red
    exit
}

Write-Host "Found $($repos.Count) repos, pulling concurrently...`n" -ForegroundColor Cyan

# Track state per repo
$state = @{}
foreach ($repo in $repos) {
    $state[$repo.Name] = "pending"
}

# Start all jobs
$jobs = $repos | ForEach-Object {
    $repo = $_
    $job = Start-Job -ScriptBlock {
        param($repoPath, $repoName)
        $output = git -C $repoPath pull 2>&1
        [PSCustomObject]@{
            Name    = $repoName
            Output  = $output -join "`n"
            Success = $LASTEXITCODE -eq 0
        }
    } -ArgumentList $repo.FullName, $repo.Name
    [PSCustomObject]@{ Job = $job; Name = $repo.Name }
}

# Reserve lines for progress display
$startLine = [Console]::CursorTop
foreach ($repo in $repos) {
    Write-Host "  [ PULLING ] $($repo.Name)" -ForegroundColor DarkGray
}

$completed = @{}

while ($completed.Count -lt $jobs.Count) {
    foreach ($entry in $jobs) {
        if ($completed.ContainsKey($entry.Name)) { continue }
        if ($entry.Job.State -in @("Completed", "Failed")) {
            $result = Receive-Job $entry.Job
            Remove-Job $entry.Job
            $completed[$entry.Name] = $result

            # Find line index for this repo
            $idx = [array]::IndexOf(($repos | ForEach-Object { $_.Name }), $entry.Name)
            $targetLine = $startLine + $idx

            # Move cursor to that line and overwrite
            [Console]::SetCursorPosition(0, $targetLine)
            if ($result.Success) {
                $short = if ($result.Output -match "Already up to date") { "Already up to date" } else { "Pulled" }
                Write-Host "  [   DONE  ] $($entry.Name) - $short          " -ForegroundColor Green
            } else {
                Write-Host "  [  ERROR  ] $($entry.Name)                    " -ForegroundColor Red
            }
        }
    }
    Start-Sleep -Milliseconds 100
}

# Move cursor past the progress block
[Console]::SetCursorPosition(0, $startLine + $repos.Count)
Write-Host ""

# Print any errors in full
$errors = $completed.Values | Where-Object { -not $_.Success }
if ($errors) {
    Write-Host "Errors:" -ForegroundColor Red
    foreach ($e in $errors) {
        Write-Host "`n$($e.Name)" -ForegroundColor Yellow
        Write-Host $e.Output
    }
}

Write-Host "Done. $($completed.Values.Where({$_.Success}).Count)/$($jobs.Count) succeeded." -ForegroundColor Cyan