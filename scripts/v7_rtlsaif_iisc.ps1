# NEW (2026-11-14). "RTL-SAIF" power method for the I2SRV32-V full system
# (user decision 2026-11-14). Behavioural RTL simulation in Vivado 2026.1 xsim
# (the RTL design is within the BASIC instance limit: the same build ran in
# 2026.1 on 2026-11-13), built exactly as scripts/run_iisc_conv8_3_2026.ps1
# -MainImage xmem (unchanged; its steps are repeated here into a separate
# directory, with xelab -debug typical so the SAIF script can read signals):
# 2026.1 IP simulation models from the copy's .xcix, mainMem = xmem.coe image,
# DMEM = conv8_3 bank images, their RTL and testbench external/iisc_sim/
# iisc_tb_conv.v unchanged. SAIF windows (testbench/v7_rtlsaif.tcl):
# conv2d() entry -> return, and reset release -> main returns. read_saif onto
# the routed Virtex-7 Run 3 checkpoint (512 KB repo build, their constraints),
# report_power at the nominal 50 MHz clock (their design FAILS timing at 50 MHz).
# Usage: powershell -File scripts\v7_rtlsaif_iisc.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2026_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$repo = Join-Path $root 'external\I2SRV32-V-v1-master'
$rtl  = Join-Path $repo 'Source code\rtl'
$glue = Join-Path $root 'external\iisc_sim'
$ipd  = Join-Path $root 'external_2026\iisc_copy\Source code\IP'
$lst  = Join-Path $root 'synth_build_2026\gate_b2'
$work = Join-Path $root 'synth_build_2026\v7_power_rtlsaif\iisc'
$dcp  = Join-Path $root 'synth_build_2026\v7_xc7vx485t\iisc_fpga_wrapper\post_route.dcp'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
"[$(Get-Date -Format s)] start"
if (-not (Test-Path (Join-Path $work 'xsim.dir\rsnap'))) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $ipdir = Join-Path $work 'ip'
  $simv = @(); $simvhd = @()
  foreach ($x in Get-ChildItem $ipd -Filter *.xcix) {
    $ip = $x.BaseName; $want = @{}
    foreach ($line in Get-Content (Join-Path $lst "files_$ip.txt")) {
      $p = $line.Split("`t"); if ($p.Count -lt 4) { continue }
      $rel = ($p[3] -replace '\\','/'); $i = $rel.IndexOf('/IP/'); if ($i -lt 0) { continue }
      $rel = $rel.Substring($i + 4)
      if ($p[0] -match 'simulation' -and $p[0] -notmatch 'ipstatic' -and $p[2] -eq 'xil_defaultlib') { $want[$rel] = $p[1] }
    }
    $z = [IO.Compression.ZipFile]::OpenRead($x.FullName)
    foreach ($e in $z.Entries) {
      $isMif = $e.Name -like '*.mif'
      if ($want.ContainsKey($e.FullName) -or $isMif) {
        $dst = Join-Path $ipdir $e.FullName
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
        if ($isMif) { Copy-Item $dst (Join-Path $work $e.Name) -Force }
        elseif ($want[$e.FullName] -match 'VHDL') { $simvhd += $dst } else { $simv += $dst }
      }
    }
    $z.Dispose()
  }
  "2026.1 IP simulation files: $($simv.Count) Verilog, $($simvhd.Count) VHDL"
  & $py (Join-Path $root 'scripts\gen_conv_sizes.py') "8" $work
  if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }
  $tmp = Join-Path $work 'xmem_mif'
  & $py (Join-Path $glue 'gen_mif.py') (Join-Path $repo 'benchmarks\benchmarks\conv\conv8_3\Outputfiles') $tmp
  if ($LASTEXITCODE -ne 0) { throw 'gen_mif failed' }
  Copy-Item (Join-Path $tmp 'mainMem.mif') (Join-Path $work 'mainMem.mif') -Force
  "mainMem.mif REPLACED by the xmem.coe image (2019.1 baseline program image, as Run 3)"
  $vhdl = @($simvhd)
  $vhdl += Get-ChildItem (Join-Path $rtl 'FPU\fpu') -File | Where-Object { $_.Extension -in '.vhd','.vhdl' } | ForEach-Object { $_.FullName }
  $vu = Join-Path $rtl 'vector_unit'
  $vhdl += 'mypack','alu','count_gen','lsu','stall_gen','dmem_addr_xbar','vrf_bank','multicycle_ops','vminmax','xoutreg','cpu_inf','exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
  $fv = @('-work xil_defaultlib') + ($vhdl | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' })
  $fv | Set-Content -Encoding ascii (Join-Path $work 'vhdl.f')
  & "$viv\xvhdl.bat" -f vhdl.f
  if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
  $vlog = @($simv)
  $vlog += (Join-Path $glue 'xbip_dsp48_macro_missing.v')
  $vlog += Get-ChildItem $rtl -Recurse -File -Filter *.v | Where-Object { $_.Name -notin 'defines.v','timescale.v','uart_defines.v' } | ForEach-Object { $_.FullName }
  $vlog += (Join-Path $repo 'Source code\testbench\FPGA_WRAPPER.v')
  $vlog += (Join-Path $glue 'iisc_tb_conv.v')
  $vlog += (Join-Path $VIVADO2026_ROOT 'data\verilog\src\glbl.v')
  $f = @('--relax', '-work xil_defaultlib', ('-i "' + ($rtl -replace '\\','/') + '"'), '-d itlb_def=1', '-d test_tlb=1', '-d hardware_test=0')
  $f += $vlog | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' }
  $f | Set-Content -Encoding ascii (Join-Path $work 'vlog.f')
  & "$viv\xvlog.bat" -f vlog.f
  if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
  & "$viv\xelab.bat" -debug typical -L xil_defaultlib -L blk_mem_gen_v8_4_13 -L div_gen_v5_1_26 -L dsp_macro_v1_0_10 -L xbip_utils_v3_0_16 -L xbip_pipe_v3_0_12 -L xbip_dsp48_wrapper_v3_0_7 -L xbip_multadd_v3_0_24 -L axi_utils_v2_0_12 -L mult_gen_v12_0_25 -L unisims_ver -L unimacro_ver -L secureip --relax xil_defaultlib.iisc_tb_conv xil_defaultlib.glbl -s rsnap
  if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
  "[$(Get-Date -Format s)] snapshot built"
}
foreach ($w in 'conv','all') {
  $env:RS_TB = 'iisc_tb_conv'; $env:RS_WIN = "iisc_$w"; $env:RS_FILE = "rtl_$w.saif"
  $env:RS_SKIP = '^$'; $env:RS_NODESCEND = '^$'
  & "$viv\xsim.bat" rsnap -log "xsim_$w.log" -tclbatch (("$root\testbench\v7_rtlsaif.tcl") -replace '\\','/')
  if ($LASTEXITCODE -ne 0) { throw "xsim $w failed" }
  "[$(Get-Date -Format s)] xsim $w done"
  & "$viv\vivado.bat" -mode batch -nojournal -log "report_$w.log" -source "$root\scripts\v7_rtlsaif_report.tcl" -tclargs ($dcp -replace '\\','/') (("$work\rtl_$w.saif") -replace '\\','/') 'iisc_tb_conv/dut' ($work -replace '\\','/') "rtlsaif_iisc_$w"
  if ($LASTEXITCODE -ne 0) { throw "report_power $w failed" }
  "[$(Get-Date -Format s)] report $w done"
}
