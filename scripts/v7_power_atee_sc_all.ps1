# NEW (2026-11-19). Runs scripts\v7_power_atee_sc.ps1 for conv8, then for
# cnn_demo image 0, one after the other (for scripts\launch_ps_detached.ps1,
# which takes a script without arguments).
$root = Split-Path -Parent $PSScriptRoot
& "$root\scripts\v7_power_atee_sc.ps1" -Workload conv8
& "$root\scripts\v7_power_atee_sc.ps1" -Workload cnn -Image 0
