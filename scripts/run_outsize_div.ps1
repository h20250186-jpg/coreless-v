# Builds and runs the standalone output-size divider testbench.
# Usage: powershell -File scripts\run_outsize_div.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root 'sim_build\outsize_div'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
& "$viv\xvlog.bat" -work xil_defaultlib (Join-Path $root 'rtl\vector_unit\outsize_div.v') (Join-Path $root 'testbench\outsize_div_tb.v')
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\xelab.bat" xil_defaultlib.outsize_div_tb -s outsize_div_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" outsize_div_snap -runall
