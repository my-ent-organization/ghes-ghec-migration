#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GHES -> GHEC VARIABLES + ENVIRONMENTS (+best-effort rules)
#   - Org Actions variables
#   - Repo Actions variables
#   - Environments (create/ensure)
#   - Environment-scoped variables
#   - Environment protection rules (best-effort)
#
# Minimal required exports:
#   export GH_PAT="..."            # GHEC PAT
#   export GH_SOURCE_PAT="..."     # GHES PAT
#   export GHES_API_URL="https://<ghes-host>/api/v3"
#
# Optional:
#   export CSV_FILE="repos.csv"
#   export DRY_RUN=true|false
#   export OVERWRITE=true|false
#   export MIGRATE_ENV_PROTECTION=true|false
#
# ============================================================

CSV_FILE="${CSV_FILE:-repos.csv}"

# Minimal required inputs
GH_PAT="${GH_PAT:?Set GH_PAT (Target GHEC PAT)}"
GH_SOURCE_PAT="${GH_SOURCE_PAT:?Set GH_SOURCE_PAT (Source GHES PAT)}"
GHES_API_URL="${GHES_API_URL:?Set GHES_API_URL (e.g. https://ghe.company.com/api/v3)}"

# GitHub REST API version: default to most compatible
API_VERSION="${API_VERSION:-2022-11-28}"  # GitHub default REST API version [4](https://stackoverflow.com/questions/76576013/how-to-get-a-list-of-environment-variables-in-github-actions)

# Behavior toggles
DRY_RUN="${DRY_RUN:-false}"
OVERWRITE="${OVERWRITE:-true}"

MIGRATE_ORG_VARS="${MIGRATE_ORG_VARS:-true}"
MIGRATE_REPO_VARS="${MIGRATE_REPO_VARS:-true}"
MIGRATE_ENVS="${MIGRATE_ENVS:-true}"
MIGRATE_ENV_VARS="${MIGRATE_ENV_VARS:-true}"
MIGRATE_ENV_PROTECTION="${MIGRATE_ENV_PROTECTION:-true}"  # env protection rules best-effort [2](https://docs.github.com/en/rest/actions/variables)

TARGET_HOST="${TARGET_HOST:-github.com}"

LOG_DIR="${LOG_DIR:-./var-migration-logs}"
mkdir -p "$LOG_DIR"

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need_cmd gh
need_cmd python3

# Use array headers (prevents malformed header argument issues)
GH_HEADERS=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: ${API_VERSION}") # [4](https://stackoverflow.com/questions/76576013/how-to-get-a-list-of-environment-variables-in-github-actions)

# -----------------------------
# Helpers
# -----------------------------
parse_host_from_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse
u = sys.argv[1].strip()
if "://" not in u:
  u = "https://" + u
p = urlparse(u)
print(p.netloc)
PY
}

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

json_payload_var() {
  # name value visibility ids_csv(optional)
  python3 - "$@" <<'PY'
import json, sys
name = sys.argv[1]
value = sys.argv[2]
visibility = sys.argv[3] if len(sys.argv) > 3 else None
ids_csv = sys.argv[4] if len(sys.argv) > 4 else ""
payload = {"name": name, "value": value}
if visibility:
  payload["visibility"] = visibility
  if visibility == "selected":
    ids = [int(x) for x in ids_csv.split(",") if x.strip()]
    payload["selected_repository_ids"] = ids
print(json.dumps(payload))
PY
}

build_env_payload() {
  # args: wait_timer|null  prevent_self_review|null  reviewers_json|null  dbp_json|null
  python3 - "$@" <<'PY'
import json, sys

def norm(x):
  x = (x or "").strip()
  return "null" if x == "" else x

wait_timer = norm(sys.argv[1])
prevent = norm(sys.argv[2])
reviewers_json = norm(sys.argv[3])
dbp_json = norm(sys.argv[4])

payload = {}

if wait_timer != "null":
  try:
    payload["wait_timer"] = int(wait_timer)
  except Exception:
    pass

if prevent != "null":
  payload["prevent_self_review"] = (prevent.lower() == "true")

if reviewers_json != "null":
  try:
    payload["reviewers"] = json.loads(reviewers_json)
  except Exception:
    pass

if dbp_json == "null":
  payload["deployment_branch_policy"] = None
else:
  try:
    payload["deployment_branch_policy"] = json.loads(dbp_json)
  except Exception:
    payload["deployment_branch_policy"] = None

print(json.dumps(payload))
PY
}

gh_api() {
  local host="$1"; shift
  local method="$1"; shift
  local path="$1"; shift
  local body="${1:-}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY_RUN] gh api --hostname ${host} -X ${method} ${path} ${body:+(json body)}"
    return 0
  fi

  if [[ -n "$body" ]]; then
    gh api --hostname "$host" -X "$method" "${GH_HEADERS[@]}" "$path" --input - <<<"$body"
  else
    gh api --hostname "$host" -X "$method" "${GH_HEADERS[@]}" "$path"
  fi
}

gh_api_jq() {
  local host="$1"; shift
  local path="$1"; shift
  local jqexpr="$1"; shift

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY_RUN] gh api --hostname ${host} --paginate ${path} --jq '${jqexpr}'"
    return 0
  fi

  gh api --hostname "$host" --paginate "${GH_HEADERS[@]}" "$path" --jq "$jqexpr"
}

ensure_auth() {
  local host="$1"
  local token="$2"

  if gh auth status --hostname "$host" >/dev/null 2>&1; then
    log "Already authenticated to $host"
    return 0
  fi

  log "Authenticating gh CLI to $host"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY_RUN] echo *** | gh auth login --hostname $host --with-token"
    return 0
  fi

  echo "$token" | gh auth login --hostname "$host" --with-token >/dev/null
}

# Derived hosts
SOURCE_HOST="$(parse_host_from_url "$GHES_API_URL")"

# -----------------------------
# CSV mapping (no subshell)
# -----------------------------
declare -A SRC_TO_TGT_REPO   # "ghes_org/ghes_repo" -> "github_org/github_repo"
declare -A ORG_MAP_SEEN      # "ghes_org->github_org" -> 1

build_mappings() {
  log "Reading CSV: $CSV_FILE"
  [[ -f "$CSV_FILE" ]] || { echo "CSV file not found: $CSV_FILE" >&2; exit 1; }

  local header
  header="$(head -n 1 "$CSV_FILE")"
  for col in ghes_org ghes_repo github_org github_repo; do
    if ! echo "$header" | grep -q "$col"; then
      echo "CSV missing required column: $col" >&2
      exit 1
    fi
  done

  while IFS=',' read -r ghes_org ghes_repo repo_url repo_size_MB github_org github_repo gh_repo_visibility; do
    ghes_org="$(echo "${ghes_org:-}" | xargs)"
    ghes_repo="$(echo "${ghes_repo:-}" | xargs)"
    github_org="$(echo "${github_org:-}" | xargs)"
    github_repo="$(echo "${github_repo:-}" | xargs)"

    [[ -n "$ghes_org" && -n "$ghes_repo" && -n "$github_org" && -n "$github_repo" ]] || continue
    SRC_TO_TGT_REPO["$ghes_org/$ghes_repo"]="$github_org/$github_repo"
    ORG_MAP_SEEN["$ghes_org->$github_org"]=1
  done < <(tail -n +2 "$CSV_FILE")
}

# -----------------------------
# Upsert: Org + Repo variables (Actions Variables API)
# -----------------------------
upsert_org_var() {
  local tgt_org="$1" name="$2" value="$3" visibility="$4" selected_ids_csv="${5:-}"
  local payload
  payload="$(json_payload_var "$name" "$value" "$visibility" "$selected_ids_csv")"

  # Org variables endpoints [1](https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2022-11-++28)
  if gh api --hostname "$TARGET_HOST" "${GH_HEADERS[@]}" "/orgs/${tgt_org}/actions/variables/${name}" >/dev/null 2>&1; then
    if [[ "$OVERWRITE" == "true" ]]; then
      gh_api "$TARGET_HOST" "PATCH" "/orgs/${tgt_org}/actions/variables/${name}" "$payload" >/dev/null
      log "ORG VAR updated: $tgt_org :: $name"
    else
      log "ORG VAR exists (skipped): $tgt_org :: $name"
    fi
  else
    gh_api "$TARGET_HOST" "POST" "/orgs/${tgt_org}/actions/variables" "$payload" >/dev/null
    log "ORG VAR created: $tgt_org :: $name"
  fi
}

upsert_repo_var() {
  local tgt_full="$1" name="$2" value="$3"
  local payload
  payload="$(json_payload_var "$name" "$value" "")"

  # Repo variables endpoints [1](https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2022-11-++28)
  if gh api --hostname "$TARGET_HOST" "${GH_HEADERS[@]}" "/repos/${tgt_full}/actions/variables/${name}" >/dev/null 2>&1; then
    if [[ "$OVERWRITE" == "true" ]]; then
      gh_api "$TARGET_HOST" "PATCH" "/repos/${tgt_full}/actions/variables/${name}" "$payload" >/dev/null
      log "REPO VAR updated: $tgt_full :: $name"
    else
      log "REPO VAR exists (skipped): $tgt_full :: $name"
    fi
  else
    gh_api "$TARGET_HOST" "POST" "/repos/${tgt_full}/actions/variables" "$payload" >/dev/null
    log "REPO VAR created: $tgt_full :: $name"
  fi
}

# -----------------------------
# Env variables (repo_id + env_name endpoints)
# -----------------------------
upsert_env_var_by_repoid() {
  local tgt_repo_id="$1" env_name="$2" var_name="$3" var_value="$4"
  local payload env_enc
  payload="$(json_payload_var "$var_name" "$var_value" "")"
  env_enc="$(urlencode "$env_name")"

  # Env variable endpoints (list/get/create/update/delete) [3](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
  if gh api --hostname "$TARGET_HOST" "${GH_HEADERS[@]}" \
      "/repositories/${tgt_repo_id}/environments/${env_enc}/variables/${var_name}" >/dev/null 2>&1; then
    if [[ "$OVERWRITE" == "true" ]]; then
      gh_api "$TARGET_HOST" "PATCH" "/repositories/${tgt_repo_id}/environments/${env_enc}/variables/${var_name}" "$payload" >/dev/null
      log "ENV VAR updated: repo_id=$tgt_repo_id env=$env_name :: $var_name"
    else
      log "ENV VAR exists (skipped): repo_id=$tgt_repo_id env=$env_name :: $var_name"
    fi
  else
    gh_api "$TARGET_HOST" "POST" "/repositories/${tgt_repo_id}/environments/${env_enc}/variables" "$payload" >/dev/null
    log "ENV VAR created: repo_id=$tgt_repo_id env=$env_name :: $var_name"
  fi
}

# -----------------------------
# Environment create/update + protection rules (BEST-EFFORT)
# -----------------------------
resolve_target_reviewer_id() {
  local tgt_org="$1" rtype="$2" key="$3"
  if [[ "$rtype" == "User" ]]; then
    gh_api_jq "$TARGET_HOST" "/users/${key}" '.id' 2>/dev/null || echo ""
  else
    gh_api_jq "$TARGET_HOST" "/orgs/${tgt_org}/teams/${key}" '.id' 2>/dev/null || echo ""
  fi
}

ensure_environment_exists_and_protection() {
  local src_full="$1" tgt_full="$2" env_name="$3"
  local env_enc tgt_org
  env_enc="$(urlencode "$env_name")"
  tgt_org="${tgt_full%%/*}"

  # If rules not requested, just ensure env exists [2](https://docs.github.com/en/rest/actions/variables)
  if [[ "$MIGRATE_ENV_PROTECTION" != "true" ]]; then
    gh_api "$TARGET_HOST" "PUT" "/repos/${tgt_full}/environments/${env_enc}" "{}" >/dev/null
    log "ENV ensured (no rules): $tgt_full :: $env_name"
    return 0
  fi

  # Fetch source env details; if not JSON, skip rules and continue [2](https://docs.github.com/en/rest/actions/variables)
  local src_json=""
  src_json="$(gh api --hostname "$SOURCE_HOST" "${GH_HEADERS[@]}" "/repos/${src_full}/environments/${env_enc}" 2>/dev/null || true)"

  local is_json="false"
  is_json="$(python3 - <<'PY'
import sys, json
s=sys.stdin.read().strip()
if not s:
  print("false"); sys.exit(0)
try:
  json.loads(s)
  print("true")
except Exception:
  print("false")
PY
<<<"$src_json")"

  if [[ "$is_json" != "true" ]]; then
    gh_api "$TARGET_HOST" "PUT" "/repos/${tgt_full}/environments/${env_enc}" "{}" >/dev/null
    log "ENV ensured (rules skipped - source env details not JSON): $tgt_full :: $env_name"
    return 0
  fi

  # Extract rule components from source JSON [2](https://docs.github.com/en/rest/actions/variables)
  local wait_timer prevent_self_review dbp_json reviewers_lines reviewers_payload

  wait_timer="$(python3 - <<'PY'
import json,sys
try:
  j=json.loads(sys.stdin.read())
  wt=None
  for r in (j.get("protection_rules") or []):
    if r.get("type")=="wait_timer":
      wt=r.get("wait_timer")
  print("null" if wt is None else wt)
except Exception:
  print("null")
PY
<<<"$src_json")"

  prevent_self_review="$(python3 - <<'PY'
import json,sys
try:
  j=json.loads(sys.stdin.read())
  psr=None
  for r in (j.get("protection_rules") or []):
    if r.get("type")=="required_reviewers":
      psr=r.get("prevent_self_review")
  if psr is None:
    print("null")
  else:
    print("true" if psr else "false")
except Exception:
  print("null")
PY
<<<"$src_json")"

  dbp_json="$(python3 - <<'PY'
import json,sys
try:
  j=json.loads(sys.stdin.read())
  dbp=j.get("deployment_branch_policy",None)
  if dbp is None:
    print("null"); sys.exit(0)
  out={"protected_branches": bool(dbp.get("protected_branches", False)),
       "custom_branch_policies": bool(dbp.get("custom_branch_policies", False))}
  print(json.dumps(out))
except Exception:
  print("null")
PY
<<<"$src_json")"

  reviewers_lines="$(python3 - <<'PY'
import json,sys
try:
  j=json.loads(sys.stdin.read())
  for r in (j.get("protection_rules") or []):
    if r.get("type")=="required_reviewers":
      for it in (r.get("reviewers") or []):
        t=it.get("type")
        rv=it.get("reviewer") or {}
        if t=="User":
          login=rv.get("login")
          if login:
            print("User\t"+login)
        elif t=="Team":
          slug=rv.get("slug")
          if not slug:
            hu=(rv.get("html_url") or "").rstrip("/")
            if hu:
              slug=hu.split("/")[-1]
          if slug:
            print("Team\t"+slug)
except Exception:
  pass
PY
<<<"$src_json")"

  # Resolve reviewers to target IDs (best-effort)
  reviewers_payload="null"
  if [[ -n "${reviewers_lines:-}" ]]; then
    local tmp="[" first="true"
    while IFS=$'\t' read -r rtype key; do
      [[ -n "${rtype:-}" && -n "${key:-}" ]] || continue
      rid="$(resolve_target_reviewer_id "$tgt_org" "$rtype" "$key")"
      if [[ -n "${rid:-}" ]]; then
        if [[ "$first" == "true" ]]; then
          first="false"
        else
          tmp+=","
        fi
        tmp+="{\"type\":\"$rtype\",\"id\":$rid}"
      fi
    done <<<"$reviewers_lines"
    tmp+="]"
    if [[ "$tmp" != "[]" ]]; then
      reviewers_payload="$tmp"
    fi
  fi

  # Build target payload + PUT environment (create/update) [2](https://docs.github.com/en/rest/actions/variables)
  local payload
  payload="$(build_env_payload "$wait_timer" "$prevent_self_review" "$reviewers_payload" "$dbp_json")"

  gh_api "$TARGET_HOST" "PUT" "/repos/${tgt_full}/environments/${env_enc}" "$payload" >/dev/null
  log "ENV ensured + rules(best-effort): $tgt_full :: $env_name"
}

# -----------------------------
# Migration steps
# -----------------------------
migrate_org_vars() {
  local src_org="$1" tgt_org="$2"
  local out="$LOG_DIR/org-vars_${src_org}_to_${tgt_org}.log"
  log "Migrating ORG variables: $src_org -> $tgt_org" | tee -a "$out"

  # Org variables list endpoint [1](https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2022-11-++28)
  gh_api_jq "$SOURCE_HOST" "/orgs/${src_org}/actions/variables" \
    '.variables[] | [.name, (.value|tostring), .visibility] | @tsv' \
    | while IFS=$'\t' read -r name value visibility; do

      if [[ "$visibility" == "selected" ]]; then
        local selected_names selected_ids=()
        selected_names="$(gh_api_jq "$SOURCE_HOST" "/orgs/${src_org}/actions/variables/${name}/repositories" '.repositories[].name')"

        while IFS= read -r repo_name; do
          [[ -n "$repo_name" ]] || continue
          local tgt_full="${SRC_TO_TGT_REPO["$src_org/$repo_name"]:-}"
          if [[ -n "$tgt_full" ]]; then
            local rid
            rid="$(gh_api_jq "$TARGET_HOST" "/repos/${tgt_full}" '.id')"
            selected_ids+=("$rid")
          fi
        done <<<"$selected_names"

        local ids_csv
        ids_csv="$(IFS=,; echo "${selected_ids[*]:-}")"
        upsert_org_var "$tgt_org" "$name" "$value" "$visibility" "$ids_csv" | tee -a "$out"
      else
        upsert_org_var "$tgt_org" "$name" "$value" "$visibility" "" | tee -a "$out"
      fi
    done
}

migrate_repo_vars() {
  local src_full="$1" tgt_full="$2"
  local out="$LOG_DIR/repo-vars_${src_full//\//_}_to_${tgt_full//\//_}.log"
  log "Migrating REPO variables: $src_full -> $tgt_full" | tee -a "$out"

  # Repo variables list endpoint [1](https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2022-11-++28)
  gh_api_jq "$SOURCE_HOST" "/repos/${src_full}/actions/variables" \
    '.variables[] | [.name, (.value|tostring)] | @tsv' \
    | while IFS=$'\t' read -r name value; do
      upsert_repo_var "$tgt_full" "$name" "$value" | tee -a "$out"
    done
}

migrate_envs_and_env_vars() {
  local src_full="$1" tgt_full="$2"
  local out="$LOG_DIR/env_${src_full//\//_}_to_${tgt_full//\//_}.log"
  log "Migrating ENVIRONMENTS + VARS: $src_full -> $tgt_full" | tee -a "$out"

  local src_repo_id tgt_repo_id
  src_repo_id="$(gh_api_jq "$SOURCE_HOST" "/repos/${src_full}" '.id')"
  tgt_repo_id="$(gh_api_jq "$TARGET_HOST" "/repos/${tgt_full}" '.id')"

  # List environments endpoint [2](https://docs.github.com/en/rest/actions/variables)
  local envs
  envs="$(gh_api_jq "$SOURCE_HOST" "/repos/${src_full}/environments" '.environments[].name')"

  while IFS= read -r env_name; do
    [[ -n "$env_name" ]] || continue

    if [[ "$MIGRATE_ENVS" == "true" ]]; then
      ensure_environment_exists_and_protection "$src_full" "$tgt_full" "$env_name" | tee -a "$out"
    fi

    if [[ "$MIGRATE_ENV_VARS" == "true" ]]; then
      local env_enc
      env_enc="$(urlencode "$env_name")"

      # List environment variables endpoint (repo_id form) [3](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
      gh_api_jq "$SOURCE_HOST" "/repositories/${src_repo_id}/environments/${env_enc}/variables" \
        '.variables[] | [.name, (.value|tostring)] | @tsv' \
        | while IFS=$'\t' read -r vname vval; do
          upsert_env_var_by_repoid "$tgt_repo_id" "$env_name" "$vname" "$vval" | tee -a "$out"
        done
    fi
  done <<<"$envs"
}

# -----------------------------
# MAIN
# -----------------------------
main() {
  log "Starting GHES -> GHEC variables migration"
  log "CSV_FILE=$CSV_FILE"
  log "SOURCE_HOST=$SOURCE_HOST  TARGET_HOST=$TARGET_HOST"
  log "API_VERSION=$API_VERSION"
  log "DRY_RUN=$DRY_RUN  OVERWRITE=$OVERWRITE"
  log "ORG=$MIGRATE_ORG_VARS  REPO=$MIGRATE_REPO_VARS  ENVS=$MIGRATE_ENVS  ENV_VARS=$MIGRATE_ENV_VARS  ENV_RULES=$MIGRATE_ENV_PROTECTION"

  ensure_auth "$SOURCE_HOST" "$GH_SOURCE_PAT"
  ensure_auth "$TARGET_HOST" "$GH_PAT"

  build_mappings

  # 1) Org variables [1](https://docs.github.com/en/rest/about-the-rest-api/api-versions?apiVersion=2022-11-++28)
  if [[ "$MIGRATE_ORG_VARS" == "true" ]]; then
    for k in "${!ORG_MAP_SEEN[@]}"; do
      src_org="${k%%->*}"
      tgt_org="${k##*->}"
      migrate_org_vars "$src_org" "$tgt_org"
    done
  fi

  # 2) Repo + env per row
  while IFS=',' read -r ghes_org ghes_repo repo_url repo_size_MB github_org github_repo gh_repo_visibility; do
    ghes_org="$(echo "${ghes_org:-}" | xargs)"
    ghes_repo="$(echo "${ghes_repo:-}" | xargs)"
    github_org="$(echo "${github_org:-}" | xargs)"
    github_repo="$(echo "${github_repo:-}" | xargs)"

    [[ -n "$ghes_org" && -n "$ghes_repo" && -n "$github_org" && -n "$github_repo" ]] || continue

    src_full="${ghes_org}/${ghes_repo}"
    tgt_full="${github_org}/${github_repo}"

    if [[ "$MIGRATE_REPO_VARS" == "true" ]]; then
      migrate_repo_vars "$src_full" "$tgt_full"
    fi

    if [[ "$MIGRATE_ENVS" == "true" || "$MIGRATE_ENV_VARS" == "true" ]]; then
      migrate_envs_and_env_vars "$src_full" "$tgt_full"
    fi
  done < <(tail -n +2 "$CSV_FILE")

  log "Done. Logs are in: $LOG_DIR"
}

main "$@"
