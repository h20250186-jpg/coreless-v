# NEW (2026-11-19, task H step 5). Runs one of the five fault-reproduction
# testbenches (v_wrapper alone, testbenches and trace scripts unchanged) on a
# vector-unit tree from sim_build_h/trees/<Tree> (scripts/h_trees.py).
#   convoy        testbench/convoy_tb.v        (load-use stall V1/V1b, broadcast collision V3a-d)
#   convoy_multi  testbench/convoy_multi_tb.v  (multi-MAC depth, slot-7 store L3M3S, early clear)
#   lane_load     testbench/lane_load_tb.v     (EXP A/B/C: slot routing, write gate)
#   convoy_reuse  testbench/convoy_reuse_tb.v  (slot reuse T1-T6), conv8_3 hex
#   convoy_vl16   testbench/convoy_vl16_tb.v   (vl=16, empty-slot negative test), conv8_3 hex
# Output: sim_build_h\<Tree>\fault\<Tb>\xsim.log
# Usage: powershell -File scripts\h_run_fault.ps1 -Tree upstream -Tb convoy
param([Parameter(Mandatory)][string]$Tree,
      [Parameter(Mandatory)][ValidateSet('convoy','convoy_multi','lane_load','convoy_reuse','convoy_vl16')][string]$Tb)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\h_compile.ps1')
$work = Join-Path $root "sim_build_h\$Tree\fault\$Tb"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
if ($Tb -in 'convoy_reuse','convoy_vl16') { Copy-Item (Join-Path $root 'testbench\test1_*.hex') $work -Force }
$vu = Join-Path $root "sim_build_h\trees\$Tree\vector_unit"
H-Compile -Tree $Tree -Vlog @((Join-Path $vu 'v_wrapper.v'), (Join-Path $root "testbench\${Tb}_tb.v")) -Top "${Tb}_tb" -Snap "${Tb}_snap" -Debug
& "$viv\xsim.bat" "${Tb}_snap" -log xsim.log -tclbatch ((Join-Path $root "testbench\${Tb}_trace.tcl") -replace '\\','/') | Out-Null
"$Tree / $Tb : exit $LASTEXITCODE, log $work\xsim.log"
