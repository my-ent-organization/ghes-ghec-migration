# GHES -> GitHub parallel migration runner (GitHub Actions optimized)
# - Configurable via parameters for GitHub Actions workflow
# - Keeps your status bar and CSV writes
# - Streams logs from files (delta-only) while jobs run
# - Ensures background job emits only the final result object (no log noise on the output stream)
# - Robust Receive-Job parsing so $failed increments correctly
#
# Expected repos.csv schema columns (source + target):
# ghes_org, ghes_repo, github_org, github_repo, gh_repo_visibility
# Other columns are ignored. (e.g. repo_url, repo_size_MB)
#
# Requires env vars:
# GH_SOURCE_PAT (source GHES token)
# GH_PAT (target GitHub token)
# GHES_API_URL (e.g. https://ghe.example.com/api/v3)
#
# Uses GEI CLI: gh gei migrate-repo ... --ghes-api-url ... --target-repo-visibility ...
param(
  [Parameter(Mandatory=$false)]
  [int]$MaxConcurrent = 5,

  [Parameter(Mandatory=$false)]
  [string]$CsvPath = "repos.csv",

  [Parameter(Mandatory=$false)]
  [string]$OutputPath = ""
)

# -------------------- Settings --------------------
# Validate max concurrent limit
if ($MaxConcurrent -gt 5) {
  Write-Host "[ERROR] Maximum concurrent migrations ($MaxConcurrent) exceeds the allowed limit of 5." -ForegroundColor Red
  Write-Host "[ERROR] Please set MaxConcurrent to 5 or less." -ForegroundColor Red
  exit 1
}
if ($MaxConcurrent -lt 1) {
  Write-Host "[ERROR] MaxConcurrent must be at least 1." -ForegroundColor Red
  exit 1
}

# Validate required environment variables (GEI)
if ([string]::IsNullOrWhiteSpace($env:GH_SOURCE_PAT)) {
  Write-Host "[ERROR] Environment variable GH_SOURCE_PAT is not set." -ForegroundColor Red
  exit 1
}
if ([string]::IsNullOrWhiteSpace($env:GH_PAT)) {
  Write-Host "[ERROR] Environment variable GH_PAT is not set." -ForegroundColor Red
  exit 1
}
if ([string]::IsNullOrWhiteSpace($env:GHES_API_URL)) {
  Write-Host "[ERROR] Environment variable GHES_API_URL is not set (example: https://ghe.example.com/api/v3)." -ForegroundColor Red
  exit 1
}

# Normalize GHES API URL (remove trailing slash)
$env:GHES_API_URL = $env:GHES_API_URL.TrimEnd('/')

# -------------------- DR-aware TARGET_API_URL --------------------
# If GH_TARGET_HOST is set, treat destination as Data Residency (GHE.com) and set target api url as https://api.<GH_TARGET_HOST>
# Else default to https://api.github.com
# If TARGET_API_URL is explicitly set already, keep it (no behavior break).
$targetApiUrl =
if (-not [string]::IsNullOrWhiteSpace($env:TARGET_API_URL)) {
  $env:TARGET_API_URL
}
elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TARGET_HOST)) {
  "https://api.$($env:GH_TARGET_HOST)"
}
else {
  "https://api.github.com"
}

# Output file
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $outputCsvPath = "repo_migration_output-$timestamp.csv"
} else {
  $outputCsvPath = $OutputPath
}

# CSV exists?
if (-not (Test-Path -Path $CsvPath)) {
  Write-Host "[ERROR] CSV file not found at path: $CsvPath" -ForegroundColor Red
  exit 1
}

# Load CSV
$REOSource = Import-Csv -Path $CsvPath
if ($REOSource.Count -eq 0) {
  Write-Host "[ERROR] CSV file is empty: $CsvPath" -ForegroundColor Red
  exit 1
}

# Convert to ArrayList for mutation-friendly operations later
$REPOS = New-Object System.Collections.ArrayList
foreach ($repo in $REOSource) { [void]$REPOS.Add($repo) }

# Validate required columns for GHES -> GitHub
$requiredColumns = @('ghes_org', 'ghes_repo', 'github_org', 'github_repo', 'gh_repo_visibility')
$firstRepo = $REPOS[0]
$missingColumns = $requiredColumns | Where-Object { $_ -notin $firstRepo.PSObject.Properties.Name }
if ($missingColumns) {
  Write-Host "[ERROR] CSV is missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
  Write-Host "[ERROR] Required columns: $($requiredColumns -join ', ')" -ForegroundColor Red
  exit 1
}

# Ensure expected columns exist / initialize
foreach ($repo in $REPOS) {
  if ($repo.PSObject.Properties["Migration_Status"]) {
    $repo.Migration_Status = "Pending"
  } else {
    $repo | Add-Member -NotePropertyName Migration_Status -NotePropertyValue "Pending"
  }

  if ($repo.PSObject.Properties["Log_File"]) {
    $repo.Log_File = ""
  } else {
    $repo | Add-Member -NotePropertyName Log_File -NotePropertyValue ""
  }
}

function Write-MigrationStatusCsv {
  $REPOS | Export-Csv -Path $outputCsvPath -NoTypeInformation
}

Write-MigrationStatusCsv
Write-Host "[INFO] Starting migration with $MaxConcurrent concurrent jobs..."
Write-Host "[INFO] Processing $($REPOS.Count) repositories from: $CsvPath" -ForegroundColor Cyan
Write-Host "[INFO] Initialized migration status output: $outputCsvPath" -ForegroundColor Cyan

# -------------------- MAIN: parallel migration with concurrent jobs --------------------
$queue = [System.Collections.ArrayList]@($REPOS)
$inProgress = [System.Collections.ArrayList]@()
$migrated = [System.Collections.ArrayList]@()
$failed = [System.Collections.ArrayList]@()
$script:StatusLineWidth = 0

function Show-StatusBar {
  param($queue, $inProgress, $migrated, $failed)

  $queueCount = $queue.Count
  $progressCount = $inProgress.Count
  $migratedCount = $migrated.Count
  $failedCount = $failed.Count

  $statusLine = "QUEUE: $queueCount "
  $statusLine += "IN PROGRESS: $progressCount "
  $statusLine += "MIGRATED: $migratedCount "
  $statusLine += "MIGRATION FAILED: $failedCount"

  if ($statusLine.Length -gt $script:StatusLineWidth) {
    $script:StatusLineWidth = $statusLine.Length
  }
  $statusLine = $statusLine.PadRight($script:StatusLineWidth)
  Write-Host "`r$statusLine" -NoNewline -ForegroundColor Cyan
}

while ($queue.Count -gt 0 -or $inProgress.Count -gt 0) {

  # Start new jobs if below max concurrent
  while ($inProgress.Count -lt $MaxConcurrent -and $queue.Count -gt 0) {

    $repo = $queue[0]
    $queue.RemoveAt(0)

    $ghesOrg = $repo.ghes_org
    $ghesRepo = $repo.ghes_repo
    $githubOrg = $repo.github_org
    $githubRepo = $repo.github_repo
    $visibility = $repo.gh_repo_visibility

    # Create log file (per repo)
    $logFile = "migration-$githubRepo-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    # Ensure log directory exists (if any)
    $logDir = Split-Path -Path $logFile
    if ($logDir) { $null = New-Item -ItemType Directory -Force -Path $logDir }

    $repo.Log_File = $logFile
    Write-MigrationStatusCsv

    # Background job script: emits ONLY @{ MigrationSuccess = <bool> }
    $scriptBlock = {
      param($ghesOrg, $ghesRepo, $githubOrg, $githubRepo, $visibility, $logFile, $workDir, $ghesApiUrl, $targetApiUrl)

      Set-Location -Path $workDir

      function Migrate-Repository {
        param (
          [string]$ghesOrg,
          [string]$ghesRepo,
          [string]$githubOrg,
          [string]$githubRepo,
          [string]$visibility,
          [string]$logFile,
          [string]$ghesApiUrl,
          [string]$targetApiUrl
        )

        "[{0}] [START] Migration: {1}/{2} -> {3}/{4} (visibility: {5})" -f (Get-Date), $ghesOrg, $ghesRepo, $githubOrg, $githubRepo, $visibility |
          Tee-Object -FilePath $logFile -Append | Out-Null

        "[{0}] [DEBUG] Running: gh gei migrate-repo --github-source-org {1} --source-repo {2} --github-target-org {3} --target-repo {4} --target-repo-visibility {5} --ghes-api-url {6} --target-api-url {7}" -f (Get-Date), $ghesOrg, $ghesRepo, $githubOrg, $githubRepo, $visibility, $ghesApiUrl, $targetApiUrl |
          Tee-Object -FilePath $logFile -Append | Out-Null

        & gh gei migrate-repo `
          --github-source-org $ghesOrg `
          --source-repo $ghesRepo `
          --github-target-org $githubOrg `
          --target-repo $githubRepo `
          --target-repo-visibility $visibility `
          --ghes-api-url $ghesApiUrl `
          --target-api-url $targetApiUrl *>&1 |
          Tee-Object -FilePath $logFile -Append | Out-Null

        $migrateExit = $LASTEXITCODE

        # Check for markers in the log (same behavior as your bash runner)
        $logContent = Get-Content -Path $logFile -Raw
        if ($logContent -match "No operation will be performed") {
          return $false # keep behavior as Failure; change to $null for "Skipped"
        }

        # GEI often includes "State: SUCCEEDED" (keep tolerant check)
        if ($logContent -notmatch "State:\s*SUCCEEDED" -and $logContent -notmatch "\bSUCCEEDED\b") {
          return $false
        }

        if ($migrateExit -eq 0) {
          "[{0}] [SUCCESS] Migration: {1}/{2} -> {3}/{4}" -f (Get-Date), $ghesOrg, $ghesRepo, $githubOrg, $githubRepo |
            Tee-Object -FilePath $logFile -Append | Out-Null
          return $true
        } else {
          "[{0}] [FAILED] Migration: {1}/{2} -> {3}/{4}" -f (Get-Date), $ghesOrg, $ghesRepo, $githubOrg, $githubRepo |
            Tee-Object -FilePath $logFile -Append | Out-Null
          return $false
        }
      }

      $migrationSuccess = Migrate-Repository -ghesOrg $ghesOrg -ghesRepo $ghesRepo -githubOrg $githubOrg -githubRepo $githubRepo -visibility $visibility -logFile $logFile -ghesApiUrl $ghesApiUrl -targetApiUrl $targetApiUrl
      return @{ MigrationSuccess = $migrationSuccess }
    }

    # Start background job
    $workDir = (Get-Location).Path
    $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $ghesOrg, $ghesRepo, $githubOrg, $githubRepo, $visibility, $logFile, $workDir, $env:GHES_API_URL, $targetApiUrl

    $null = $inProgress.Add([PSCustomObject]@{
      Job = $job
      Repo = $repo
      LogFile = $logFile
      LastOutputLength = 0 # track how much of the log we've printed
    })

    Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
  }

  # --- Stream new output from each job's log file to the console ---
  foreach ($item in @($inProgress)) {
    if (Test-Path -Path $item.LogFile) {
      try {
        $content = Get-Content -Path $item.LogFile -Raw
        $newLen = $content.Length
        if ($newLen -gt $item.LastOutputLength) {
          $delta = $content.Substring($item.LastOutputLength)
          $item.LastOutputLength = $newLen
          if ($delta) {
            Write-Host ""
            $delta.TrimEnd("`r","`n") -split "(`r`n|`n|`r)" |
              ForEach-Object {
                if ($_ -ne '') { Write-Host $_ }
              }
            Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
          }
        }
      } catch {
        # Ignore transient read errors while the job is writing
      }
    }
  }

  # --- Check completed/failed/stopped jobs ---
  foreach ($item in @($inProgress)) {
    if ($item.Job.State -in 'Completed','Failed','Stopped') {
      $jobOutput = Receive-Job -Job $item.Job
      Remove-Job -Job $item.Job

      # Pick the last object that actually has the MigrationSuccess property
      $result = $jobOutput |
        Where-Object { $_ -is [hashtable] -and $_.ContainsKey('MigrationSuccess') } |
        Select-Object -Last 1

      if ($null -eq $result) {
        $null = $failed.Add($item.Repo)
        $item.Repo.Migration_Status = "Failure"
      }
      elseif ($result.MigrationSuccess -eq $true) {
        $null = $migrated.Add($item.Repo)
        $item.Repo.Migration_Status = "Success"
      }
      else {
        $null = $failed.Add($item.Repo)
        $item.Repo.Migration_Status = "Failure"
      }

      Write-MigrationStatusCsv
      $inProgress.Remove($item)
      Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
    }
  }

  Start-Sleep -Seconds 5
}

Write-Host "`n[INFO] All migrations completed."
Write-Host "[SUMMARY] Total: $($REPOS.Count) Migrated: $($migrated.Count) Failed: $($failed.Count)" -ForegroundColor Green
Write-MigrationStatusCsv
Write-Host "[INFO] Wrote migration results with Migration_Status column: $outputCsvPath" -ForegroundColor Cyan

if ($failed.Count -gt 0) {
  Write-Host "[WARNING] Migration completed with $($failed.Count) failures" -ForegroundColor Yellow
  # Don't exit with error - let workflow handle it
}
