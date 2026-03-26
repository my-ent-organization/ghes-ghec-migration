#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# GHES -> GHEC: COMPLETE SYNC (ORG, REPO, ENV VARS + RULES)
# ============================================================
CSV_FILE="${CSV_FILE:-repos.csv}"
GH_PAT="${GH_PAT:?Set GH_PAT}"
GH_SOURCE_PAT="${GH_SOURCE_PAT:?Set GH_SOURCE_PAT}"
GHES_API_URL="${GHES_API_URL:?Set GHES_API_URL}"
GH_TARGET_HOST="${GH_TARGET_HOST:-github.com}"
GH_HEADERS=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

# --- Parse host (netloc) from GHES_API_URL, keeping optional :port ---
# Equivalent intent to: urlparse(...).netloc
SOURCE_HOST="$GHES_API_URL"
[[ "$SOURCE_HOST" != *"://"* ]] && SOURCE_HOST="https://$SOURCE_HOST"
SOURCE_HOST="${SOURCE_HOST#*://}" # drop scheme
SOURCE_HOST="${SOURCE_HOST%%/*}"  # drop path/query/fragment

# --- URL encode (percent-encode) ---
# Equivalent intent to: urllib.parse.quote(env_name)
urlencode() {
  local s="$1"
  local out="" i c hex
  LC_ALL=C
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *)
        printf -v hex '%02X' "'$c"
        out+="%$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

gh_source() { GH_TOKEN="$GH_SOURCE_PAT" gh api --hostname "$SOURCE_HOST" "${GH_HEADERS[@]}" "$@"; }
gh_target() { GH_TOKEN="$GH_PAT" gh api --hostname "$GH_TARGET_HOST" "${GH_HEADERS[@]}" "$@"; }

get_reviewer_id() {
  local handle="$1"
  gh_target "/users/$handle" --jq '.id' 2>/dev/null || echo ""
}

sync_environment_data() {
  local src_full="$1" tgt_full="$2" env_name="$3" reviewer_handle="$4"
  local env_enc
  env_enc="$(urlencode "$env_name")"

  # --- 1. SYNC PROTECTION RULES ---
  local src_env_json reviewer_id payload
  src_env_json="$(gh_source "/repos/$src_full/environments/$env_enc" 2>/dev/null || echo "{}")"
  reviewer_id=""
  [[ -n "${reviewer_handle:-}" ]] && reviewer_id="$(get_reviewer_id "$reviewer_handle")"

  payload="$(
    printf '%s' "$src_env_json" |
    jq -c --arg rev_id "$reviewer_id" '
      try (
        (.protection_rules // []) as $rules
        | (
            $rules
            | map(select(.type=="wait_timer") | (.wait_timer // 0))
            | .[0]
          ) as $wt
        | (
            $rules
            | map(select(.type=="required_reviewers"))
            | .[0]
          ) as $rr
        | {}
          + (if $wt == null then {} else {wait_timer:$wt} end)
          + (if ($rr != null) and ($rev_id|length>0)
             then {
               reviewers: [ {type:"User", id: ($rev_id|tonumber)} ],
               prevent_self_review: ($rr.prevent_self_review // false)
             }
             else {}
             end)
      ) catch {}'
  )"

  gh_target -X PUT "/repos/$tgt_full/environments/$env_enc" --input - <<<"$payload" >/dev/null
  log " + Env '$env_name' rules synced."

  # --- 2. SYNC ENVIRONMENT VARIABLES ---
  # We need the numeric ID of the repo for the Env Var API
  local src_repo_id tgt_repo_id
  src_repo_id="$(gh_source "/repos/$src_full" --jq '.id')"
  tgt_repo_id="$(gh_target "/repos/$tgt_full" --jq '.id')"

  gh_source "/repositories/$src_repo_id/environments/$env_enc/variables" --jq '.variables[] | "\(.name)\t\(.value)"' 2>/dev/null |
  while IFS=$'\t' read -r vname vval; do
    gh_target -X POST "/repositories/$tgt_repo_id/environments/$env_enc/variables" -f "name=$vname" -f "value=$vval" >/dev/null 2>&1 ||
    gh_target -X PATCH "/repositories/$tgt_repo_id/environments/$env_enc/variables/$vname" -f "name=$vname" -f "value=$vval" >/dev/null
    log " - Env Var: $vname synced"
  done
}

main() {
  log "Starting GHES -> GHEC Full Migration"
  declare -A seen_orgs

  sed 's/\r$//' "$CSV_FILE" |
  tail -n +2 |
  while IFS=',' read -r s_org s_repo r_url r_size t_org t_repo t_vis reviewer_handle; do
    src_org="$(echo "$s_org" | xargs)"; src_repo="$(echo "$s_repo" | xargs)"
    tgt_org="$(echo "$t_org" | xargs)"; tgt_repo="$(echo "$t_repo" | xargs)"
    reviewer_handle="$(echo "${reviewer_handle:-}" | xargs)"
    [[ -z "$src_org" ]] && continue

    log "Processing: $src_org/$src_repo -> $tgt_org/$tgt_repo"

    # --- 1. ORG VARIABLES ---
    if [[ -z "${seen_orgs["$src_org"]+x}" ]]; then
      log " -> Syncing Org Vars for $tgt_org"
      gh_source "/orgs/$src_org/actions/variables" --jq '.variables[] | "\(.name)\t\(.value)"' 2>/dev/null |
      while IFS=$'\t' read -r n v; do
        gh_target -X POST "/orgs/$tgt_org/actions/variables" -f "name=$n" -f "value=$v" -f "visibility=all" >/dev/null 2>&1 ||
        gh_target -X PATCH "/orgs/$tgt_org/actions/variables/$n" -f "name=$n" -f "value=$v" >/dev/null 2>&1 || true
      done
      seen_orgs["$src_org"]=1
    fi

    # --- 2. REPO VARIABLES ---
    log " -> Syncing Repo Vars"
    gh_source "/repos/$src_org/$src_repo/actions/variables" --jq '.variables[] | "\(.name)\t\(.value)"' 2>/dev/null |
    while IFS=$'\t' read -r n v; do
      gh_target -X POST "/repos/$tgt_org/$tgt_repo/actions/variables" -f "name=$n" -f "value=$v" >/dev/null 2>&1 ||
      gh_target -X PATCH "/repos/$tgt_org/$tgt_repo/actions/variables/$n" -f "name=$n" -f "value=$v" >/dev/null 2>&1 || true
    done

    # --- 3. ENVIRONMENTS (Rules + Vars) ---
    log " -> Syncing Environments"
    local envs
    envs="$(gh_source "/repos/$src_org/$src_repo/environments" --jq '.environments[].name' 2>/dev/null || echo "")"
    for env in $envs; do
      sync_environment_data "$src_org/$src_repo" "$tgt_org/$tgt_repo" "$env" "$reviewer_handle"
    done
  done

  log "Migration Complete."
}

main
