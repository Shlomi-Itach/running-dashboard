<#
  ci-sync.ps1  —  runs inside GitHub Actions (non-interactive).
  Uses repo secrets (env vars) to refresh the Strava token, fetch all
  activities, and write strava-data.js. No browser, no client secret in
  the page — the secret lives only in GitHub Secrets.

  Required env vars:
    STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET, STRAVA_REFRESH_TOKEN
#>
$ErrorActionPreference = 'Stop'

$cid = $env:STRAVA_CLIENT_ID
$sec = $env:STRAVA_CLIENT_SECRET
$rt  = $env:STRAVA_REFRESH_TOKEN
if (-not $cid -or -not $sec -or -not $rt) { throw "Missing STRAVA_* secrets." }

Write-Host "Refreshing Strava token..."
$tok = Invoke-RestMethod -Uri "https://www.strava.com/oauth/token" -Method Post -Body @{
    client_id     = $cid
    client_secret = $sec
    grant_type    = 'refresh_token'
    refresh_token = $rt
}
$headers = @{ Authorization = "Bearer $($tok.access_token)" }

Write-Host "Fetching activities..."
$all  = @()
$page = 1
do {
    $uri   = "https://www.strava.com/api/v3/athlete/activities?per_page=200&page=$page"
    $batch = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    if ($batch) { $all += $batch }
    $page++
} while ($batch -and $batch.Count -eq 200)
Write-Host "Got $($all.Count) activities."

$keep = 'Run|Elliptical|WeightTraining|Workout|Crossfit|Hiit'
$acts = $all | Where-Object { $_.type -match $keep } | ForEach-Object {
    [pscustomobject]@{
        id          = $_.id
        name        = $_.name
        type        = $_.type
        date        = $_.start_date_local
        distance    = $_.distance
        moving_time = $_.moving_time
        elapsed     = $_.elapsed_time
        avg_speed   = $_.average_speed
        max_speed   = $_.max_speed
        avg_hr      = $_.average_heartrate
        max_hr      = $_.max_heartrate
        elev_gain   = $_.total_elevation_gain
        avg_cadence = $_.average_cadence
        suffer      = $_.suffer_score
        calories    = $_.kilojoules
    }
}
$acts = @($acts)
Write-Host "Kept $($acts.Count) (runs/elliptical/strength)."

$json = if ($acts.Count -eq 0) { "[]" }
        elseif ($acts.Count -eq 1) { "[" + ($acts[0] | ConvertTo-Json -Depth 4 -Compress) + "]" }
        else { $acts | ConvertTo-Json -Depth 4 }

$payload = "window.STRAVA_DATA = $json;`nwindow.STRAVA_SYNCED_AT = '" + (Get-Date -Format 's') + "';"
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path (Get-Location) 'strava-data.js'), $payload, $enc)
Write-Host "Wrote strava-data.js"
