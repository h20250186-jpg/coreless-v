# NEW (2026-11-19). Runs scripts\v7_rtlsaif_atee_sc.ps1 for conv8, then for
# cnn_demo image 0 (for scripts\launch_ps_detached.ps1).
$root = Split-Path -Parent $PSScriptRoot
& "$root\scripts\v7_rtlsaif_atee_sc.ps1" -Workload conv8
& "$root\scripts\v7_rtlsaif_atee_sc.ps1" -Workload cnn -Image 0
