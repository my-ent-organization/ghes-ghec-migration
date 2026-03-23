#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# GHES -> GHEC: COMPLETE SYNC (ORG, REPO, ENV VARS + RULES)
# ============================================================

# Env inputs (match bash behavior)
$CSV_FILE       = if ($env:CSV_FILE) { $env:CSV_FILE } else { "repos.csv" }
$GH_PAT         = $env:GH_PAT;         if (-not $GH_PAT)         { throw "Set GH_PAT" }
$GH_SOURCE_PAT  = $env:GH_SOURCE_PAT;  if (-not $GH_SOURCE_PAT)  { throw "Set GH_SOURCE_PAT" }
$GHES_API_URL   = $env:GHES_API_URL;   if (-not $GHES_API_URL)   { throw "Set GHES_API_URL" }

# Headers (same as bash)
$GH_HEADERS = @(
  "-H", "Accept: application/vnd.github+json",
  "-H", "X-GitHub-Api-Version: 2022-11-28"
)

function Log([string]$Message) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts] $Message"
}

# --- Parse SOURCE_HOST from GHES_API_URL (scheme optional) ---
# Accepts:
# - https://ghe.company.com/api/v3
# - ghe.company.com/api/v3
# - ghe.company.com:8443/api/v3
$sourceUrlText = $GHES_API_URL
if ($sourceUrlText -notmatch "^\w+://") { $sourceUrlText = "https://$sourceUrlText" }
$sourceUri = [Uri]$sourceUrlText
$SOURCE_HOST = if ($sourceUri.IsDefaultPort) { $sourceUri.Host } else { "$($sourceUri.Host):$($sourceUri.Port)" }

function UrlEncode([string]$s) {
  # Equivalent intent to urllib.parse.quote
  return [Uri]::EscapeDataString($s)
}

function Invoke-GhApi {
  param(
    [Parameter(Mandatory=$true)][string]$HostName,
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string[]]$Args,
    [string]$Stdin = $null
  )

  $old = $env:GH_TOKEN
  try {
    $env:GH_TOKEN = $Token

    if ($null -ne $Stdin) {
      $out = $Stdin | & gh api --hostname $HostName @GH_HEADERS @Args 2>$null
    } else {
      $out = & gh api --hostname $HostName @GH_HEADERS @Args 2>$null
    }

    return $out
  }
  finally {
    $env:GH_TOKEN = $old
  }
}

function Gh-Source {
  param([Parameter(Mandatory=$true)][string[]]$Args, [string]$Stdin = $null)
  return Invoke-GhApi -HostName $SOURCE_HOST -Token $GH_SOURCE_PAT -Args $Args -Stdin $Stdin
}

function Gh-Target {
  param([Parameter(Mandatory=$true)][string[]]$Args, [string]$Stdin = $null)
  return Invoke-GhApi -HostName "github.com" -Token $GH_PAT -Args $Args -Stdin $Stdin
}

function Get-ReviewerId {
  param([Parameter(Mandatory=$true)][string]$Handle)

  try {
    $json = Gh-Target -Args @("/users/$Handle")
    $obj = $json | ConvertFrom-Json
    if ($null -ne $obj.id) { return [string]$obj.id }
  } catch {
    # match bash behavior: return "" on errors
  }
  return ""
}

function Sync-EnvironmentData {
  param(
    [Parameter(Mandatory=$true)][string]$SrcFull,
    [Parameter(Mandatory=$true)][string]$TgtFull,
    [Parameter(Mandatory=$true)][string]$EnvName,
    [string]$ReviewerHandle
  )

  $env_enc = UrlEncode $EnvName

  # --- 1. SYNC PROTECTION RULES ---
  $src_env_json = "{}"
  try {
    $tmp = Gh-Source -Args @("/repos/$SrcFull/environments/$env_enc")
    if ($tmp) { $src_env_json = $tmp } else { $src_env_json = "{}" }
  } catch {
    $src_env_json = "{}"
  }

  $reviewer_id = ""
  if ($ReviewerHandle) {
    $reviewer_id = Get-ReviewerId -Handle $ReviewerHandle
  }

  $payloadObj = @{}
  try {
    $src = $src_env_json | ConvertFrom-Json

    $rules = @()
    if ($null -ne $src.protection_rules) { $rules = @($src.protection_rules) }

    foreach ($r in $rules) {
      if ($null -eq $r) { continue }

      if ($r.type -eq "wait_timer") {
        $payloadObj["wait_timer"] = if ($null -ne $r.wait_timer) { [int]$r.wait_timer } else { 0 }
      }

      if ($r.type -eq "required_reviewers" -and $reviewer_id) {
        $payloadObj["reviewers"] = @(@{ type = "User"; id = [int]$reviewer_id })
        $payloadObj["prevent_self_review"] = if ($null -ne $r.prevent_self_review) { [bool]$r.prevent_self_review } else { $false }
      }
    }
  } catch {
    $payloadObj = @{}
  }

  $payload = ($payloadObj | ConvertTo-Json -Compress)

  Gh-Target -Args @("-X","PUT","/repos/$TgtFull/environments/$env_enc","--input","-") -Stdin $payload | Out-Null
  Log "    + Env '$EnvName' rules synced."

  # --- 2. SYNC ENVIRONMENT VARIABLES ---
  # We need numeric repo ID for env var API
  $src_repo_id = ((Gh-Source -Args @("/repos/$SrcFull")) | ConvertFrom-Json).id
  $tgt_repo_id = ((Gh-Target -Args @("/repos/$TgtFull")) | ConvertFrom-Json).id

  $varsJson = $null
  try {
    $varsJson = Gh-Source -Args @("/repositories/$src_repo_id/environments/$env_enc/variables")
  } catch {
    $varsJson = $null
  }

  if ($varsJson) {
    $varsObj = $varsJson | ConvertFrom-Json
    $vars = @()
    if ($null -ne $varsObj.variables) { $vars = @($varsObj.variables) }

    foreach ($v in $vars) {
      $vname = [string]$v.name
      $vval  = [string]$v.value

      # Try POST; if fails then PATCH (same logic as bash)
      try {
        Gh-Target -Args @(
          "-X","POST",
          "/repositories/$tgt_repo_id/environments/$env_enc/variables",
          "-f","name=$vname",
          "-f","value=$vval"
        ) | Out-Null
      } catch {
        Gh-Target -Args @(
          "-X","PATCH",
          "/repositories/$tgt_repo_id/environments/$env_enc/variables/$vname",
          "-f","name=$vname",
          "-f","value=$vval"
        ) | Out-Null
      }

      Log "      - Env Var: $vname synced"
    }
  }
}

function Main {
  Log "Starting GHES -> GHEC Full Migration"
  $seen_orgs = @{}

  if (-not (Test-Path -LiteralPath $CSV_FILE)) {
    throw "CSV file not found: $CSV_FILE"
  }

  $lines = Get-Content -LiteralPath $CSV_FILE | ForEach-Object { $_ -replace "`r$","" }
  if ($lines.Count -lt 2) {
    Log "Migration Complete."
    return
  }

  # skip header (tail -n +2)
  foreach ($line in $lines[1..($lines.Count-1)]) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    # Mirror bash: IFS=',' read -r ... (no CSV quoting support)
    $parts = $line -split ",", 8
    while ($parts.Count -lt 8) { $parts += "" }

    $s_org  = $parts[0].Trim()
    $s_repo = $parts[1].Trim()
    $t_org  = $parts[4].Trim()
    $t_repo = $parts[5].Trim()
    $reviewer_handle = $parts[7].Trim()

    if (-not $s_org) { continue }

    Log "Processing: $s_org/$s_repo -> $t_org/$t_repo"

    # --- 1. ORG VARIABLES ---
    if (-not $seen_orgs.ContainsKey($s_org)) {
      Log "  -> Syncing Org Vars for $t_org"

      $orgVarsJson = $null
      try { $orgVarsJson = Gh-Source -Args @("/orgs/$s_org/actions/variables") } catch { $orgVarsJson = $null }

      if ($orgVarsJson) {
        $orgVarsObj = $orgVarsJson | ConvertFrom-Json
        $vars = @()
        if ($null -ne $orgVarsObj.variables) { $vars = @($orgVarsObj.variables) }

        foreach ($v in $vars) {
          $n = [string]$v.name
          $val = [string]$v.value

          try {
            Gh-Target -Args @(
              "-X","POST",
              "/orgs/$t_org/actions/variables",
              "-f","name=$n",
              "-f","value=$val",
              "-f","visibility=all"
            ) | Out-Null
          } catch {
            try {
              Gh-Target -Args @(
                "-X","PATCH",
                "/orgs/$t_org/actions/variables/$n",
                "-f","name=$n",
                "-f","value=$val"
              ) | Out-Null
            } catch {
              # || true
            }
          }
        }
      }

      $seen_orgs[$s_org] = 1
    }

    # --- 2. REPO VARIABLES ---
    Log "  -> Syncing Repo Vars"

    $repoVarsJson = $null
    try { $repoVarsJson = Gh-Source -Args @("/repos/$s_org/$s_repo/actions/variables") } catch { $repoVarsJson = $null }

    if ($repoVarsJson) {
      $repoVarsObj = $repoVarsJson | ConvertFrom-Json
      $vars = @()
      if ($null -ne $repoVarsObj.variables) { $vars = @($repoVarsObj.variables) }

      foreach ($v in $vars) {
        $n = [string]$v.name
        $val = [string]$v.value

        try {
          Gh-Target -Args @(
            "-X","POST",
            "/repos/$t_org/$t_repo/actions/variables",
            "-f","name=$n",
            "-f","value=$val"
          ) | Out-Null
        } catch {
          try {
            Gh-Target -Args @(
              "-X","PATCH",
              "/repos/$t_org/$t_repo/actions/variables/$n",
              "-f","name=$n",
              "-f","value=$val"
            ) | Out-Null
          } catch {
            # || true
          }
        }
      }
    }

    # --- 3. ENVIRONMENTS (Rules + Vars) ---
    Log "  -> Syncing Environments"

    $envsJson = $null
    try { $envsJson = Gh-Source -Args @("/repos/$s_org/$s_repo/environments") } catch { $envsJson = $null }

    if ($envsJson) {
      $envsObj = $envsJson | ConvertFrom-Json
      $envNames = @()
      if ($null -ne $envsObj.environments) { $envNames = @($envsObj.environments | ForEach-Object { $_.name }) }

      foreach ($envName in $envNames) {
        Sync-EnvironmentData -SrcFull "$s_org/$s_repo" -TgtFull "$t_org/$t_repo" -EnvName ([string]$envName) -ReviewerHandle $reviewer_handle
      }
    }
  }

  Log "Migration Complete."
}

Main
