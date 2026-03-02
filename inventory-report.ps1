#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------
# Config
# ----------------------------
$GHES_HOST = Read-Host "Enter the GHES_HOST URL"
$ORG       = Read-Host "Enter the ORG name"

# Token must be set
if ([string]::IsNullOrWhiteSpace($env:GH_SOURCE_PAT)) {
    throw "Environment variable GH_SOURCE_PAT is not set"
}

# Normalize host (trim trailing slash)
$GHES_HOST = $GHES_HOST.TrimEnd('/')
$API_BASE  = "$GHES_HOST/api/v3"
$OUT_FILE  = "repos.csv"

# ----------------------------
# Helpers
# ----------------------------
function Get-NextLink {
    param(
        [Parameter(Mandatory)]
        [object]$Headers
    )

    # GHES/GitHub uses RFC5988-style Link header:
    # <url1>; rel="next", <url2>; rel="last"
    $link = $null

    try {
        # Some PS versions expose Headers as dictionary-like
        $link = $Headers["Link"]
    } catch {
        $link = $null
    }

    if ([string]::IsNullOrWhiteSpace($link)) {
        return $null
    }

    $m = [regex]::Match($link, '<([^>]+)>\s*;\s*rel="next"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Escape-CsvField {
    param([string]$Value)
    if ($null -eq $Value) { return "" }

    # If field contains comma, quote, or newline -> quote and escape quotes
    if ($Value -match '[,"\r\n]') {
        $escaped = $Value -replace '"', '""'
        return '"' + $escaped + '"'
    }
    return $Value
}

# ----------------------------
# Main
# ----------------------------
"ghes_org,ghes_repo,repo_url,repo_size_MB" | Out-File -FilePath $OUT_FILE -Encoding utf8

$headers = @{
    "Accept"        = "application/vnd.github+json"
    "Authorization" = "Bearer $($env:GH_SOURCE_PAT)"
}

$url = "$API_BASE/orgs/$ORG/repos?per_page=100&type=all"

while (-not [string]::IsNullOrWhiteSpace($url)) {

    # Use Invoke-WebRequest so we can read the response headers for pagination
    $resp = Invoke-WebRequest -Method GET -Uri $url -Headers $headers

    # Body JSON -> objects
    $repos = $resp.Content | ConvertFrom-Json

    foreach ($r in $repos) {
        $owner = [string]$r.owner.login
        $name  = [string]$r.name
        $html  = [string]($r.html_url)
        $sizeKb = [double]($r.size)

        # size is returned in KB -> convert to MB (2 decimals)
        $sizeMb = [Math]::Round(($sizeKb / 1024.0), 2)

        $line = @(
            (Escape-CsvField $owner),
            (Escape-CsvField $name),
            (Escape-CsvField $html),
            $sizeMb
        ) -join ','

        Add-Content -Path $OUT_FILE -Value $line -Encoding utf8
    }

    $url = Get-NextLink -Headers $resp.Headers
}

Write-Host "Done. Wrote: $OUT_FILE"