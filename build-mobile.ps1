<#
  build-mobile.ps1
  Bundles index.html + chart.min.js + strava-data.js into ONE self-contained
  file: dashboard.html — ready to upload to any static host (or open anywhere).
  Run it after each sync to refresh the online/mobile copy.
#>
$ErrorActionPreference='Stop'
$d = Split-Path -Parent $MyInvocation.MyCommand.Path

$html  = Get-Content (Join-Path $d 'index.html')     -Raw -Encoding UTF8
$chart = Get-Content (Join-Path $d 'chart.min.js')   -Raw -Encoding UTF8
$data  = Get-Content (Join-Path $d 'strava-data.js') -Raw -Encoding UTF8

# Protect any literal </script> inside the JS so it doesn't close the tag early
$chart = $chart.Replace('</script>','<\/script>')
$data  = $data.Replace('</script>','<\/script>')

# Inline the two external scripts
$html = $html.Replace('<script src="chart.min.js" onerror="window.__noChart=true"></script>',   '<script>'+$chart+'</script>')
$html = $html.Replace('<script src="strava-data.js" onerror="window.__noData=true"></script>', '<script>'+$data+'</script>')

$out = Join-Path $d 'dashboard.html'
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($out, $html, $enc)

$kb = [math]::Round((Get-Item $out).Length/1KB)
Write-Host "Built dashboard.html ($kb KB) - single self-contained file." -ForegroundColor Green
