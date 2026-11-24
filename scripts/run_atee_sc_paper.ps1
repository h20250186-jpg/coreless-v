# NEW script (2026-11-19). Paper benchmark rows on the scalar-operand design
# (rtl/vector_unit/atee_top_sc.v + hbm_lite_controller_sc.v + ibuf_ram.v, all
# unchanged), testbench testbench/atee_sc_tb.v (unchanged), Vivado 2019.1 xsim,
# BRAM-only, no DMA, ENABLE_DIV=0. Data from scripts/atee_sc_paper.py.
# Usage: powershell -File scripts\run_atee_sc_paper.ps1 [-Programs conv32_5,matmul16,matmul32,matmul64]
# Output: sim_build\atee_sc\paper\<program>\ (cnn_dump.txt, cnn_ref.json, xsim_run.log)
#        add -Distinct for the seeded mixed-sign data sets (output <program>_distinct)
param([string[]]$Programs = @('matmul16','matmul32','matmul64','conv32_5'), [switch]$Distinct)
$ErrorActionPreference = 'Stop'
$Programs = @($Programs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
$base = Join-Path $root 'sim_build\atee_sc\paper'
$snap = Join-Path $base 'snap'
New-Item -ItemType Directory -Force $snap | Out-Null
Set-Location $snap
if (-not (Test-Path (Join-Path $snap 'xsim.dir\atee_sc_snap'))) {
    $vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
            'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
            'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
    $vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'),
            (Join-Path $vu 'ibuf_ram.v'), (Join-Path $vu 'hbm_lite_controller_sc.v'),
            (Join-Path $vu 'atee_top_sc.v'), (Join-Path $root 'testbench\atee_sc_tb.v')
    & "$viv\xvhdl.bat" -work xil_defaultlib @vhdl | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
    & "$viv\xvlog.bat" -work xil_defaultlib @vlog | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & "$viv\xelab.bat" xil_defaultlib.atee_sc_tb -s atee_sc_snap | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
}
$dirs = @()
foreach ($p in $Programs) {
    $out = Join-Path $base ($p + $(if ($Distinct) { '_distinct' } else { '' }))
    $pa = @('prep', $p, $snap); if ($Distinct) { $pa += '--distinct' }
    & $py (Join-Path $root 'scripts\atee_sc_paper.py') @pa
    if ($LASTEXITCODE -ne 0) { throw "prep failed: $p" }
    Remove-Item cnn_dump.txt -ErrorAction SilentlyContinue
    $t0 = Get-Date
    & "$viv\xsim.bat" atee_sc_snap -runall -log xsim_run.log | Out-Null
    $dt = ((Get-Date) - $t0).TotalSeconds
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item cnn_ref.json, xsim_run.log, cnn_params.txt $out -Force
    if (Test-Path cnn_dump.txt) { Move-Item cnn_dump.txt $out -Force }
    $line = Select-String -Path xsim_run.log -Pattern '^CNN_DONE' | Select-Object -First 1
    "$p : $($line.Line)  [$([int]$dt) s]"
    $dirs += $out
}
& $py (Join-Path $root 'scripts\atee_sc_check.py') conv @dirs
