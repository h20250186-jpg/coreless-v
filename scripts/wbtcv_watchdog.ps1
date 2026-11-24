# NEW (2026-11-17). Generic copy of scripts/iisc_wbtcv_watchdog.ps1 (unchanged)
# with the runner pattern as a parameter. xsim 2019.1 sometimes hangs on exit
# in WebTalk (wbtcv.exe), holding the runner's output pipe open although the
# simulation and its dumps are complete. Every 60 s this stops any wbtcv.exe
# older than 3 minutes (usage reporting only; no simulation data involved) and
# logs it. Ends after -Hours, or after 5 idle checks with no runner matching
# -Match left.
param([double]$Hours = 14, [string]$Match = 'run_atee_cnn', [string]$Log = '')
$root = Split-Path -Parent $PSScriptRoot
if (-not $Log) { $Log = Join-Path $root 'sim_build\atee_cnn\watchdog.txt' }
New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
$t0 = Get-Date
"[$(Get-Date -Format s)] watchdog started (match '$Match')" | Add-Content $Log
$idle = 0
while (((Get-Date) - $t0).TotalHours -lt $Hours) {
    Get-CimInstance Win32_Process -Filter "Name='wbtcv.exe'" | ForEach-Object {
        $age = (Get-Date) - $_.CreationDate
        if ($age.TotalMinutes -gt 3) {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            "[$(Get-Date -Format s)] stopped wbtcv.exe pid $($_.ProcessId), age $([int]$age.TotalMinutes) min" | Add-Content $Log
        }
    }
    $runners = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match $Match }).Count
    if ($runners -eq 0) { $idle++ } else { $idle = 0 }
    if ($idle -ge 5) { break }
    Start-Sleep 60
}
"[$(Get-Date -Format s)] watchdog ended" | Add-Content $Log
