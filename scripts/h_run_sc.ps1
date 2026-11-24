# NEW (2026-11-19, task H). Runs the MAIN design (scalar-operand controller SC:
# atee_top_sc + hbm_lite_controller_sc + ibuf_ram, testbench/atee_sc_tb.v, all
# unchanged) on a vector-unit tree from sim_build_h/trees/<Tree> (scripts/h_trees.py).
# Same data preparation as the recorded runs (scripts/atee_sc_prep.py,
# scripts/atee_sc_paper.py, unchanged). Output only in sim_build_h\<Tree>\sc\.
# Each finished run is compared with its RECORDED counterpart by scripts/h_compare.py.
# Usage:
#   powershell -File scripts\h_run_sc.ps1 -Tree min -Job conv -Items 8,16,32,64
#   powershell -File scripts\h_run_sc.ps1 -Tree min -Job paper -Items conv32_5,matmul16,matmul32,matmul64
#   powershell -File scripts\h_run_sc.ps1 -Tree min -Job cnn -From 0 -To 33
param([Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][ValidateSet('conv','paper','cnn')][string]$Job,
      [string]$Items = '', [int]$From = 0, [int]$To = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\h_compile.ps1')
$vu   = Join-Path $root "sim_build_h\trees\$Tree\vector_unit"
$base = Join-Path $root "sim_build_h\$Tree\sc"
$snap = Join-Path $base $(if ($Job -eq 'cnn') { "snap_cnn_${From}_$To" } else { "snap_$Job" })
New-Item -ItemType Directory -Force $snap | Out-Null
Set-Location $snap
if (-not (Test-Path 'xsim.dir\atee_sc_snap')) {
    $vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'), (Join-Path $vu 'ibuf_ram.v'),
            (Join-Path $vu 'hbm_lite_controller_sc.v'), (Join-Path $vu 'atee_top_sc.v'), (Join-Path $root 'testbench\atee_sc_tb.v')
    H-Compile -Tree $Tree -Vlog $vlog -Top atee_sc_tb -Snap atee_sc_snap
}
function Run-One([string]$out, [string]$prepScript, [string[]]$prepArgs, [string]$rec) {
    if (Test-Path (Join-Path $out 'cnn_dump.txt')) { "$(Split-Path -Leaf $out) already done"; return }
    & $py (Join-Path $root "scripts\$prepScript") @prepArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "prep failed: $prepArgs" }
    Remove-Item cnn_dump.txt -ErrorAction SilentlyContinue
    $t0 = Get-Date
    & "$viv\xsim.bat" atee_sc_snap -runall -log xsim_run.log | Out-Null
    $dt = ((Get-Date) - $t0).TotalSeconds
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item cnn_ref.json, xsim_run.log, cnn_params.txt $out -Force
    if (Test-Path cnn_dump.txt) { Move-Item cnn_dump.txt $out -Force }
    $line = Select-String -Path (Join-Path $out 'xsim_run.log') -Pattern '^CNN_DONE' | Select-Object -First 1
    "$(Split-Path -Leaf $out) : $($line.Line)  [$([int]$dt) s]"
    & $py (Join-Path $root 'scripts\h_compare.py') $out $rec
}
$list = if ($Items) { $Items -split ',' } else { @() }
switch ($Job) {
  'conv'  { foreach ($s in $list) { Run-One (Join-Path $base "conv$s") 'atee_sc_prep.py' @('conv', "$s", $snap) (Join-Path $root "sim_build\atee_sc\conv\conv$s") } }
  'paper' { foreach ($p in $list) { Run-One (Join-Path $base $p) 'atee_sc_paper.py' @('prep', $p, $snap) (Join-Path $root "sim_build\atee_sc\paper\$p") } }
  'cnn'   { for ($k = $From; $k -le $To; $k++) { Run-One (Join-Path $base "cnn\img$k") 'atee_sc_prep.py' @('cnn', "$k", $snap, '3') (Join-Path $root "sim_build\atee_sc\L3\img$k") } }
}
