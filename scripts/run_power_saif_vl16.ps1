# NEW (2026-11-12), a copy of scripts/run_power_saif.ps1 (unchanged) for the
# vl=16 design. Post-implementation FUNCTIONAL simulation of the routed
# full-chip atee_top_vl16 netlist (no timing annotation) running CONV2D 8x8
# (conv8_3 data, gen_conv_sizes.py 8) without ReLU, SAIF over the layer-busy
# window, then report_power with that activity. BRAM-only, no DMA.
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, not the Genesys 2 Kintex-7 part).
# Prerequisite: vivado -mode batch -source scripts/synth_atee_vl16_fullchip.tcl
# Usage: powershell -File scripts\run_power_saif_vl16.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = $VIVADO2019_ROOT
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root 'synth_build\power_saif_vl16'
& $py (Join-Path $root 'scripts\gen_conv_sizes.py') 8 $work
if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }
Set-Location $work

& "$viv\bin\xvlog.bat" -work xil_defaultlib atee_top_vl16_funcsim.v (Join-Path $root 'testbench\atee_conv_vl16_tb.v') "$viv\data\verilog\src\glbl.v"
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$viv\bin\xelab.bat" -debug typical -L unisims_ver -L secureip xil_defaultlib.atee_conv_vl16_tb xil_defaultlib.glbl -s power_vl16_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\bin\xsim.bat" power_vl16_snap -tclbatch ((Join-Path $root 'testbench\power_saif_vl16.tcl') -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }

& "$viv\bin\vivado.bat" -mode batch -nojournal -log vivado_power_saif_vl16.log -source (Join-Path $root 'scripts\power_report_saif_vl16.tcl')
