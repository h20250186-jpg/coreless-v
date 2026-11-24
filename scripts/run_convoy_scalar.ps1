# NEW (2026-11-17). Builds and runs testbench/convoy_scalar_tb.v (isolated
# scalar-operand convoy tests, step 1 of docs/chunked_taps_design.md section
# 10.7) against v_wrapper in Vivado 2019.1 xsim. Same source list as
# scripts/run_convoy_chunk.ps1 (unchanged). No DMA, no atee_top, no RTL change.
# Usage: powershell -File scripts\run_convoy_scalar.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$work = Join-Path $root 'sim_build\convoy_scalar'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }

& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$viv\xvlog.bat" -work xil_defaultlib (Join-Path $vu 'v_wrapper.v') (Join-Path $root 'testbench\convoy_scalar_tb.v')
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" -debug typical xil_defaultlib.convoy_scalar_tb -s convoy_scalar_snap | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" convoy_scalar_snap -R
