# NEW (2026-11-14). Task B hybrid power flow for the I2SRV32-V full system
# (Virtex-7 Run 3, repo-build size, their constraints): routed checkpoint ->
# funcsim netlist (2026.1, scripts/v7_power_export.tcl iisc) -> Vivado 2019.1
# xsim (unmodified install, used as is; the 2026.1 BASIC simulator is limited
# to 50,000 instances) with testbench/v7_iisc_netlist_tb.v on their conv8_3
# program (xmem.coe) -> SAIF -> report_power in 2026.1 on the routed checkpoint.
#   -Window conv : conv2d() entry -> return ; all : reset release -> main returns
# The snapshot is built once (sim\) and reused by both windows.
# Usage: powershell -File scripts\v7_power_iisc.ps1 -Window conv
param([Parameter(Mandatory)][ValidateSet('conv','all')][string]$Window)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$v19  = $VIVADO2019_ROOT
$v26  = $VIVADO2026_ROOT
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$base = Join-Path $root 'synth_build_2026\v7_power\iisc'
$dcp  = "$root\synth_build_2026\v7_xc7vx485t\iisc_fpga_wrapper\post_route.dcp"
$net  = Join-Path $base 'iisc_funcsim.v'
$hier = Join-Path $base 'hier_cells.txt'
$sim  = Join-Path $base 'sim'
New-Item -ItemType Directory -Force $sim | Out-Null
Set-Location $sim
"[$(Get-Date -Format s)] window $Window"
if (-not (Test-Path (Join-Path $sim 'xsim.dir\isnap'))) {
  & $py "$root\scripts\gen_conv_sizes.py" 8 $sim
  if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }
  # 2019.1 xvlog fails on the 1,704,045-line netlist (error reported at line
  # 1,048,575 = 2^20 - 1 on an ordinary wire declaration): it is read as parts
  # split at module boundaries by scripts/split_netlist.py (no line changed).
  $parts = Join-Path $base 'netlist_parts'
  if (-not (Test-Path $parts)) { & $py -I "$root\scripts\split_netlist.py" $net $parts; if ($LASTEXITCODE -ne 0) { throw 'split failed' } }
  $nl = Get-ChildItem $parts -Filter 'part*.v' | Sort-Object Name | ForEach-Object FullName
  & "$v19\bin\xvlog.bat" -work xil_defaultlib @nl "$root\testbench\v7_iisc_netlist_tb.v" "$v19\data\verilog\src\glbl.v"
  if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
  "[$(Get-Date -Format s)] xvlog done"
  & "$v19\bin\xelab.bat" -debug typical -L unisims_ver -L secureip xil_defaultlib.v7_iisc_netlist_tb xil_defaultlib.glbl -s isnap
  if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
  "[$(Get-Date -Format s)] xelab done"
}
$env:SAIF_WIN = $Window; $env:SAIF_FILE = "iisc_conv8_3_$Window.saif"; $env:SAIF_HIER = $hier
& "$v19\bin\xsim.bat" isnap -log "xsim_$Window.log" -tclbatch (("$root\testbench\v7_power_saif_iisc.tcl") -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
"[$(Get-Date -Format s)] xsim done"
& "$v26\bin\vivado.bat" -mode batch -nojournal -log "report_$Window.log" -source "$root\scripts\v7_power_report.tcl" -tclargs ($dcp -replace '\\','/') (("$sim\iisc_conv8_3_$Window.saif") -replace '\\','/') 'v7_iisc_netlist_tb/dut' ($sim -replace '\\','/') "iisc_$Window"
if ($LASTEXITCODE -ne 0) { throw 'report_power failed' }
"[$(Get-Date -Format s)] report done"
