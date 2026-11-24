# NEW (2026-11-17). Watchdog for long xsim batches (run_iisc_cnn_probe.ps1).
# On exit, xsim 2019.1 starts WebTalk (wbtcv.exe), which sometimes never
# returns; it keeps the runner's redirected output pipe open, so the runner
# waits forever although the simulation and its dumps are complete. Every 60 s
# this stops any wbtcv.exe older than 3 minutes (usage reporting only; no
# simulation data involved) and logs it. Ends after -Hours or when no xsim
# runner is left.
# Log: sim_build\iisc_cnn_probe\logs\watchdog.txt
param([double]$Hours = 14)
$root = Split-Path -Parent $PSScriptRoot
$log  = Join-Path $root 'sim_build\iisc_cnn_probe\logs\watchdog.txt'
$t0 = Get-Date
"[$(Get-Date -Format s)] watchdog started" | Add-Content $log
$idle = 0
while (((Get-Date) - $t0).TotalHours -lt $Hours) {
    Get-CimInstance Win32_Process -Filter "Name='wbtcv.exe'" | ForEach-Object {
        $age = (Get-Date) - $_.CreationDate
        if ($age.TotalMinutes -gt 3) {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            "[$(Get-Date -Format s)] stopped wbtcv.exe pid $($_.ProcessId), age $([int]$age.TotalMinutes) min" | Add-Content $log
        }
    }
    $runners = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'run_iisc_cnn_probe' }).Count
    if ($runners -eq 0) { $idle++ } else { $idle = 0 }
    if ($idle -ge 5) { break }
    Start-Sleep 60
}
"[$(Get-Date -Format s)] watchdog ended" | Add-Content $log
