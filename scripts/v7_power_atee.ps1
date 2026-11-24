# NEW (2026-11-14). Task B hybrid power flow for Coreless-V (user decision
# 2026-11-14): routed checkpoint -> funcsim netlist -> Vivado 2019.1 xsim
# (unmodified install, used as is; the 2026.1 BASIC simulator is limited to
# 50,000 instances) -> SAIF over the layer-busy window -> report_power in
# Vivado 2026.1 on the routed checkpoint. conv8_3 data, no ReLU, BRAM-only, no DMA.
#   -Design atee_vl16 | atee_vl8 : Virtex-7 Runs 1/2 (netlist exported in 2026.1)
#   -Design artix_vl16           : cross-check, the Artix-7 vl=16 build of
#                                  "vl=16 power" (its existing 2019.1 netlist)
#   -Mode old | new              : SAIF scope logging (testbench/v7_power_saif_atee.tcl)
# Usage: powershell -File scripts\v7_power_atee.ps1 -Design atee_vl16 -Mode new
param([Parameter(Mandatory)][ValidateSet('atee_vl16','atee_vl8','artix_vl16')][string]$Design,
      [Parameter(Mandatory)][ValidateSet('old','new')][string]$Mode)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$v19  = $VIVADO2019_ROOT
$v26  = $VIVADO2026_ROOT
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$base = Join-Path $root "synth_build_2026\v7_power\$Design"
$work = Join-Path $base "sim_$Mode"
New-Item -ItemType Directory -Force $work | Out-Null
switch ($Design) {
  'atee_vl16'  { $dcp = "$root\synth_build_2026\v7_xc7vx485t\atee_vl16\post_route.dcp"; $net = "$base\atee_vl16_funcsim.v"; $tb = 'atee_conv_vl16_tb' }
  'atee_vl8'   { $dcp = "$root\synth_build_2026\v7_xc7vx485t\atee_vl8\post_route.dcp";  $net = "$base\atee_vl8_funcsim.v";  $tb = 'atee_conv8_3_tb' }
  'artix_vl16' { $dcp = "$root\synth_build\artix7_xc7a200tfbg676-2_vl16\clk_only\post_route.dcp"; $net = "$root\synth_build\power_saif_vl16\atee_top_vl16_funcsim.v"; $tb = 'atee_conv_vl16_tb' }
}
$tbfile = if ($tb -eq 'atee_conv_vl16_tb') { "$root\testbench\atee_conv_vl16_tb.v" } else { "$root\testbench\atee_conv8_3_tb.v" }
Set-Location $base
if (-not (Test-Path $net)) {
  & "$v26\bin\vivado.bat" -mode batch -nojournal -log export.log -source "$root\scripts\v7_power_export.tcl" -tclargs $Design
  if ($LASTEXITCODE -ne 0) { throw 'export failed' }
}
$hier = Join-Path $base 'hier_cells.txt'
if (-not (Test-Path $hier)) {
  & "$v26\bin\vivado.bat" -mode batch -nojournal -log hiercells.log -source "$root\scripts\v7_power_hiercells.tcl" -tclargs ($dcp -replace '\\','/') ($hier -replace '\\','/')
  if ($LASTEXITCODE -ne 0) { throw 'hiercells failed' }
}
Set-Location $work
if ($tb -eq 'atee_conv_vl16_tb') { & $py "$root\scripts\gen_conv_sizes.py" 8 $work | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' } }
else { Copy-Item "$root\testbench\test1_*.hex" $work -Force }
& "$v19\bin\xvlog.bat" -work xil_defaultlib $net $tbfile "$v19\data\verilog\src\glbl.v"
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$v19\bin\xelab.bat" -debug typical -L unisims_ver -L secureip "xil_defaultlib.$tb" xil_defaultlib.glbl -s psnap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
$env:SAIF_TB = $tb; $env:SAIF_MODE = $Mode; $env:SAIF_FILE = "conv8_3_busy_$Mode.saif"; $env:SAIF_HIER = $hier
& "$v19\bin\xsim.bat" psnap -tclbatch (("$root\testbench\v7_power_saif_atee.tcl") -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
& "$v26\bin\vivado.bat" -mode batch -nojournal -log "report_$Mode.log" -source "$root\scripts\v7_power_report.tcl" -tclargs ($dcp -replace '\\','/') (("$work\conv8_3_busy_$Mode.saif") -replace '\\','/') "$tb/dut" ($work -replace '\\','/') "${Design}_$Mode"
if ($LASTEXITCODE -ne 0) { throw 'report_power failed' }
