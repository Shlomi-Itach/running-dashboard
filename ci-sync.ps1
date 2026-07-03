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
        z           = $null
    }
}
$acts = @($acts)
Write-Host "Kept $($acts.Count) (runs/elliptical/strength)."

# ---- time-in-zone: fetch HR streams for aerobic activities (incremental) ----
function Get-ZoneTimes($hr, $tm) {
    $z = @(0, 0, 0, 0, 0)   # zones 1..5 by our HR bounds: <136,136-150,150-163,163-177,>=177
    for ($i = 1; $i -lt $hr.Count; $i++) {
        $dt = $tm[$i] - $tm[$i - 1]
        if ($dt -le 0 -or $dt -gt 30) { $dt = 1 }   # guard pauses / gaps
        $h = $hr[$i]
        $b = if ($h -lt 136) { 0 } elseif ($h -lt 150) { 1 } elseif ($h -lt 163) { 2 } elseif ($h -lt 177) { 3 } else { 4 }
        $z[$b] += $dt
    }
    return , $z
}

# reuse zone data already computed (so we don't re-fetch streams every run)
$existingZ = @{}
$dataFile  = Join-Path (Get-Location) 'strava-data.js'
if (Test-Path $dataFile) {
    try {
        $old = Get-Content $dataFile -Raw
        $mm  = [regex]::Match($old, '(?s)window\.STRAVA_DATA\s*=\s*(\[.*\]);\s*window\.STRAVA_SYNCED_AT')
        if ($mm.Success) {
            (ConvertFrom-Json $mm.Groups[1].Value) | ForEach-Object { if ($_.z) { $existingZ[[string]$_.id] = $_.z } }
        }
    } catch { Write-Host "Could not read existing zones: $($_.Exception.Message)" }
}

$fetched = 0; $cap = 180
foreach ($a in $acts) {
    $idKey = [string]$a.id
    if ($existingZ.ContainsKey($idKey)) { $a.z = $existingZ[$idKey]; continue }
    if (-not $a.avg_hr) { continue }
    if ($a.type -match 'WeightTraining|Workout|Crossfit|Hiit') { continue }   # aerobic only
    if ($fetched -ge $cap) { continue }
    try {
        $s = Invoke-RestMethod -Uri "https://www.strava.com/api/v3/activities/$($a.id)/streams?keys=heartrate,time&key_by_type=true" -Headers $headers -Method Get
        if ($s.heartrate.data -and $s.time.data) { $a.z = Get-ZoneTimes $s.heartrate.data $s.time.data }
        $fetched++
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 429) {
            Write-Host "Rate limited after $fetched stream fetches - stopping (rest next run)."; break
        }
    }
}
Write-Host "Fetched HR streams for $fetched activities."

$json = if ($acts.Count -eq 0) { "[]" }
        elseif ($acts.Count -eq 1) { "[" + ($acts[0] | ConvertTo-Json -Depth 4 -Compress) + "]" }
        else { $acts | ConvertTo-Json -Depth 4 }

$payload = "window.STRAVA_DATA = $json;`nwindow.STRAVA_SYNCED_AT = '" + (Get-Date -Format 's') + "';"
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path (Get-Location) 'strava-data.js'), $payload, $enc)
Write-Host "Wrote strava-data.js"
