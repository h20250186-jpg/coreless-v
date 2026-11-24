# NEW script (2026-11-11). Runs the vl=16 controller (atee_top_vl16 /
# hbm_lite_controller_vl16) with testbench/atee_conv_vl16_tb.v. BRAM-only, no
# DMA; design default ENABLE_DIV; nothing from archive/ is compiled. The live
# vl=8 controller and its scripts are not touched.
# Usage: powershell -File scripts\run_conv_vl16.ps1
#          -Size 8|16|32|64 [-Distinct]      their CONV2D 3x3 data (gen_conv_sizes.py)
#          -Workload mnist                   MNIST conv1, bias omitted (testbench/test2_*.hex)
#          [-Activation 1]                   ReLU on
#          [-NegControl]                     ReLU off, compared against the ReLU'd reference
#          -LimitTest                        refusal of configurations outside the limits
param([int]$Size = 0, [switch]$Distinct, [string]$Workload = 'conv', [int]$Activation = 0,
      [switch]$NegControl, [switch]$LimitTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$tag  = if ($LimitTest) { 'limits' } elseif ($Workload -eq 'mnist') { 'mnist' } else { "conv$Size" + $(if ($Distinct) { '_distinct' } else { '' }) }
$tag += $(if ($Activation -ne 0) { '_relu' } elseif ($NegControl) { '_negctl' } else { '' })
$work = Join-Path $root "sim_build\vl16_$tag"
New-Item -ItemType Directory -Force $work | Out-Null

if ($Workload -eq 'mnist') {
    # MNIST conv1 (bias omitted): the recorded test2 files, renamed for the testbench
    $tb = Join-Path $root 'testbench'
    Copy-Item (Join-Path $tb 'test2_input.hex')   (Join-Path $work 'conv_input.hex')   -Force
    Copy-Item (Join-Path $tb 'test2_weights.hex') (Join-Path $work 'conv_weights.hex') -Force
    Copy-Item (Join-Path $tb 'test2_golden.hex')  (Join-Path $work 'conv_golden.hex')  -Force
    Remove-Item (Join-Path $work 'conv_theirs.hex') -ErrorAction SilentlyContinue
    "28`n3`n16`n26`n6272`n10816`n00000000`n00000000`n00000000`n0`n" | Set-Content -NoNewline -Encoding ascii (Join-Path $work 'conv_params.txt')
} elseif (-not $LimitTest) {
    $genArgs = @((Join-Path $root 'scripts\gen_conv_sizes.py'), "$Size", $work)
    if ($Distinct) { $genArgs += '--distinct' }
    & $py @genArgs
    if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }
    if ($Distinct) { Remove-Item (Join-Path $work 'conv_theirs.hex') -ErrorAction SilentlyContinue }
}
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
$vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'),
        (Join-Path $vu 'outsize_div.v'),
        (Join-Path $vu 'hbm_lite_controller_vl16.v'), (Join-Path $vu 'atee_top_vl16.v'),
        (Join-Path $root 'testbench\atee_conv_vl16_tb.v')
& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
$defs = @()
if ($Activation -ne 0) { $defs += '-d', 'RELU_ON' }
if ($NegControl)       { $defs += '-d', 'NEG_CONTROL' }
if ($LimitTest)        { $defs += '-d', 'LIMIT_TEST' }
& "$viv\xvlog.bat" -work xil_defaultlib @defs @vlog
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" xil_defaultlib.atee_conv_vl16_tb -s conv_vl16_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" conv_vl16_snap -runall
