#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# GHES -> GHEC: COMPLETE SYNC (ORG, REPO, ENV VARS + RULES)
# Enhanced version:
#  - Source/target repo existence checks
#  - Centralized API wrapper with exit code handling
#  - Structured logging
#  - Per-repo and final execution summary
# ============================================================

# ------------------------------------------------------------
# Env inputs
# ------------------------------------------------------------
$CSV_FILE       = if ($env:CSV_FILE) { $env:CSV_FILE } else { "repos.csv" }
$GH_PAT         = $env:GH_PAT;         if (-not $GH_PAT)         { throw "Set GH_PAT" }
$GH_SOURCE_PAT  = $env:GH_SOURCE_PAT;  if (-not $GH_SOURCE_PAT)  { throw "Set GH_SOURCE_PAT" }
$GHES_API_URL   = $env:GHES_API_URL;   if (-not $GHES_API_URL)   { throw "Set GHES_API_URL" }
$TARGET_HOST    = if ($env:GH_TARGET_HOST) { $env:GH_TARGET_HOST } else { "github.com" }

# Headers same as shell
$GH_HEADERS = @(
    "-H", "Accept: application/vnd.github+json",
    "-H", "X-GitHub-Api-Version: 2022-11-28"
)

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
function Get-Timestamp {
    Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

function Log-Info([string]$Message) {
    Write-Host "[$(Get-Timestamp)] [INFO]    $Message"
}

function Log-Warn([string]$Message) {
    Write-Host "[$(Get-Timestamp)] [WARN]    $Message" -ForegroundColor Yellow
}

function Log-ErrorMsg([string]$Message) {
    Write-Host "[$(Get-Timestamp)] [ERROR]   $Message" -ForegroundColor Red
}

function Log-Success([string]$Message) {
    Write-Host "[$(Get-Timestamp)] [SUCCESS] $Message" -ForegroundColor Green
}

# backward-compatible
function Log([string]$Message) {
    Log-Info $Message
}

# ------------------------------------------------------------
# Parse SOURCE_HOST from GHES_API_URL
# ------------------------------------------------------------
$sourceUrlText = $GHES_API_URL
if ($sourceUrlText -notmatch "^\w+://") {
    $sourceUrlText = "https://$sourceUrlText"
}
$sourceUri = [Uri]$sourceUrlText
$SOURCE_HOST = if ($sourceUri.IsDefaultPort) { $sourceUri.Host } else { "$($sourceUri.Host):$($sourceUri.Port)" }

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function UrlEncode([string]$s) {
    return [Uri]::EscapeDataString($s)
}

# ------------------------------------------------------------
# Centralized API wrapper
# ------------------------------------------------------------
function Invoke-GhApi {
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][string]$Token,
        [Parameter(Mandatory=$true)][string]$Context,
        [Parameter(Mandatory=$true)][string[]]$Args,
        [string]$Stdin = $null
    )

    $old = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $Token

        $tempErr = [System.IO.Path]::GetTempFileName()
        try {
            if ($null -ne $Stdin) {
                $out = $Stdin | & gh api --hostname $HostName @GH_HEADERS @Args 2> $tempErr
            } else {
                $out = & gh api --hostname $HostName @GH_HEADERS @Args 2> $tempErr
            }

            if ($LASTEXITCODE -ne 0) {
                $errText = ""
                if (Test-Path $tempErr) {
                    $errText = (Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue).Trim()
                }
                throw "API failed [$Context] :: $errText"
            }

            if ($null -eq $out) { return "" }
            if ($out -is [Array]) { return ($out -join [Environment]::NewLine) }
            return [string]$out
        }
        finally {
            Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        $env:GH_TOKEN = $old
    }
}

function Gh-Source {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [string]$Stdin = $null,
        [Parameter(Mandatory=$true)][string]$Context
    )
    Invoke-GhApi -HostName $SOURCE_HOST -Token $GH_SOURCE_PAT -Args $Args -Stdin $Stdin -Context $Context
}

function Gh-Target {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [string]$Stdin = $null,
        [Parameter(Mandatory=$true)][string]$Context
    )
    Invoke-GhApi -HostName $TARGET_HOST -Token $GH_PAT -Args $Args -Stdin $Stdin -Context $Context
}

# ------------------------------------------------------------
# Repo existence checks
# ------------------------------------------------------------
function Test-SourceRepoExists {
    param([Parameter(Mandatory=$true)][string]$FullName)
    try {
        [void](Gh-Source -Args @("/repos/$FullName") -Context "check source repo exists: $FullName")
        return $true
    }
    catch {
        Log-ErrorMsg $_.Exception.Message
        return $false
    }
}

function Test-TargetRepoExists {
    param([Parameter(Mandatory=$true)][string]$FullName)
    try {
        [void](Gh-Target -Args @("/repos/$FullName") -Context "check target repo exists: $FullName")
        return $true
    }
    catch {
        Log-ErrorMsg $_.Exception.Message
        return $false
    }
}

function Get-ReviewerId {
    param([Parameter(Mandatory=$true)][string]$Handle)

    try {
        $json = Gh-Target -Args @("/users/$Handle") -Context "get reviewer id: $Handle"
        $obj = $json | ConvertFrom-Json
        if ($null -ne $obj.id) {
            return [string]$obj.id
        }
    }
    catch {
        Log-Warn "Reviewer '$Handle' not found on target host."
    }
    return ""
}

# ------------------------------------------------------------
# Summary counters
# ------------------------------------------------------------
$script:TOTAL_REPOS             = 0
$script:SUCCESS_REPOS           = 0
$script:FAILED_REPOS            = 0
$script:SKIPPED_REPOS           = 0
$script:TOTAL_ORG_VARS_SYNCED   = 0
$script:TOTAL_REPO_VARS_SYNCED  = 0
$script:TOTAL_ENVS_SYNCED       = 0
$script:TOTAL_ENV_VARS_SYNCED   = 0
$script:TOTAL_ENV_RULES_SYNCED  = 0

# ------------------------------------------------------------
# Sync environment data
# ------------------------------------------------------------
function Sync-EnvironmentData {
    param(
        [Parameter(Mandatory=$true)][string]$SrcFull,
        [Parameter(Mandatory=$true)][string]$TgtFull,
        [Parameter(Mandatory=$true)][string]$EnvName,
        [string]$ReviewerHandle
    )

    $env_enc = UrlEncode $EnvName
    $repoEnvRulesSynced = 0
    $repoEnvVarsSynced = 0

    # --- 1. SYNC PROTECTION RULES ---
    $src_env_json = "{}"
    try {
        $tmp = Gh-Source -Args @("/repos/$SrcFull/environments/$env_enc") -Context "fetch source environment rules: $SrcFull / $EnvName"
        if ($tmp) { $src_env_json = $tmp }
    }
    catch {
        Log-Warn "Skipping environment rules for '$EnvName' due to source fetch failure."
    }

    $reviewer_id = ""
    if ($ReviewerHandle) {
        $reviewer_id = Get-ReviewerId -Handle $ReviewerHandle
    }

    $payloadObj = @{}
    try {
        $src = $src_env_json | ConvertFrom-Json
        $rules = @()
        if ($null -ne $src.protection_rules) {
            $rules = @($src.protection_rules)
        }

        foreach ($r in $rules) {
            if ($null -eq $r) { continue }

            if ($r.type -eq "wait_timer") {
                $payloadObj["wait_timer"] = if ($null -ne $r.wait_timer) { [int]$r.wait_timer } else { 0 }
            }

            if ($r.type -eq "required_reviewers" -and $reviewer_id) {
                $payloadObj["reviewers"] = @(@{
                    type = "User"
                    id   = [int]$reviewer_id
                })

                $payloadObj["prevent_self_review"] = if ($null -ne $r.prevent_self_review) {
                    [bool]$r.prevent_self_review
                } else {
                    $false
                }
            }
        }
    }
    catch {
        $payloadObj = @{}
    }

    try {
        $payload = $payloadObj | ConvertTo-Json -Compress
        Gh-Target -Args @("-X", "PUT", "/repos/$TgtFull/environments/$env_enc", "--input", "-") -Stdin $payload -Context "apply environment rules: $TgtFull / $EnvName" | Out-Null
        Log-Success "Env '$EnvName' rules synced."
        $script:TOTAL_ENV_RULES_SYNCED++
        $repoEnvRulesSynced = 1
    }
    catch {
        Log-Warn "Failed to sync environment rules for '$EnvName'. $_"
    }

    # --- 2. SYNC ENVIRONMENT VARIABLES ---
    $src_repo_id = $null
    $tgt_repo_id = $null

    try {
        $src_repo_id = (($(
            Gh-Source -Args @("/repos/$SrcFull") -Context "get source repo id: $SrcFull"
        ) | ConvertFrom-Json).id)
    }
    catch {
        Log-Warn "Unable to resolve source repo id for '$SrcFull'. Skipping env vars for '$EnvName'."
    }

    try {
        $tgt_repo_id = (($(
            Gh-Target -Args @("/repos/$TgtFull") -Context "get target repo id: $TgtFull"
        ) | ConvertFrom-Json).id)
    }
    catch {
        Log-Warn "Unable to resolve target repo id for '$TgtFull'. Skipping env vars for '$EnvName'."
    }

    if ($src_repo_id -and $tgt_repo_id) {
        $varsJson = $null
        try {
            $varsJson = Gh-Source -Args @("/repositories/$src_repo_id/environments/$env_enc/variables") -Context "fetch source env vars: $SrcFull / $EnvName"
        }
        catch {
            $varsJson = $null
        }

        if ($varsJson) {
            $varsObj = $varsJson | ConvertFrom-Json
            $vars = @()
            if ($null -ne $varsObj.variables) {
                $vars = @($varsObj.variables)
            }

            foreach ($v in $vars) {
                $vname = [string]$v.name
                $vval  = [string]$v.value

                try {
                    Gh-Target -Args @(
                        "-X", "POST",
                        "/repositories/$tgt_repo_id/environments/$env_enc/variables",
                        "-f", "name=$vname",
                        "-f", "value=$vval"
                    ) -Context "create env var: $TgtFull / $EnvName / $vname" | Out-Null
                    Log-Success "Env Var synced: $EnvName / $vname"
                    $script:TOTAL_ENV_VARS_SYNCED++
                    $repoEnvVarsSynced++
                }
                catch {
                    try {
                        Gh-Target -Args @(
                            "-X", "PATCH",
                            "/repositories/$tgt_repo_id/environments/$env_enc/variables/$vname",
                            "-f", "name=$vname",
                            "-f", "value=$vval"
                        ) -Context "update env var: $TgtFull / $EnvName / $vname" | Out-Null
                        Log-Success "Env Var synced: $EnvName / $vname"
                        $script:TOTAL_ENV_VARS_SYNCED++
                        $repoEnvVarsSynced++
                    }
                    catch {
                        Log-Warn "Failed to sync env var: $EnvName / $vname"
                    }
                }
            }
        }
    }

    $script:TOTAL_ENVS_SYNCED++
    Log-Info "Environment summary [$EnvName] :: rules_synced=$repoEnvRulesSynced env_vars_synced=$repoEnvVarsSynced"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
function Main {
    Log-Info "Starting GHES -> GHEC Full Migration"
    $seen_orgs = @{}

    if (-not (Test-Path -LiteralPath $CSV_FILE)) {
        throw "CSV file not found: $CSV_FILE"
    }

    $lines = Get-Content -LiteralPath $CSV_FILE | ForEach-Object { $_ -replace "`r$","" }
    if ($lines.Count -lt 2) {
        Log-Success "Migration Complete."
        Log-Info "Final Summary :: repos_processed=0 repos_succeeded=0 repos_failed=0 repos_skipped=0 org_vars_synced=0 repo_vars_synced=0 envs_processed=0 env_rules_synced=0 env_vars_synced=0"
        return
    }

    foreach ($line in $lines[1..($lines.Count-1)]) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split ",", 8
        while ($parts.Count -lt 8) { $parts += "" }

        $s_org           = $parts[0].Trim()
        $s_repo          = $parts[1].Trim()
        $t_org           = $parts[4].Trim()
        $t_repo          = $parts[5].Trim()
        $reviewer_handle = $parts[7].Trim()

        if (-not $s_org) { continue }

        $script:TOTAL_REPOS++

        $localRepoOrgVars = 0
        $localRepoRepoVars = 0
        $localRepoEnvs = 0
        $localFailed = 0

        $srcFull = "$s_org/$s_repo"
        $tgtFull = "$t_org/$t_repo"

        Log-Info "Processing: $srcFull -> $tgtFull"

        if (-not (Test-SourceRepoExists -FullName $srcFull)) {
            Log-ErrorMsg "Source repository not found or inaccessible: $srcFull"
            $script:FAILED_REPOS++
            continue
        }

        if (-not (Test-TargetRepoExists -FullName $tgtFull)) {
            Log-ErrorMsg "Target repository not found or inaccessible: $tgtFull"
            $script:FAILED_REPOS++
            continue
        }

        # --- 1. ORG VARIABLES ---
        if (-not $seen_orgs.ContainsKey($s_org)) {
            Log-Info "Syncing Org Vars for $t_org"

            $orgVarsJson = $null
            try {
                $orgVarsJson = Gh-Source -Args @("/orgs/$s_org/actions/variables") -Context "fetch source org vars: $s_org"
            }
            catch {
                $orgVarsJson = $null
            }

            if ($orgVarsJson) {
                $orgVarsObj = $orgVarsJson | ConvertFrom-Json
                $vars = @()
                if ($null -ne $orgVarsObj.variables) {
                    $vars = @($orgVarsObj.variables)
                }

                foreach ($v in $vars) {
                    $n = [string]$v.name
                    $val = [string]$v.value

                    try {
                        Gh-Target -Args @(
                            "-X", "POST",
                            "/orgs/$t_org/actions/variables",
                            "-f", "name=$n",
                            "-f", "value=$val",
                            "-f", "visibility=all"
                        ) -Context "create org var: $t_org / $n" | Out-Null
                        $localRepoOrgVars++
                        $script:TOTAL_ORG_VARS_SYNCED++
                    }
                    catch {
                        try {
                            Gh-Target -Args @(
                                "-X", "PATCH",
                                "/orgs/$t_org/actions/variables/$n",
                                "-f", "name=$n",
                                "-f", "value=$val"
                            ) -Context "update org var: $t_org / $n" | Out-Null
                            $localRepoOrgVars++
                            $script:TOTAL_ORG_VARS_SYNCED++
                        }
                        catch {
                            Log-Warn "Failed to sync org var: $t_org / $n"
                            $localFailed++
                        }
                    }
                }
            }

            $seen_orgs[$s_org] = 1
            Log-Success "Org vars sync completed for $t_org (count=$localRepoOrgVars)"
        }
        else {
            Log-Info "Org vars already processed for source org '$s_org'; skipping duplicate org sync."
        }

        # --- 2. REPO VARIABLES ---
        Log-Info "Syncing Repo Vars"
        $repoVarsJson = $null
        try {
            $repoVarsJson = Gh-Source -Args @("/repos/$s_org/$s_repo/actions/variables") -Context "fetch source repo vars: $srcFull"
        }
        catch {
            $repoVarsJson = $null
        }

        if ($repoVarsJson) {
            $repoVarsObj = $repoVarsJson | ConvertFrom-Json
            $vars = @()
            if ($null -ne $repoVarsObj.variables) {
                $vars = @($repoVarsObj.variables)
            }

            foreach ($v in $vars) {
                $n = [string]$v.name
                $val = [string]$v.value

                try {
                    Gh-Target -Args @(
                        "-X", "POST",
                        "/repos/$t_org/$t_repo/actions/variables",
                        "-f", "name=$n",
                        "-f", "value=$val"
                    ) -Context "create repo var: $tgtFull / $n" | Out-Null
                    $localRepoRepoVars++
                    $script:TOTAL_REPO_VARS_SYNCED++
                }
                catch {
                    try {
                        Gh-Target -Args @(
                            "-X", "PATCH",
                            "/repos/$t_org/$t_repo/actions/variables/$n",
                            "-f", "name=$n",
                            "-f", "value=$val"
                        ) -Context "update repo var: $tgtFull / $n" | Out-Null
                        $localRepoRepoVars++
                        $script:TOTAL_REPO_VARS_SYNCED++
                    }
                    catch {
                        Log-Warn "Failed to sync repo var: $tgtFull / $n"
                        $localFailed++
                    }
                }
            }
        }

        Log-Success "Repo vars sync completed for $tgtFull (count=$localRepoRepoVars)"

        # --- 3. ENVIRONMENTS ---
        Log-Info "Syncing Environments"
        $envsJson = $null
        try {
            $envsJson = Gh-Source -Args @("/repos/$s_org/$s_repo/environments") -Context "fetch source environments: $srcFull"
        }
        catch {
            $envsJson = $null
        }

        if ($envsJson) {
            $envsObj = $envsJson | ConvertFrom-Json
            $envNames = @()
            if ($null -ne $envsObj.environments) {
                $envNames = @($envsObj.environments | ForEach-Object { $_.name })
            }

            foreach ($envName in $envNames) {
                Sync-EnvironmentData -SrcFull $srcFull -TgtFull $tgtFull -EnvName ([string]$envName) -ReviewerHandle $reviewer_handle
                $localRepoEnvs++
            }
        }
        else {
            Log-Info "No environments found for $srcFull"
        }

        if ($localFailed -eq 0) {
            $script:SUCCESS_REPOS++
            Log-Success "Repository summary [$srcFull -> $tgtFull] :: org_vars=$localRepoOrgVars repo_vars=$localRepoRepoVars envs=$localRepoEnvs failures=0"
        }
        else {
            $script:FAILED_REPOS++
            Log-Warn "Repository summary [$srcFull -> $tgtFull] :: org_vars=$localRepoOrgVars repo_vars=$localRepoRepoVars envs=$localRepoEnvs failures=$localFailed"
        }
    }

    Log-Success "Migration Complete."
    Log-Info "Final Summary :: repos_processed=$($script:TOTAL_REPOS) repos_succeeded=$($script:SUCCESS_REPOS) repos_failed=$($script:FAILED_REPOS) repos_skipped=$($script:SKIPPED_REPOS) org_vars_synced=$($script:TOTAL_ORG_VARS_SYNCED) repo_vars_synced=$($script:TOTAL_REPO_VARS_SYNCED) envs_processed=$($script:TOTAL_ENVS_SYNCED) env_rules_synced=$($script:TOTAL_ENV_RULES_SYNCED) env_vars_synced=$($script:TOTAL_ENV_VARS_SYNCED)"
}

Main
 