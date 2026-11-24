# Builds and runs the BRAM-only conv8_3 testbench (testbench/atee_conv8_3_tb.v).
# No DMA, no DRAM: nothing from archive/ is compiled here.
# Usage: powershell -File scripts\run_conv8_3.ps1 [-HexDir <dir with test1_*.hex>]
#                                                  [-EarlyClear 0|1] [-Activation 0|1]
#   -EarlyClear : omit to use the controller's own default (1); 0 or 1 forces it.
#   -Activation : 1 runs the layer with ReLU (the golden file must then be ReLU'd).
#   -Workload   : conv8_3 (default, test1_*.hex) or mnist (MNIST conv1 with the
#                 bias omitted, test2_*.hex; picks test2_golden_relu.hex with -Activation 1).
param([string]$HexDir = '', [int]$EarlyClear = -1, [int]$Activation = 0, [string]$Workload = 'conv8_3', [switch]$NoDiv)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$work = Join-Path $root 'sim_build\conv8_3'
New-Item -ItemType Directory -Force $work | Out-Null
if (-not $HexDir) { $HexDir = Join-Path $root 'testbench' }
Copy-Item (Join-Path $HexDir 'test[12]_*.hex') $work -Force
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
$vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'),
        (Join-Path $vu 'outsize_div.v'),
        (Join-Path $vu 'hbm_lite_controller.v'), (Join-Path $vu 'atee_top.v'),
        (Join-Path $root 'testbench\atee_conv8_3_tb.v')

& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
$defs = @()
if ($EarlyClear -eq 1) { $defs += '-d', 'EARLY_CLEAR_ON' }
if ($EarlyClear -eq 0) { $defs += '-d', 'EARLY_CLEAR_OFF' }
if ($Activation -ne 0) { $defs += '-d', 'RELU_ON' }
if ($Workload -eq 'mnist') { $defs += '-d', 'MNIST_CONV1' }
if ($NoDiv) { $defs += '-d', 'DIV_OFF' }   # ENABLE_DIV=0: divider hardware removed
& "$viv\xvlog.bat" -work xil_defaultlib @defs @vlog
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" xil_defaultlib.atee_conv8_3_tb -s conv8_3_bram_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" conv8_3_bram_snap -runall
