# NEW (2026-11-19). cnn_demo power runs with the condition-triggered SAIF window
# (testbench/v7_saif_cond.tcl) instead of 20 ns Tcl steps, which made the
# 152k / 242k-cycle windows take hours. Reuses the snapshots, prepared data and
# memory images that scripts/v7_power_atee_sc.ps1, v7_rtlsaif_atee_sc.ps1 and
# v7_rtlsaif_iisc_cnn.ps1 already built in their run directories (nothing is
# recompiled). Same objects logged, same window signals, same report scripts.
#   -Design sc_netlist : netlist-SAIF, SC funcsim netlist, Vivado 2019.1 xsim
#           sc_rtl     : RTL-SAIF, SC RTL, Vivado 2026.1 xsim
#           iisc_rtl   : RTL-SAIF, THEIR design, cnn_demo, 2026.1 xsim; window
#                        conv2d entry -> layer3 return; DMEM/VRF dump for the gate
# Usage: powershell -File scripts\v7_power_cnn_cond.ps1 -Design sc_netlist|sc_rtl|iisc_rtl [-Image 0]
#           sc_netlist_seg : as sc_netlist, one SAIF per layer (v7_saif_cond_seg.tcl)
param([Parameter(Mandatory)][ValidateSet('sc_netlist','sc_netlist_seg','sc_rtl','iisc_rtl')][string]$Design, [int]$Image = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$v19  = Join-Path $VIVADO2019_ROOT 'bin'
$v26  = Join-Path $VIVADO2026_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$tcl  = (Join-Path $root 'testbench\v7_saif_cond.tcl') -replace '\\','/'
$dcpS = "$root\synth_build_2026\v7_xc7vx485t\atee_sc\post_route.dcp"
$dcpI = "$root\synth_build_2026\v7_xc7vx485t\iisc_fpga_wrapper\post_route.dcp"
"[$(Get-Date -Format s)] start $Design image $Image"
switch ($Design) {
  'sc_netlist' {
    $work = Join-Path $root "synth_build_2026\v7_power\atee_sc\sim_cnn\img$Image"; Set-Location $work
    $env:CS_OPEN = '/v7_sc_netlist_tb/dut/cfg_layer_busy == 1'; $env:CS_CLOSE = '/v7_sc_netlist_tb/dut/cfg_layer_busy == 0'
    $env:CS_FILE = 'cond_busy.saif'; $env:CS_LOG = 'netlist'; $env:CS_DUT = '/v7_sc_netlist_tb/dut'
    $env:CS_HIER = "$root\synth_build_2026\v7_power\atee_sc\hier_cells.txt"; $env:CS_DUMP = '0'
    & "$v19\xsim.bat" psnap -wdb cond.wdb -log xsim_run.log -tclbatch $tcl
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    "[$(Get-Date -Format s)] xsim done"
    & $py "$root\scripts\atee_sc_check.py" cnn (Split-Path $work) "$Image" "$Image"
    & "$v26\vivado.bat" -mode batch -nojournal -log report_cond.log -source "$root\scripts\v7_power_report.tcl" -tclargs ($dcpS -replace '\\','/') (("$work\cond_busy.saif") -replace '\\','/') 'v7_sc_netlist_tb/dut' ($work -replace '\\','/') "atee_sc_cnn_img$Image"
  }
  'sc_netlist_seg' {
    # per-layer SAIF files in one run (testbench/v7_saif_cond_seg.tcl); reports by
    # scripts/v7_power_report_multi.tcl
    $work = Join-Path $root "synth_build_2026\v7_power\atee_sc\sim_cnn\img$Image"; Set-Location $work
    $env:CS_OPEN = '/v7_sc_netlist_tb/dut/cfg_layer_busy == 1'; $env:CS_NSEG = '3'
    $env:CS_SEG1 = '/v7_sc_netlist_tb/dut/cur_layer == 0001'; $env:CS_SEG2 = '/v7_sc_netlist_tb/dut/cur_layer == 0010'
    $env:CS_SEG3 = '/v7_sc_netlist_tb/dut/cfg_layer_busy == 0'
    $env:CS_FILE = 'layer'; $env:CS_LOG = 'netlist'; $env:CS_DUT = '/v7_sc_netlist_tb/dut'
    $env:CS_HIER = "$root\synth_build_2026\v7_power\atee_sc\hier_cells.txt"
    & "$v19\xsim.bat" psnap -wdb seg.wdb -log xsim_run.log -tclbatch ((Join-Path $root 'testbench\v7_saif_cond_seg.tcl') -replace '\\','/')
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    "[$(Get-Date -Format s)] xsim done"
    & $py "$root\scripts\atee_sc_check.py" cnn (Split-Path $work) "$Image" "$Image"
    $w = $work -replace '\\','/'
    & "$v26\vivado.bat" -mode batch -nojournal -log report_seg.log -source "$root\scripts\v7_power_report_multi.tcl" -tclargs ($dcpS -replace '\\','/') 'v7_sc_netlist_tb/dut' $w "$w/layer_seg1.saif" "atee_sc_cnn_img${Image}_L1" "$w/layer_seg2.saif" "atee_sc_cnn_img${Image}_L2" "$w/layer_seg3.saif" "atee_sc_cnn_img${Image}_L3"
  }
  'sc_rtl' {
    $work = Join-Path $root "synth_build_2026\v7_power_rtlsaif\atee_sc\cnn\img$Image"; Set-Location $work
    $env:CS_OPEN = '/atee_sc_tb/dut/cfg_layer_busy == 1'; $env:CS_CLOSE = '/atee_sc_tb/dut/cfg_layer_busy == 0'
    $env:CS_FILE = 'cond_busy.saif'; $env:CS_LOG = 'rtl'; $env:CS_DUT = '/atee_sc_tb/dut'
    $env:CS_SKIP = '/DMEM[0-7]/ram$|/u_ibuf/mem$'; $env:CS_DUMP = '0'
    & "$v26\xsim.bat" rsnap -wdb cond.wdb -log xsim_run.log -tclbatch $tcl
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    "[$(Get-Date -Format s)] xsim done"
    & $py "$root\scripts\atee_sc_check.py" cnn (Split-Path $work) "$Image" "$Image"
    & "$v26\vivado.bat" -mode batch -nojournal -log report_cond.log -source "$root\scripts\v7_rtlsaif_report.tcl" -tclargs ($dcpS -replace '\\','/') (("$work\cond_busy.saif") -replace '\\','/') 'atee_sc_tb/dut' ($work -replace '\\','/') "rtlsaif_atee_sc_cnn_img$Image"
  }
  'iisc_rtl' {
    $work = Join-Path $root "synth_build_2026\v7_power_rtlsaif\iisc_cnn_img$Image"; Set-Location $work
    $ref  = Join-Path $root "sim_build\iisc_bench\cnn_img$Image"
    Remove-Item dump.txt, dmem_*.txt, vrf_*.txt -ErrorAction SilentlyContinue
    $env:CS_OPEN = '/iisc_tb_bench26/seen_in == 1'; $env:CS_CLOSE = '/iisc_tb_bench26/seen_out == 1'
    $env:CS_FILE = 'cond_cnn.saif'; $env:CS_LOG = 'rtl'; $env:CS_DUT = '/iisc_tb_bench26/dut'; $env:CS_SKIP = '^$'
    $env:CS_DUMP = '1'; $env:CS_EU = '/iisc_tb_bench26/dut/cpu1/fdem/Pipeline/VECTOR_UNIT/VEC_EXE_UNIT/wrapper_vhd/VECTOR_EXE_UNIT_PIPE'
    & "$v26\xsim.bat" rsnap -wdb cond.wdb -log xsim_cnn_cond.log -tclbatch $tcl
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    "[$(Get-Date -Format s)] xsim done"
    & $py (Join-Path $root 'scripts\iisc_cnn26_helper.py') check $work $ref
    & "$v26\vivado.bat" -mode batch -nojournal -log report_cnn_cond.log -source "$root\scripts\v7_rtlsaif_report.tcl" -tclargs ($dcpI -replace '\\','/') (("$work\cond_cnn.saif") -replace '\\','/') 'iisc_tb_bench26/dut' ($work -replace '\\','/') "rtlsaif_iisc_cnn_img$Image"
  }
}
if ($LASTEXITCODE -ne 0) { throw 'report_power failed' }
"[$(Get-Date -Format s)] report done"
