# NEW (2026-11-16). Check A.2: runs scripts/iisc_vlhazard.py's minimal
# layer3-pattern program on THEIR design for each vl and data set, reusing the
# cnn_img0 snapshot of scripts/run_iisc_bench.ps1 (iisc_tb_bench.v, assumed
# stand-ins; identical design and testbench, only the memory images differ).
# Run dirs sim_build/iisc_vlhazard/vl<v>_<ds>, logs sim_build/iisc_vlhazard/logs.
# Usage: powershell -File scripts\run_iisc_vlhazard.ps1 [-Vl 8,9,10,11,12,16] [-Sets A,B]
param([int[]]$Vl = @(8, 9, 10, 11, 12, 16), [string[]]$Sets = @('A', 'B'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$snap = Join-Path $root 'sim_build\iisc_bench\cnn_img0\xsim.dir'
if (-not (Test-Path (Join-Path $snap 'bench_snap'))) { throw "snapshot not built: $snap" }
$tcl  = (Join-Path $root 'external\iisc_sim\iisc_bench_dump.tcl') -replace '\\','/'
$base = Join-Path $root 'sim_build\iisc_vlhazard'
$logs = Join-Path $base 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
foreach ($v in $Vl) { foreach ($s in $Sets) {
    $log = Join-Path $logs "vl${v}_$s.txt"
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern '^CHECK ' -Quiet)) { continue }
    $work = Join-Path $base "vl${v}_$s"
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Location $work
    & {
        "[$(Get-Date -Format s)] vl $v data set $s"
        & $py (Join-Path $root 'scripts\iisc_vlhazard.py') prep $work "$v" $s
        if (Test-Path (Join-Path $work 'xsim.dir')) { Remove-Item -Recurse -Force (Join-Path $work 'xsim.dir') }
        Copy-Item -Recurse $snap (Join-Path $work 'xsim.dir')
        & "$viv\xsim.bat" bench_snap -tclbatch $tcl
        "[$(Get-Date -Format s)] simulation finished"
        & $py (Join-Path $root 'scripts\iisc_vlhazard.py') check $work
        Remove-Item -Recurse -Force (Join-Path $work 'xsim.dir')
    } *> $log
} }
