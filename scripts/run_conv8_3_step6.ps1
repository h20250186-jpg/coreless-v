# Reproduces the Step 6 result (NEGATIVE RESULT: slower than Step 5): conv8_3, BRAM-only (no DMA), vl=8,
# WEIGHT-stationary controller, frozen in archive/step6_weight_stationary/.
# Uses the live vector unit, atee_top, tensor_config_regs and
# testbench/atee_conv8_3_tb.v; only the controller and the hex data come from
# the archive, so later changes to the live controller cannot alter this number.
# Usage: powershell -File scripts\run_conv8_3_step6.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$arch = Join-Path $root 'archive\step6_weight_stationary'
$work = Join-Path $root 'sim_build\conv8_3_step6'
New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item (Join-Path $arch 'hex\test1_*.hex') $work -Force
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
$vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'),
        (Join-Path $arch 'hbm_lite_controller_ws.v'), (Join-Path $vu 'atee_top.v'),
        (Join-Path $root 'testbench\atee_conv8_3_tb.v')

& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$viv\xvlog.bat" -work xil_defaultlib @vlog
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" xil_defaultlib.atee_conv8_3_tb -s conv8_3_step6_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" conv8_3_step6_snap -runall
