# Post-implementation FUNCTIONAL simulation of the routed netlist (no timing
# annotation) running conv8_3 without ReLU, recording a SAIF over the
# layer-busy window, then report_power with that activity.
# Build: divider removed (ENABLE_DIV=0), sequential output-size divider.
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, not the Genesys 2 Kintex-7 part).
# Prerequisite: vivado -mode batch -source scripts/power_export_netlist.tcl
# Usage: powershell -File scripts\run_power_saif.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = $VIVADO2019_ROOT
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root 'synth_build\power_saif'
Copy-Item (Join-Path $root 'testbench\test1_*.hex') $work -Force
Set-Location $work

& "$viv\bin\xvlog.bat" -work xil_defaultlib atee_top_funcsim.v (Join-Path $root 'testbench\atee_conv8_3_tb.v') "$viv\data\verilog\src\glbl.v"
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\bin\xelab.bat" -debug typical -L unisims_ver -L secureip xil_defaultlib.atee_conv8_3_tb xil_defaultlib.glbl -s power_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\bin\xsim.bat" power_snap -tclbatch ((Join-Path $root 'testbench\power_saif.tcl') -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }

& "$viv\bin\vivado.bat" -mode batch -nojournal -log vivado_power_saif.log -source (Join-Path $root 'scripts\power_report_saif.tcl')
