# Builds and runs testbench/lane_load_tb.v against v_wrapper in Vivado xsim.
# Usage: powershell -File scripts\run_lane_load.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$work = Join-Path $root 'sim_build\lane_load'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }

& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$viv\xvlog.bat" -work xil_defaultlib (Join-Path $vu 'v_wrapper.v') (Join-Path $root 'testbench\lane_load_tb.v')
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" -debug typical xil_defaultlib.lane_load_tb -s lane_load_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" lane_load_snap -tclbatch ((Join-Path $root 'testbench\lane_load_trace.tcl') -replace '\\','/')
