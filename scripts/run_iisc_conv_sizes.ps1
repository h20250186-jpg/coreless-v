# NEW script (2026-11-11), a copy of run_iisc_baseline_dtlb.ps1 (unchanged)
# generalised to THEIR CONV2D 3x3 benchmarks conv8_3 .. conv64_3.
# Simulates the I2SRV32-V repo's OWN design (top FPGA_WRAPPER) on its OWN
# program image for the chosen size; same substitutions and defines as the
# 3,181-cycle conv8_3 baseline. Nothing from this project's rtl/ is compiled.
# Testbench: external/iisc_sim/iisc_tb_conv.v (cycles, err_count, ITLB+DTLB
# stand-in probes, read capture of their Y[] for the exactness check).
# Usage: powershell -File scripts\run_iisc_conv_sizes.ps1 -Size 8|16|32|64 [-StandIn assumed|zero]
param([Parameter(Mandatory)][int]$Size, [ValidateSet('assumed','zero')][string]$StandIn = 'assumed')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$repo = Join-Path $root 'external\I2SRV32-V-v1-master'
$rtl  = Join-Path $repo 'Source code\rtl'
$ipx  = Join-Path $root 'external\ip_extracted'
$glue = Join-Path $root 'external\iisc_sim'
$work = Join-Path $root ("sim_build\iisc_conv${Size}_$StandIn")
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

# their memory images for THIS size, and the per-size parameters / reference data
& $py (Join-Path $glue 'gen_mif.py') (Join-Path $repo "benchmarks\benchmarks\conv\conv${Size}_3\Outputfiles") $work
if ($LASTEXITCODE -ne 0) { throw 'gen_mif failed' }
& $py (Join-Path $root 'scripts\gen_conv_sizes.py') "$Size" $work
if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }

foreach ($n in 'div_gen_0','div_gen_1') {
    (Get-Content (Join-Path $ipx "$n\sim\$n.vhd") -Raw).Replace('div_gen_v5_1_17','div_gen_v5_1_15') | Set-Content -Encoding ascii (Join-Path $work "$n.vhd")
}
(Get-Content (Join-Path $ipx 'xbip_dsp48_macro_0\sim\xbip_dsp48_macro_0.vhd') -Raw).Replace('xbip_dsp48_macro_v3_0_18','xbip_dsp48_macro_v3_0_17') | Set-Content -Encoding ascii (Join-Path $work 'xbip_dsp48_macro_0.vhd')

$vhdl = @((Join-Path $work 'div_gen_0.vhd'), (Join-Path $work 'div_gen_1.vhd'), (Join-Path $work 'xbip_dsp48_macro_0.vhd'))
$vhdl += Get-ChildItem (Join-Path $rtl 'FPU\fpu') -File | Where-Object { $_.Extension -in '.vhd','.vhdl' } | ForEach-Object { $_.FullName }
$vu = Join-Path $rtl 'vector_unit'
$vhdl += 'mypack','alu','count_gen','lsu','stall_gen','dmem_addr_xbar','vrf_bank','multicycle_ops','vminmax','xoutreg','cpu_inf','exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }

$vlog = @((Join-Path $ipx 'mainMem\simulation\blk_mem_gen_v8_4.v'))
$vlog += 'mainMem','dcache','tag_ram','BTB_mem','PHT_mem','blk_mem_gen_v7_3','blk_mem_gen_v7_3_2','DMEM_0','DMEM_1','DMEM_2','DMEM_3','DMEM_4','DMEM_5','DMEM_6','DMEM_7' | ForEach-Object { Join-Path $ipx "$_\sim\$_.v" }
$vlog += (Join-Path $glue 'clk_wiz_0_behav.v')
$vlog += (Join-Path $glue $(if ($StandIn -eq 'zero') { 'xbip_dsp48_macro_zero.v' } else { 'xbip_dsp48_macro_missing.v' }))
Write-Host "size: ${Size}x${Size}  stand-ins: $StandIn"
$vlog += Get-ChildItem $rtl -Recurse -File -Filter *.v | Where-Object { $_.Name -notin 'defines.v','timescale.v','uart_defines.v' } | ForEach-Object { $_.FullName }
$vlog += (Join-Path $repo 'Source code\testbench\FPGA_WRAPPER.v')
$vlog += (Join-Path $glue 'iisc_tb_conv.v')
$f = @('-work xil_defaultlib', ('-i "' + ($rtl -replace '\\','/') + '"'), '-d itlb_def=1', '-d test_tlb=1', '-d hardware_test=0')
$f += $vlog | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' }
$f | Set-Content -Encoding ascii (Join-Path $work 'vlog.f')
& "$viv\xvlog.bat" -f vlog.f
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }

& "$viv\xelab.bat" -L xil_defaultlib -L div_gen_v5_1_15 -L xbip_dsp48_macro_v3_0_17 -L unisims_ver -L secureip xil_defaultlib.iisc_tb_conv -s iisc_conv_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" iisc_conv_snap -runall
