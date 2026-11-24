# NEW (2026-11-19). "RTL-SAIF" power method, THEIR cnn_demo on THEIR design
# (user request 2026-11-19: "IISc CNN: inference window, same image"). Same
# build as scripts/v7_rtlsaif_iisc.ps1 (unchanged; its compile lists vhdl.f /
# vlog.f and extracted 2026.1 IP simulation files in
# synth_build_2026\v7_power_rtlsaif\iisc are reused as they are), except:
#   - testbench external/iisc_sim/iisc_tb_bench26.v (copy of iisc_tb_bench.v)
#     instead of iisc_tb_conv.v;
#   - memory images: cnn_demo from its ELF via scripts/iisc_bench_prep.py
#     (unchanged; = the shipped xmem.coe / dmem_bank*.coe word for word), the
#     image's img_buf[] + pflag written into mainMem.mif
#     (scripts/iisc_cnn26_helper.py preload).
# SAIF window: conv2d entry -> layer3 return (testbench/v7_rtlsaif_iisc_cnn.tcl).
# Gate: windows and final DMEM / VRF identical to the 2019.1 run of the same
# image (sim_build\iisc_bench\cnn_img<k>). read_saif onto the routed Virtex-7
# Run 3 checkpoint, report_power at the nominal 50 MHz (their design FAILS 50 MHz).
# Usage: powershell -File scripts\v7_rtlsaif_iisc_cnn.ps1 [-Image 0]
param([int]$Image = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2026_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$old  = Join-Path $root 'synth_build_2026\v7_power_rtlsaif\iisc'
$work = Join-Path $root "synth_build_2026\v7_power_rtlsaif\iisc_cnn_img$Image"
$ref  = Join-Path $root "sim_build\iisc_bench\cnn_img$Image"
$dcp  = Join-Path $root 'synth_build_2026\v7_xc7vx485t\iisc_fpga_wrapper\post_route.dcp'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
"[$(Get-Date -Format s)] start, image $Image"
& $py (Join-Path $root 'scripts\iisc_bench_prep.py') cnn $work "$Image"
if ($LASTEXITCODE -ne 0) { throw 'iisc_bench_prep failed' }
& $py (Join-Path $root 'scripts\iisc_cnn26_helper.py') preload $work
if ($LASTEXITCODE -ne 0) { throw 'preload failed' }
if (-not (Test-Path (Join-Path $work 'xsim.dir\rsnap'))) {
  Copy-Item (Join-Path $old 'vhdl.f') $work -Force
  $tbOld = (Join-Path $root 'external\iisc_sim\iisc_tb_conv.v') -replace '\\','/'
  $tbNew = (Join-Path $root 'external\iisc_sim\iisc_tb_bench26.v') -replace '\\','/'
  $vl = Get-Content (Join-Path $old 'vlog.f')
  if (-not ($vl -contains ('"' + $tbOld + '"'))) { throw 'tb line not found in vlog.f' }
  $vl | ForEach-Object { if ($_ -eq ('"' + $tbOld + '"')) { '"' + $tbNew + '"' } else { $_ } } | Set-Content -Encoding ascii (Join-Path $work 'vlog.f')
  & "$viv\xvhdl.bat" -f vhdl.f
  if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
  & "$viv\xvlog.bat" -f vlog.f
  if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
  & "$viv\xelab.bat" -debug typical -L xil_defaultlib -L blk_mem_gen_v8_4_13 -L div_gen_v5_1_26 -L dsp_macro_v1_0_10 -L xbip_utils_v3_0_16 -L xbip_pipe_v3_0_12 -L xbip_dsp48_wrapper_v3_0_7 -L xbip_multadd_v3_0_24 -L axi_utils_v2_0_12 -L mult_gen_v12_0_25 -L unisims_ver -L unimacro_ver -L secureip --relax xil_defaultlib.iisc_tb_bench26 xil_defaultlib.glbl -s rsnap
  if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
  "[$(Get-Date -Format s)] snapshot built"
}
$env:RS_FILE = 'rtl_cnn.saif'
& "$viv\xsim.bat" rsnap -log xsim_cnn.log -tclbatch (("$root\testbench\v7_rtlsaif_iisc_cnn.tcl") -replace '\\','/')
if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
"[$(Get-Date -Format s)] xsim done"
& $py (Join-Path $root 'scripts\iisc_cnn26_helper.py') check $work $ref
& "$viv\vivado.bat" -mode batch -nojournal -log report_cnn.log -source "$root\scripts\v7_rtlsaif_report.tcl" -tclargs ($dcp -replace '\\','/') (("$work\rtl_cnn.saif") -replace '\\','/') 'iisc_tb_bench26/dut' ($work -replace '\\','/') 'rtlsaif_iisc_cnn'
if ($LASTEXITCODE -ne 0) { throw 'report_power failed' }
"[$(Get-Date -Format s)] report done"
