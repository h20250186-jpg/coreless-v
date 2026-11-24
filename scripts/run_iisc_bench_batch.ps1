# NEW (2026-11-15). Runs scripts/run_iisc_bench.ps1 for a list of programs, one
# after the other, each with its own log in sim_build/iisc_bench/logs/.
# Entries: "<program>" | "<program>:relocated" | "cnn:<image index>".
# Usage: powershell -File scripts\run_iisc_bench_batch.ps1 -List "saxpy16,perc8:relocated,cnn:3"
param([Parameter(Mandatory)][string]$List)
$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root 'sim_build\iisc_bench\logs'
New-Item -ItemType Directory -Force $logs | Out-Null
foreach ($e in ($List -split ',')) {
    $p = $e.Trim().Split(':'); $prog = $p[0]; $mode = 'shipped'; $img = 0
    if ($p.Count -gt 1) { if ($prog -eq 'cnn') { $img = [int]$p[1] } else { $mode = $p[1] } }
    $name = $prog; if ($prog -eq 'cnn') { $name = "cnn_img$img" }; if ($mode -ne 'shipped') { $name += "_$mode" }
    $log = Join-Path $logs "$name.txt"
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern '^CHECK ' -Quiet)) { continue }   # already done
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\run_iisc_bench.ps1') -Program $prog -Image $img -Mode $mode *> $log
}
