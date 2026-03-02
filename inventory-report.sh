#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
read -p "Enter the GHES_HOST URL: " GHES_HOST
read -p "Enter the ORG name: " ORG

# Token must be set
: "${GH_SOURCE_PAT:?Environment variable GH_SOURCE_PAT is not set}"

API_BASE="${GHES_HOST}/api/v3"
OUT_FILE="repos.csv"

# ----------------------------
# Helpers
# ----------------------------
# Extract the "next" URL from the Link header (pagination)
get_next_link() {
  local headers_file="$1"
  awk -F': ' 'tolower($1)=="link"{print $2}' "$headers_file" \
    | tr ',' '\n' \
    | sed -n 's/.*<\(.*\)>; rel="next".*/\1/p' \
    | head -n 1
}

# ----------------------------
# Main
# ----------------------------
echo "ghes_org,ghes_repo,repo_url,repo_size_MB" > "$OUT_FILE"

url="${API_BASE}/orgs/${ORG}/repos?per_page=100&type=all"
tmp_headers="$(mktemp)"
tmp_body="$(mktemp)"

while [[ -n "${url}" ]]; do
  curl -sS -D "$tmp_headers" -o "$tmp_body" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_SOURCE_PAT}" \
    "$url"

  # size is returned in KB -> convert to MB (2 decimals)
  # include html_url (web URL) if present in response
  jq -r '
    .[] |
    "\(.owner.login),\(.name),\(.html_url // ""),\((.size / 1024 * 100 | round) / 100)"
  ' "$tmp_body" >> "$OUT_FILE"

  url="$(get_next_link "$tmp_headers")"
done

rm -f "$tmp_headers" "$tmp_body"
echo "Done. Wrote: ${OUT_FILE}"