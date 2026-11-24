# NEW (2026-11-19, task H step 4). COPY of scripts/h_batch_step4.ps1 for tree "needed"
# (their files + count_gen '>' + divider switch + exe_unit DONE 1-2, DMEM_WE 14-16,
# VREG_WE 17-19; everything else theirs). Original header:
# Runs the main design (SC) on the vector-unit
# trees "min" (their files + off-by-one fix + divider switch) and then "min_vwe"
# (min + our VREG_WE gating, exe_unit hunks 17-19) over every recorded SC
# workload: CONV2D 3x3 8/16/32/64, CONV2D 5x5 32x32, MATMUL 16/32/64, cnn_demo
# images 0..99. Four processes per tree; the trees run one after the other.
# Output: sim_build_h\<tree>\sc\..., logs sim_build_h\logs\step4_<tree>_<part>.txt
# For scripts\launch_ps_detached.ps1 (no arguments).
$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root 'sim_build_h\logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$run = Join-Path $root 'scripts\h_run_sc.ps1'
foreach ($tree in 'needed') {
    "[$(Get-Date -Format s)] tree $tree start"
    $parts = @(
        @('rows', "-Tree $tree -Job conv -Items 8,16,32,64", "-Tree $tree -Job paper -Items conv32_5,matmul16,matmul32,matmul64"),
        @('cnnA', "-Tree $tree -Job cnn -From 0 -To 33"),
        @('cnnB', "-Tree $tree -Job cnn -From 34 -To 66"),
        @('cnnC', "-Tree $tree -Job cnn -From 67 -To 99"))
    $procs = foreach ($p in $parts) {
        $cmds = ($p[1..($p.Count - 1)] | ForEach-Object { "& powershell -NoProfile -ExecutionPolicy Bypass -File '$run' $_" }) -join '; '
        $log = Join-Path $logs "step4_${tree}_$($p[0]).txt"
        Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "$cmds *> '$log'" -WindowStyle Hidden -PassThru
    }
    $procs | Wait-Process
    "[$(Get-Date -Format s)] tree $tree done"
}

