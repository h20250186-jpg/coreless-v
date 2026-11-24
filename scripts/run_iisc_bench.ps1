# NEW script (2026-11-15), a copy of run_iisc_conv_sizes.ps1 (unchanged)
# generalised to ANY of THEIR benchmark programs. Simulates the I2SRV32-V repo's
# OWN design (top FPGA_WRAPPER, repo build = Run-3 configuration, 512 KB
# scratchpad) on its OWN program (memory images rebuilt from the program's ELF
# by scripts/iisc_bench_prep.py and checked word by word against the shipped
# .coe files). Same substitutions, defines and Vivado 2019.1 xsim as the
# 3,181-cycle conv8_3 baseline. Nothing from this project's rtl/ is compiled.
# Testbench: external/iisc_sim/iisc_tb_bench.v. Result check:
# scripts/iisc_bench_check.py.
# Usage: powershell -File scripts\run_iisc_bench.ps1 -Program saxpy8 [-Image 0] [-Mode shipped|relocated] [-Tag x]
param([Parameter(Mandatory)][string]$Program, [int]$Image = 0,
      [ValidateSet('shipped','relocated')][string]$Mode = 'shipped', [string]$Tag = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$repo = Join-Path $root 'external\I2SRV32-V-v1-master'
$rtl  = Join-Path $repo 'Source code\rtl'
$ipx  = Join-Path $root 'external\ip_extracted'
$glue = Join-Path $root 'external\iisc_sim'
$name = $Program; if ($Program -eq 'cnn') { $name = "cnn_img$Image" }; if ($Mode -ne 'shipped') { $name += "_$Mode" }; if ($Tag) { $name += "_$Tag" }
$work = Join-Path $root "sim_build\iisc_bench\$name"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
"[$(Get-Date -Format s)] program $Program image $Image mode $Mode -> $work"

& $py (Join-Path $root 'scripts\iisc_bench_prep.py') $Program $work "$Image" $Mode
if ($LASTEXITCODE -ne 0) { throw 'iisc_bench_prep failed' }

foreach ($n in 'div_gen_0','div_gen_1') {
    (Get-Content (Join-Path $ipx "$n\sim\$n.vhd") -Raw).Replace('div_gen_v5_1_17','div_gen_v5_1_15') | Set-Content -Encoding ascii (Join-Path $work "$n.vhd")
}
(Get-Content (Join-Path $ipx 'xbip_dsp48_macro_0\sim\xbip_dsp48_macro_0.vhd') -Raw).Replace('xbip_dsp48_macro_v3_0_18','xbip_dsp48_macro_v3_0_17') | Set-Content -Encoding ascii (Join-Path $work 'xbip_dsp48_macro_0.vhd')
$vhdl = @((Join-Path $work 'div_gen_0.vhd'), (Join-Path $work 'div_gen_1.vhd'), (Join-Path $work 'xbip_dsp48_macro_0.vhd'))
$vhdl += Get-ChildItem (Join-Path $rtl 'FPU\fpu') -File | Where-Object { $_.Extension -in '.vhd','.vhdl' } | ForEach-Object { $_.FullName }
$vu = Join-Path $rtl 'vector_unit'
$vhdl += 'mypack','alu','count_gen','lsu','stall_gen','dmem_addr_xbar','vrf_bank','multicycle_ops','vminmax','xoutreg','cpu_inf','exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
& "$viv\xvhdl.bat" -work xil_defaultlib @vhdl | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }

$vlog = @((Join-Path $ipx 'mainMem\simulation\blk_mem_gen_v8_4.v'))
$vlog += 'mainMem','dcache','tag_ram','BTB_mem','PHT_mem','blk_mem_gen_v7_3','blk_mem_gen_v7_3_2','DMEM_0','DMEM_1','DMEM_2','DMEM_3','DMEM_4','DMEM_5','DMEM_6','DMEM_7' | ForEach-Object { Join-Path $ipx "$_\sim\$_.v" }
$vlog += (Join-Path $glue 'clk_wiz_0_behav.v')
$vlog += (Join-Path $glue 'xbip_dsp48_macro_missing.v')
$vlog += Get-ChildItem $rtl -Recurse -File -Filter *.v | Where-Object { $_.Name -notin 'defines.v','timescale.v','uart_defines.v' } | ForEach-Object { $_.FullName }
$vlog += (Join-Path $repo 'Source code\testbench\FPGA_WRAPPER.v')
$vlog += (Join-Path $glue 'iisc_tb_bench.v')
$f = @('-work xil_defaultlib', ('-i "' + ($rtl -replace '\\','/') + '"'), '-d itlb_def=1', '-d test_tlb=1', '-d hardware_test=0')
$f += $vlog | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' }
$f | Set-Content -Encoding ascii (Join-Path $work 'vlog.f')
& "$viv\xvlog.bat" -f vlog.f | Out-Null
if ($LASTEXITCODE -ne 0) { Get-Content xvlog.log -Tail 20; throw 'xvlog failed' }
& "$viv\xelab.bat" -debug typical -L xil_defaultlib -L div_gen_v5_1_15 -L xbip_dsp48_macro_v3_0_17 -L unisims_ver -L secureip xil_defaultlib.iisc_tb_bench -s bench_snap | Out-Null
if ($LASTEXITCODE -ne 0) { Select-String -Path xelab.log -Pattern 'ERROR' | Select-Object -First 10 | ForEach-Object { $_.Line }; throw 'xelab failed' }
"[$(Get-Date -Format s)] snapshot built, simulating"
& "$viv\xsim.bat" bench_snap -tclbatch ((Join-Path $glue 'iisc_bench_dump.tcl') -replace '\\','/')
"[$(Get-Date -Format s)] simulation finished"
& $py (Join-Path $root 'scripts\iisc_bench_check.py') $work
