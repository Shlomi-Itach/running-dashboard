<#
=====================================================================
  sync-strava.ps1
  Pulls all your activities from Strava and writes them to
  strava-data.js so the dashboard (index.html) can display them.

  How to run (right-click > Run with PowerShell), or in a terminal:
    powershell -ExecutionPolicy Bypass -File .\sync-strava.ps1

  First run: you'll be asked for Client ID + Client Secret from
  https://www.strava.com/settings/api and to approve access in the
  browser. After that it remembers you and updates automatically.
=====================================================================
#>

$ErrorActionPreference = 'Stop'
$Root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile  = Join-Path $Root 'config.json'      # Client ID + Secret
$TokenFile   = Join-Path $Root 'tokens.json'      # access / refresh tokens
$DataFile    = Join-Path $Root 'strava-data.js'   # output for the dashboard
$Port        = 8721
$RedirectUri = "http://localhost:$Port/"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    $msg"    -ForegroundColor Green }

# ---------- save a UTF-8 file without BOM (for the .js output) ----------
function Save-Utf8NoBom($path, $text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

# ---------- 1. config: Client ID + Secret ----------
if (Test-Path $ConfigFile) {
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} else {
    Write-Step "First-time setup - your Strava app credentials"
    Write-Host "    Find them at: https://www.strava.com/settings/api" -ForegroundColor DarkGray
    $cid = Read-Host "    Client ID"
    $sec = Read-Host "    Client Secret"
    $cfg = [pscustomobject]@{ client_id = $cid.Trim(); client_secret = $sec.Trim() }
    Save-Utf8NoBom $ConfigFile ($cfg | ConvertTo-Json)
    Write-OK "Saved to config.json (local file, not shared)."
}

# ---------- 2. get an access token ----------
function Invoke-TokenRequest($body) {
    return Invoke-RestMethod -Uri "https://www.strava.com/oauth/token" -Method Post -Body $body
}

function Get-AccessToken {
    # If we already have a refresh token, just refresh.
    if (Test-Path $TokenFile) {
        $tok = Get-Content $TokenFile -Raw | ConvertFrom-Json
        if ($tok.refresh_token) {
            Write-Step "Refreshing existing authorization..."
            $resp = Invoke-TokenRequest @{
                client_id     = $cfg.client_id
                client_secret = $cfg.client_secret
                grant_type    = 'refresh_token'
                refresh_token = $tok.refresh_token
            }
            Save-Utf8NoBom $TokenFile ($resp | ConvertTo-Json)
            Write-OK "Authorization refreshed."
            return $resp.access_token
        }
    }

    # Otherwise run the full approval flow (first time).
    Write-Step "Authorize access to Strava (first time)"
    $scope   = 'activity:read_all'
    $authUrl = "https://www.strava.com/oauth/authorize?client_id=$($cfg.client_id)" +
               "&redirect_uri=$([uri]::EscapeDataString($RedirectUri))" +
               "&response_type=code&approval_prompt=auto&scope=$scope"

    $code = $null
    $listener = $null
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add($RedirectUri)
        $listener.Start()
        Write-Host "    Opening browser to approve access... (if it doesn't open, paste this URL):" -ForegroundColor DarkGray
        Write-Host "    $authUrl" -ForegroundColor DarkGray
        Start-Process $authUrl
        Write-Host "    Waiting for approval in the browser..." -ForegroundColor Yellow
        $context = $listener.GetContext()   # blocks until the redirect arrives
        $code    = $context.Request.QueryString['code']

        $resp = $context.Response
        $msg  = "<html><head><meta charset='utf-8'></head><body style='font-family:sans-serif;text-align:center;padding-top:60px'><h2>Authorization complete</h2><p>You can close this window and go back to PowerShell.</p></body></html>"
        $buf  = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $resp.ContentType = 'text/html; charset=utf-8'
        $resp.OutputStream.Write($buf, 0, $buf.Length)
        $resp.Close()
    }
    catch {
        Write-Host "    Could not listen automatically. Manual mode:" -ForegroundColor Yellow
        Write-Host "    1) Open this URL in a browser: $authUrl"
        Write-Host "    2) Approve. The browser jumps to a URL starting with $RedirectUri"
        Write-Host "    3) Copy the value of code= from that URL and paste it here."
        $code = (Read-Host "    Paste the code").Trim()
    }
    finally {
        if ($listener) { $listener.Stop() }
    }

    if (-not $code) { throw "No authorization code received from Strava." }

    Write-Step "Exchanging code for a token..."
    $resp = Invoke-TokenRequest @{
        client_id     = $cfg.client_id
        client_secret = $cfg.client_secret
        code          = $code
        grant_type    = 'authorization_code'
    }
    Save-Utf8NoBom $TokenFile ($resp | ConvertTo-Json)
    Write-OK "Connected! (token saved locally)"
    return $resp.access_token
}

$accessToken = Get-AccessToken
$headers = @{ Authorization = "Bearer $accessToken" }

# ---------- 3. fetch all activities ----------
Write-Step "Fetching activities from Strava..."
$all  = @()
$page = 1
do {
    $uri   = "https://www.strava.com/api/v3/athlete/activities?per_page=200&page=$page"
    $batch = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    if ($batch) {
        $all += $batch
        Write-Host "    Page $page : got $($batch.Count) activities (total $($all.Count))" -ForegroundColor DarkGray
    }
    $page++
} while ($batch -and $batch.Count -eq 200)

Write-OK "Received $($all.Count) activities total."

# ---------- 4. keep runs + elliptical + strength + map fields ----------
$keep = 'Run|Elliptical|WeightTraining|Workout|Crossfit|Hiit'
$runs = $all | Where-Object { $_.type -match $keep } | ForEach-Object {
    [pscustomobject]@{
        id          = $_.id
        name        = $_.name
        type        = $_.type
        date        = $_.start_date_local
        distance    = $_.distance              # meters
        moving_time = $_.moving_time           # seconds
        elapsed     = $_.elapsed_time
        avg_speed   = $_.average_speed          # m/s
        max_speed   = $_.max_speed
        avg_hr      = $_.average_heartrate
        max_hr      = $_.max_heartrate
        elev_gain   = $_.total_elevation_gain   # meters
        avg_cadence = $_.average_cadence
        suffer      = $_.suffer_score
        calories    = $_.kilojoules
    }
}

$runs = @($runs)   # always an array
Write-OK "Of those, $($runs.Count) are runs / elliptical / strength workouts."

# ---------- 5. write the data file for the dashboard ----------
$json = if ($runs.Count -eq 0) { "[]" }
        elseif ($runs.Count -eq 1) { "[" + ($runs[0] | ConvertTo-Json -Depth 4 -Compress) + "]" }
        else { $runs | ConvertTo-Json -Depth 4 }

$payload = "window.STRAVA_DATA = $json;`nwindow.STRAVA_SYNCED_AT = '" + (Get-Date -Format 's') + "';"
Save-Utf8NoBom $DataFile $payload

# ---------- 6. rebuild the single-file online/mobile copy ----------
$buildScript = Join-Path $Root 'build-mobile.ps1'
if (Test-Path $buildScript) {
    Write-Step "Rebuilding single-file copy (dashboard.html)..."
    & $buildScript
}

Write-Step "Done!"
Write-OK "Data saved to: $DataFile"
Write-Host "`n    Now open index.html in your browser to see the dashboard.`n" -ForegroundColor Green
