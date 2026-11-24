# Regression: original single-lane conv8_3 (testbench/atee_functional_tb.v).
# NOTE: this build uses the archived DMA-era top and controller
# (archive/cpu_and_dma/atee_top_dma.v, hbm_lite_controller_vl1.v) plus
# archive/cpu_and_dma/dma_controller.v because the
# original atee_top + testbench load DMEM through DMA. It exists ONLY to
# reproduce the pre-scope-change baseline number; the BRAM-only design must
# not use it.
# Usage: powershell -File scripts\run_conv8_3_regression.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$work = Join-Path $root 'sim_build\conv8_3_regression'
New-Item -ItemType Directory -Force $work | Out-Null
# Original [oc][oh][ow] / bank-0-only data set, frozen so later layout changes
# to testbench\test1_*.hex cannot alter this baseline.
Copy-Item (Join-Path $root 'archive\cpu_and_dma\baseline_hex\test1_*.hex') $work -Force
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
$vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'),
        (Join-Path $root 'archive\cpu_and_dma\hbm_lite_controller_vl1.v'),
        (Join-Path $root 'archive\cpu_and_dma\atee_top_dma.v'),
        (Join-Path $root 'archive\cpu_and_dma\dma_controller.v'),
        (Join-Path $root 'testbench\atee_functional_tb.v')

& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$viv\xvlog.bat" -work xil_defaultlib @vlog
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" xil_defaultlib.atee_functional_tb -s conv8_3_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" conv8_3_snap -runall
