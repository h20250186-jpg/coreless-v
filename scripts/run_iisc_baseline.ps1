# Simulates the I2SRV32-V repo's OWN design (external/I2SRV32-V-v1-master,
# top FPGA_WRAPPER) running its OWN conv8_3 program image in xsim.
# Nothing from rtl/ of this project is compiled here.
#
# Substitutions forced by this machine (Vivado 2019.1; the repo's IP containers
# are from Vivado 2020.2 and cannot be regenerated):
#   - block memories: the repo's own behavioural simulation wrappers
#     (blk_mem_gen_v8_4.v + sim/*.v from the .xcix containers), with
#     mainMem.mif / DMEM_n.mif regenerated from conv8_3/Outputfiles/*.coe
#   - div_gen_0/1, xbip_dsp48_macro_0: the repo's own sim wrappers, pointed at
#     the Vivado 2019.1 library versions (v5_1_15 / v3_0_17) instead of 2020.2's
#   - clk_wiz_0: behavioural clock model (external/iisc_sim/clk_wiz_0_behav.v)
# Usage: powershell -File scripts\run_iisc_baseline.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$repo = Join-Path $root 'external\I2SRV32-V-v1-master'
$rtl  = Join-Path $repo 'Source code\rtl'
$ipx  = Join-Path $root 'external\ip_extracted'
$glue = Join-Path $root 'external\iisc_sim'
$work = Join-Path $root 'sim_build\iisc_baseline'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

# memory images for THIS benchmark
& $py (Join-Path $glue 'gen_mif.py') (Join-Path $repo 'benchmarks\benchmarks\conv\conv8_3\Outputfiles') $work
if ($LASTEXITCODE -ne 0) { throw 'gen_mif failed' }

# library-version patches of the repo's VHDL sim wrappers
foreach ($n in 'div_gen_0','div_gen_1') {
    (Get-Content (Join-Path $ipx "$n\sim\$n.vhd") -Raw).Replace('div_gen_v5_1_17','div_gen_v5_1_15') | Set-Content -Encoding ascii (Join-Path $work "$n.vhd")
}
(Get-Content (Join-Path $ipx 'xbip_dsp48_macro_0\sim\xbip_dsp48_macro_0.vhd') -Raw).Replace('xbip_dsp48_macro_v3_0_18','xbip_dsp48_macro_v3_0_17') | Set-Content -Encoding ascii (Join-Path $work 'xbip_dsp48_macro_0.vhd')

# ---- VHDL: IP wrappers, FPU, vector unit (mypack first, exe_unit/wrapper last)
$vhdl = @((Join-Path $work 'div_gen_0.vhd'), (Join-Path $work 'div_gen_1.vhd'), (Join-Path $work 'xbip_dsp48_macro_0.vhd'))
$vhdl += Get-ChildItem (Join-Path $rtl 'FPU\fpu') -File | Where-Object { $_.Extension -in '.vhd','.vhdl' } | ForEach-Object { $_.FullName }
$vu = Join-Path $rtl 'vector_unit'
$vhdl += 'mypack','alu','count_gen','lsu','stall_gen','dmem_addr_xbar','vrf_bank','multicycle_ops','vminmax','xoutreg','cpu_inf','exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }

# ---- Verilog: blk_mem_gen behavioural model + IP sim wrappers + all RTL + testbench
$vlog = @((Join-Path $ipx 'mainMem\simulation\blk_mem_gen_v8_4.v'))
$vlog += 'mainMem','dcache','tag_ram','BTB_mem','PHT_mem','blk_mem_gen_v7_3','blk_mem_gen_v7_3_2','DMEM_0','DMEM_1','DMEM_2','DMEM_3','DMEM_4','DMEM_5','DMEM_6','DMEM_7' | ForEach-Object { Join-Path $ipx "$_\sim\$_.v" }
$vlog += (Join-Path $glue 'clk_wiz_0_behav.v')
# xbip_dsp48_macro_1 / _2 are instantiated by the repo's RTL but NOT shipped in
# its IP folder: assumed-function stand-ins (TLB replacement ranking only)
$vlog += (Join-Path $glue 'xbip_dsp48_macro_missing.v')
$vlog += Get-ChildItem $rtl -Recurse -File -Filter *.v | Where-Object { $_.Name -notin 'defines.v','timescale.v','uart_defines.v' } | ForEach-Object { $_.FullName }
$vlog += (Join-Path $repo 'Source code\testbench\FPGA_WRAPPER.v')
$vlog += (Join-Path $glue 'iisc_tb.v')
# defines from the repo's testbench readme: itlb_def=1, test_tlb=1, hardware_test=0
# (passed through an options file: ~110 long paths exceed the command-line limit)
$f = @('-work xil_defaultlib', ('-i "' + ($rtl -replace '\\','/') + '"'), '-d itlb_def=1', '-d test_tlb=1', '-d hardware_test=0')
$f += $vlog | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' }
$f | Set-Content -Encoding ascii (Join-Path $work 'vlog.f')
& "$viv\xvlog.bat" -f vlog.f
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }

& "$viv\xelab.bat" -L xil_defaultlib -L div_gen_v5_1_15 -L xbip_dsp48_macro_v3_0_17 -L unisims_ver -L secureip xil_defaultlib.iisc_tb -s iisc_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" iisc_snap -runall
