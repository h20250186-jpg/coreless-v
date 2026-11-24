# NEW (2026-11-19). "RTL-SAIF" power method (as scripts/v7_rtlsaif_atee.ps1,
# unchanged) for the scalar-operand design: behavioural RTL in Vivado 2026.1
# xsim, ENABLE_DIV = 0 (testbench/atee_sc_tb.v sets it), SAIF over the
# layer-busy window (testbench/v7_rtlsaif.tcl, unchanged, window "atee",
# get_objects -r below dut; excluded: the 8 DMEM memory arrays as before, and
# the IBUF memory array u_ibuf/mem, which also has no netlist nets), read_saif
# onto the routed Virtex-7 checkpoint synth_build_2026\v7_xc7vx485t\atee_sc and
# report_power at 50 MHz (scripts/v7_rtlsaif_report.tcl, unchanged).
# Workloads: conv8 (their conv8_3, Q32.0, no ReLU) | cnn (cnn_demo image -Image,
# three layers from one start). Gate: scripts/atee_sc_check.py.
# Usage: powershell -File scripts\v7_rtlsaif_atee_sc.ps1 -Workload conv8|cnn [-Image 0]
param([Parameter(Mandatory)][ValidateSet('conv8','cnn')][string]$Workload, [int]$Image = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$v26  = $VIVADO2026_ROOT
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$dcp  = "$root\synth_build_2026\v7_xc7vx485t\atee_sc\post_route.dcp"
if ($Workload -eq 'conv8') { $work = Join-Path $root 'synth_build_2026\v7_power_rtlsaif\atee_sc\conv8' }
else { $work = Join-Path $root "synth_build_2026\v7_power_rtlsaif\atee_sc\cnn\img$Image" }
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
"[$(Get-Date -Format s)] start $Workload"
if ($Workload -eq 'conv8') { & $py "$root\scripts\atee_sc_prep.py" conv 8 $work } else { & $py "$root\scripts\atee_sc_prep.py" cnn "$Image" $work 3 }
if ($LASTEXITCODE -ne 0) { throw 'prep failed' }
$vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
        'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
        'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
$vlog = "$vu\v_wrapper.v","$vu\tensor_config_regs.v","$vu\ibuf_ram.v","$vu\hbm_lite_controller_sc.v","$vu\atee_top_sc.v","$root\testbench\atee_sc_tb.v"
& "$v26\bin\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
& "$v26\bin\xvlog.bat" -work xil_defaultlib @vlog
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& "$v26\bin\xelab.bat" -debug typical xil_defaultlib.atee_sc_tb -s rsnap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
$env:RS_TB = 'atee_sc_tb'; $env:RS_WIN = 'atee'; $env:RS_FILE = 'rtl_busy.saif'
$env:RS_SKIP = '/DMEM[0-7]/ram$|/u_ibuf/mem$'; $env:RS_NODESCEND = '^$'
& "$v26\bin\xsim.bat" rsnap -log xsim_run.log -tclbatch (("$root\testbench\v7_rtlsaif.tcl") -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
"[$(Get-Date -Format s)] xsim done"
if ($Workload -eq 'conv8') { & $py "$root\scripts\atee_sc_check.py" conv $work } else { & $py "$root\scripts\atee_sc_check.py" cnn (Split-Path $work) "$Image" "$Image" }
& "$v26\bin\vivado.bat" -mode batch -nojournal -log report.log -source "$root\scripts\v7_rtlsaif_report.tcl" -tclargs ($dcp -replace '\\','/') (("$work\rtl_busy.saif") -replace '\\','/') 'atee_sc_tb/dut' ($work -replace '\\','/') "rtlsaif_atee_sc_$Workload"
if ($LASTEXITCODE -ne 0) { throw 'report_power failed' }
"[$(Get-Date -Format s)] report done"
