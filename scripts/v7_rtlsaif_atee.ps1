# NEW (2026-11-14). "RTL-SAIF" power method for Coreless-V (user decision
# 2026-11-14): behavioural RTL simulation in Vivado 2026.1 xsim (RTL, far below
# the BASIC 50,000-instance limit), ENABLE_DIV=0 as the Virtex-7 builds,
# conv8_3 data, no ReLU, BRAM-only, no DMA; SAIF over the layer-busy window
# (testbench/v7_rtlsaif.tcl); read_saif onto the routed Virtex-7 checkpoint
# (Run 1 / Run 2) and report_power at 50 MHz (scripts/v7_rtlsaif_report.tcl).
# RTL, testbenches and the other scripts are used unchanged; ENABLE_DIV=0 comes
# from -d DIV_OFF (vl=8 testbench) or testbench/v7_divoff_vl16.v (vl=16).
# Usage: powershell -File scripts\v7_rtlsaif_atee.ps1 -Design vl16|vl8
param([Parameter(Mandatory)][ValidateSet('vl16','vl8')][string]$Design)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$v26  = $VIVADO2026_ROOT
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$work = Join-Path $root "synth_build_2026\v7_power_rtlsaif\atee_$Design"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
if ($Design -eq 'vl16') {
  & $py "$root\scripts\gen_conv_sizes.py" 8 $work | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }
  $vlog = "$vu\v_wrapper.v","$vu\tensor_config_regs.v","$vu\outsize_div.v","$vu\hbm_lite_controller_vl16.v","$vu\atee_top_vl16.v","$root\testbench\atee_conv_vl16_tb.v","$root\testbench\v7_divoff_vl16.v"
  $defs = @(); $tops = 'xil_defaultlib.atee_conv_vl16_tb','xil_defaultlib.v7_divoff_vl16'; $tb = 'atee_conv_vl16_tb'
  $dcp = "$root\synth_build_2026\v7_xc7vx485t\atee_vl16\post_route.dcp"
} else {
  Copy-Item "$root\testbench\test1_*.hex" $work -Force
  $vlog = "$vu\v_wrapper.v","$vu\tensor_config_regs.v","$vu\outsize_div.v","$vu\hbm_lite_controller.v","$vu\atee_top.v","$root\testbench\atee_conv8_3_tb.v"
  $defs = @('-d','DIV_OFF'); $tops = @('xil_defaultlib.atee_conv8_3_tb'); $tb = 'atee_conv8_3_tb'
  $dcp = "$root\synth_build_2026\v7_xc7vx485t\atee_vl8\post_route.dcp"
}
& "$v26\bin\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$v26\bin\xvlog.bat" -work xil_defaultlib @defs @vlog
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$v26\bin\xelab.bat" -debug typical @tops -s rsnap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
$env:RS_TB = $tb; $env:RS_WIN = 'atee'; $env:RS_FILE = 'rtl_busy.saif'
$env:RS_SKIP = '/DMEM[0-7]/ram$'; $env:RS_NODESCEND = '^$'
& "$v26\bin\xsim.bat" rsnap -log xsim_rtlsaif.log -tclbatch (("$root\testbench\v7_rtlsaif.tcl") -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
& "$v26\bin\vivado.bat" -mode batch -nojournal -log report.log -source "$root\scripts\v7_rtlsaif_report.tcl" -tclargs ($dcp -replace '\\','/') (("$work\rtl_busy.saif") -replace '\\','/') "$tb/dut" ($work -replace '\\','/') "rtlsaif_atee_$Design"
if ($LASTEXITCODE -ne 0) { throw 'report_power failed' }
