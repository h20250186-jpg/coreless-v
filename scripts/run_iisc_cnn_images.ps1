# NEW (2026-11-15). Runs THEIR cnn_demo on THEIR design for a range of the 100
# MNIST images shipped in their repo (Demo/Application/img.c, labels in
# Demo/Application/expected_output.c). Reuses the snapshot compiled by
# scripts/run_iisc_bench.ps1 -Program cnn -Image 0 (sim_build/iisc_bench/cnn_img0):
# the design and testbench are identical for every image; only the data files
# written by iisc_bench_prep.py (memory images, preload of img_buf[] + pflag)
# change. One log per image in sim_build/iisc_bench/logs/cnn_img<k>.txt.
# Usage: powershell -File scripts\run_iisc_cnn_images.ps1 -From 1 -To 33
param([Parameter(Mandatory)][int]$From, [Parameter(Mandatory)][int]$To)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$snap = Join-Path $root 'sim_build\iisc_bench\cnn_img0\xsim.dir'
if (-not (Test-Path (Join-Path $snap 'bench_snap'))) { throw "snapshot not built: $snap" }
$tcl  = (Join-Path $root 'external\iisc_sim\iisc_bench_dump.tcl') -replace '\\','/'
$logs = Join-Path $root 'sim_build\iisc_bench\logs'
for ($k = $From; $k -le $To; $k++) {
    $log = Join-Path $logs "cnn_img$k.txt"
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern '^CHECK ' -Quiet)) { continue }
    $work = Join-Path $root "sim_build\iisc_bench\cnn_img$k"
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Location $work
    & {
        "[$(Get-Date -Format s)] cnn image $k, snapshot reused from cnn_img0"
        & $py (Join-Path $root 'scripts\iisc_bench_prep.py') cnn $work "$k" shipped
        if (Test-Path (Join-Path $work 'xsim.dir')) { Remove-Item -Recurse -Force (Join-Path $work 'xsim.dir') }
        Copy-Item -Recurse $snap (Join-Path $work 'xsim.dir')
        & "$viv\xsim.bat" bench_snap -tclbatch $tcl
        "[$(Get-Date -Format s)] simulation finished"
        & $py (Join-Path $root 'scripts\iisc_bench_check.py') $work
        Remove-Item -Recurse -Force (Join-Path $work 'xsim.dir')
    } *> $log
}
