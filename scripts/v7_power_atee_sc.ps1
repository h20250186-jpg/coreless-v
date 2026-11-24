# NEW (2026-11-19). Netlist-SAIF power flow (as scripts/v7_power_atee.ps1,
# unchanged, mode "new") for the scalar-operand design, the paper's main design
# (user decision 2026-11-19): routed Virtex-7 checkpoint
# synth_build_2026\v7_xc7vx485t\atee_sc -> funcsim netlist (2026.1,
# scripts/v7_power_export_dcp.tcl) -> Vivado 2019.1 xsim (unmodified install),
# testbench testbench/v7_sc_netlist_tb.v (copy of atee_sc_tb.v) -> SAIF over the
# layer-busy window, every hierarchical cell logged
# (testbench/v7_power_saif_atee.tcl, unchanged, mode new) -> report_power in
# 2026.1 on the routed checkpoint (scripts/v7_power_report.tcl, unchanged).
# Workloads: conv8 = their conv8_3 (Q32.0, no ReLU); cnn = cnn_demo image
# -Image, all three layers from one start. Gate: scripts/atee_sc_check.py.
# Usage: powershell -File scripts\v7_power_atee_sc.ps1 -Workload conv8|cnn [-Image 0]
param([Parameter(Mandatory)][ValidateSet('conv8','cnn')][string]$Workload, [int]$Image = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$v19  = $VIVADO2019_ROOT
$v26  = $VIVADO2026_ROOT
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$dcp  = "$root\synth_build_2026\v7_xc7vx485t\atee_sc\post_route.dcp"
$base = Join-Path $root 'synth_build_2026\v7_power\atee_sc'
$net  = Join-Path $base 'atee_sc_funcsim.v'
$hier = Join-Path $base 'hier_cells.txt'
$tb   = 'v7_sc_netlist_tb'
New-Item -ItemType Directory -Force $base | Out-Null
Set-Location $base
"[$(Get-Date -Format s)] start $Workload"
if (-not (Test-Path $net) -or -not (Test-Path $hier)) {
  & "$v26\bin\vivado.bat" -mode batch -nojournal -log export.log -source "$root\scripts\v7_power_export_dcp.tcl" -tclargs ($dcp -replace '\\','/') ($net -replace '\\','/') ($hier -replace '\\','/')
  if ($LASTEXITCODE -ne 0) { throw 'export failed' }
  "[$(Get-Date -Format s)] netlist exported"
}
if ($Workload -eq 'conv8') { $work = Join-Path $base 'sim_conv\conv8' } else { $work = Join-Path $base "sim_cnn\img$Image" }
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
if ($Workload -eq 'conv8') { & $py "$root\scripts\atee_sc_prep.py" conv 8 $work } else { & $py "$root\scripts\atee_sc_prep.py" cnn "$Image" $work 3 }
if ($LASTEXITCODE -ne 0) { throw 'prep failed' }
& "$v19\bin\xvlog.bat" -work xil_defaultlib $net "$root\testbench\v7_sc_netlist_tb.v" "$v19\data\verilog\src\glbl.v"
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$v19\bin\xelab.bat" -debug typical -L unisims_ver -L secureip "xil_defaultlib.$tb" xil_defaultlib.glbl -s psnap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
"[$(Get-Date -Format s)] snapshot built"
$env:SAIF_TB = $tb; $env:SAIF_MODE = 'new'; $env:SAIF_FILE = 'busy.saif'; $env:SAIF_HIER = $hier
& "$v19\bin\xsim.bat" psnap -log xsim_run.log -tclbatch (("$root\testbench\v7_power_saif_atee.tcl") -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
"[$(Get-Date -Format s)] xsim done"
if ($Workload -eq 'conv8') { & $py "$root\scripts\atee_sc_check.py" conv $work } else { & $py "$root\scripts\atee_sc_check.py" cnn (Split-Path $work) "$Image" "$Image" }
& "$v26\bin\vivado.bat" -mode batch -nojournal -log report.log -source "$root\scripts\v7_power_report.tcl" -tclargs ($dcp -replace '\\','/') (("$work\busy.saif") -replace '\\','/') "$tb/dut" ($work -replace '\\','/') "atee_sc_$Workload"
if ($LASTEXITCODE -ne 0) { throw 'report_power failed' }
"[$(Get-Date -Format s)] report done"
