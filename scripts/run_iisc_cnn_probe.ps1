# NEW (2026-11-16). cnn_demo checks A.1 / A.3 on THEIR design (FPGA_WRAPPER,
# repo build = Run-3 configuration), Vivado 2019.1 xsim, same substitutions and
# defines as scripts/run_iisc_bench.ps1 (unchanged). Differences:
#   - testbench external/iisc_sim/iisc_tb_cnn_probe.v (copy of iisc_tb_bench.v
#     + probes of the xbip_dsp48_macro_1/_2 stand-ins, + optional UART feed)
#   - -StandIn assumed : external/iisc_sim/xbip_dsp48_macro_missing.v (the
#                        stand-in of every recorded IISc result)
#     -StandIn zero    : external/iisc_sim/xbip_dsp48_macro_zero.v (outputs tied
#                        to 0, the second stand-in of the 2026-10-19 DTLB check)
#   - -Uart            : compile with -d UART_FEED (image sent over srx_pad_i,
#                        no preload)
# Snapshot per variant in sim_build/iisc_cnn_probe/snap_<variant>; one run dir
# per image sim_build/iisc_cnn_probe/<variant>/img<k>; logs in
# sim_build/iisc_cnn_probe/logs/<variant>_img<k>.txt.
# Usage: powershell -File scripts\run_iisc_cnn_probe.ps1 -StandIn zero -BuildOnly
#        powershell -File scripts\run_iisc_cnn_probe.ps1 -StandIn zero -From 0 -To 33
param([ValidateSet('assumed','zero')][string]$StandIn = 'assumed', [switch]$Uart,
      [int]$From = 0, [int]$To = 0, [switch]$BuildOnly, [int]$MaxCyc = 40000000)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$repo = Join-Path $root 'external\I2SRV32-V-v1-master'
$rtl  = Join-Path $repo 'Source code\rtl'
$ipx  = Join-Path $root 'external\ip_extracted'
$glue = Join-Path $root 'external\iisc_sim'
$var  = $StandIn; if ($Uart) { $var += '_uart' }
$base = Join-Path $root 'sim_build\iisc_cnn_probe'
$snapd = Join-Path $base "snap_$var"
$logs = Join-Path $base 'logs'
New-Item -ItemType Directory -Force $snapd, $logs | Out-Null
$tcl  = (Join-Path $glue 'iisc_bench_dump.tcl') -replace '\\','/'

if (-not (Test-Path (Join-Path $snapd 'xsim.dir\bench_snap'))) {
    Set-Location $snapd
    "[$(Get-Date -Format s)] building snapshot $var in $snapd"
    foreach ($n in 'div_gen_0','div_gen_1') {
        (Get-Content (Join-Path $ipx "$n\sim\$n.vhd") -Raw).Replace('div_gen_v5_1_17','div_gen_v5_1_15') | Set-Content -Encoding ascii (Join-Path $snapd "$n.vhd")
    }
    (Get-Content (Join-Path $ipx 'xbip_dsp48_macro_0\sim\xbip_dsp48_macro_0.vhd') -Raw).Replace('xbip_dsp48_macro_v3_0_18','xbip_dsp48_macro_v3_0_17') | Set-Content -Encoding ascii (Join-Path $snapd 'xbip_dsp48_macro_0.vhd')
    $vhdl = @((Join-Path $snapd 'div_gen_0.vhd'), (Join-Path $snapd 'div_gen_1.vhd'), (Join-Path $snapd 'xbip_dsp48_macro_0.vhd'))
    $vhdl += Get-ChildItem (Join-Path $rtl 'FPU\fpu') -File | Where-Object { $_.Extension -in '.vhd','.vhdl' } | ForEach-Object { $_.FullName }
    $vu = Join-Path $rtl 'vector_unit'
    $vhdl += 'mypack','alu','count_gen','lsu','stall_gen','dmem_addr_xbar','vrf_bank','multicycle_ops','vminmax','xoutreg','cpu_inf','exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
    & "$viv\xvhdl.bat" -work xil_defaultlib @vhdl | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
    $vlog = @((Join-Path $ipx 'mainMem\simulation\blk_mem_gen_v8_4.v'))
    $vlog += 'mainMem','dcache','tag_ram','BTB_mem','PHT_mem','blk_mem_gen_v7_3','blk_mem_gen_v7_3_2','DMEM_0','DMEM_1','DMEM_2','DMEM_3','DMEM_4','DMEM_5','DMEM_6','DMEM_7' | ForEach-Object { Join-Path $ipx "$_\sim\$_.v" }
    $vlog += (Join-Path $glue 'clk_wiz_0_behav.v')
    if ($StandIn -eq 'zero') { $vlog += (Join-Path $glue 'xbip_dsp48_macro_zero.v') } else { $vlog += (Join-Path $glue 'xbip_dsp48_macro_missing.v') }
    $vlog += Get-ChildItem $rtl -Recurse -File -Filter *.v | Where-Object { $_.Name -notin 'defines.v','timescale.v','uart_defines.v' } | ForEach-Object { $_.FullName }
    $vlog += (Join-Path $repo 'Source code\testbench\FPGA_WRAPPER.v')
    $vlog += (Join-Path $glue 'iisc_tb_cnn_probe.v')
    $f = @('-work xil_defaultlib', ('-i "' + ($rtl -replace '\\','/') + '"'), '-d itlb_def=1', '-d test_tlb=1', '-d hardware_test=0')
    if ($Uart) { $f += '-d UART_FEED' }
    $f += $vlog | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' }
    $f | Set-Content -Encoding ascii (Join-Path $snapd 'vlog.f')
    & "$viv\xvlog.bat" -f vlog.f | Out-Null
    if ($LASTEXITCODE -ne 0) { Get-Content xvlog.log -Tail 20; throw 'xvlog failed' }
    & "$viv\xelab.bat" -debug typical -L xil_defaultlib -L div_gen_v5_1_15 -L xbip_dsp48_macro_v3_0_17 -L unisims_ver -L secureip xil_defaultlib.iisc_tb_bench -s bench_snap | Out-Null
    if ($LASTEXITCODE -ne 0) { Select-String -Path xelab.log -Pattern 'ERROR' | Select-Object -First 10 | ForEach-Object { $_.Line }; throw 'xelab failed' }
    "[$(Get-Date -Format s)] snapshot $var built"
}
if ($BuildOnly) { return }

for ($k = $From; $k -le $To; $k++) {
    $log = Join-Path $logs "${var}_img$k.txt"
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern '^CHECK ' -Quiet)) { continue }
    $work = Join-Path $base "$var\img$k"
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Location $work
    & {
        "[$(Get-Date -Format s)] cnn image $k, variant $var, snapshot $snapd"
        & $py (Join-Path $root 'scripts\iisc_bench_prep.py') cnn $work "$k" shipped
        if (Test-Path (Join-Path $work 'xsim.dir')) { Remove-Item -Recurse -Force (Join-Path $work 'xsim.dir') }
        Copy-Item -Recurse (Join-Path $snapd 'xsim.dir') (Join-Path $work 'xsim.dir')
        # (no -testplusarg: xsim.bat splits "MAXCYC=..." at '='; the testbench default 40M cycles applies)
        & "$viv\xsim.bat" bench_snap -tclbatch $tcl
        "[$(Get-Date -Format s)] simulation finished"
        & $py (Join-Path $root 'scripts\iisc_bench_check.py') $work
        Remove-Item -Recurse -Force (Join-Path $work 'xsim.dir')
    } *> $log
}
