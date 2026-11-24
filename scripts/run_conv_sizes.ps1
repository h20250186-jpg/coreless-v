# NEW script (2026-11-11), derived from run_conv8_3.ps1 (unchanged).
# Runs the live Coreless-V controller (vl=8, EARLY_CLEAR default, no ReLU,
# design default ENABLE_DIV) on the I2SRV32-V CONV2D 3x3 benchmark data at one
# image size. BRAM-only, no DMA; nothing from archive/ is compiled.
# Usage: powershell -File scripts\run_conv_sizes.ps1 -Size 8|16|32|64 [-Distinct]
param([Parameter(Mandatory)][int]$Size, [switch]$Distinct)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$tag  = "conv$Size" + $(if ($Distinct) { '_distinct' } else { '' })
$work = Join-Path $root "sim_build\conv_sizes_$tag"
New-Item -ItemType Directory -Force $work | Out-Null

$genArgs = @((Join-Path $root 'scripts\gen_conv_sizes.py'), "$Size", $work)
if ($Distinct) { $genArgs += '--distinct' }
& $py @genArgs
if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
$vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'),
        (Join-Path $vu 'outsize_div.v'),
        (Join-Path $vu 'hbm_lite_controller.v'), (Join-Path $vu 'atee_top.v'),
        (Join-Path $root 'testbench\atee_conv_sizes_tb.v')
& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$viv\xvlog.bat" -work xil_defaultlib @vlog
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" xil_defaultlib.atee_conv_sizes_tb -s conv_sizes_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" conv_sizes_snap -runall
