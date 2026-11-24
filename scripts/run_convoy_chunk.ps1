# NEW (2026-11-16). Builds and runs testbench/convoy_chunk_tb.v (chunk-boundary
# convoy test, RTL stage 1 of docs/chunked_taps_design.md) against v_wrapper in
# Vivado 2019.1 xsim. Same source list as scripts/run_convoy_vl16.ps1
# (unchanged). No DMA, no atee_top, no RTL change.
# Usage: powershell -File scripts\run_convoy_chunk.ps1 [-HexDir <dir with test1_*.hex>] [-Tag name]
param([string]$HexDir = '', [string]$Tag = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$work = Join-Path $root ('sim_build\convoy_chunk' + $(if ($Tag) { "_$Tag" } else { '' }))
New-Item -ItemType Directory -Force $work | Out-Null
if (-not $HexDir) { $HexDir = Join-Path $root 'testbench' }
Copy-Item (Join-Path $HexDir 'test1_*.hex') $work -Force
Set-Location $work

$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }

& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$viv\xvlog.bat" -work xil_defaultlib (Join-Path $vu 'v_wrapper.v') (Join-Path $root 'testbench\convoy_chunk_tb.v')
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" -debug typical xil_defaultlib.convoy_chunk_tb -s convoy_chunk_snap | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" convoy_chunk_snap -R
