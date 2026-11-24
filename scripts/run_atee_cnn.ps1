# NEW script (2026-11-17, task G). cnn_demo on Coreless-V's CNN controller
# (rtl/vector_unit/atee_top_cnn.v + hbm_lite_controller_cnn.v), testbench
# testbench/atee_cnn_tb.v, Vivado 2019.1 xsim. BRAM-only, no DMA, ENABLE_DIV=0.
# Nothing from archive/ is compiled; no existing RTL/script is changed.
# Usage: powershell -File scripts\run_atee_cnn.ps1 -Layers 1|2|3 -From 0 -To 99 [-Tag name] [-BuildOnly]
# Output: sim_build\atee_cnn\<Tag>\img<k>\ (cnn_dump.txt, cnn_ref.json, xsim.log)
param([int]$Layers = 3, [int]$From = 0, [int]$To = 0, [string]$Tag = '', [switch]$BuildOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
if (-not $Tag) { $Tag = "L$Layers" }
$base = Join-Path $root "sim_build\atee_cnn\$Tag"
$snap = Join-Path $base "snap_${From}_$To"
New-Item -ItemType Directory -Force $snap | Out-Null
Set-Location $snap

if (-not (Test-Path (Join-Path $snap 'xsim.dir\atee_cnn_snap'))) {
    $vhdl = 'mypack','alu','count_gen','lsu','stall_gen','dmem_bram','dmem_addr_xbar',
            'vrf_bank','div_gen_behav','multicycle_ops','vminmax','xoutreg','cpu_inf',
            'exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
    $vlog = (Join-Path $vu 'v_wrapper.v'), (Join-Path $vu 'tensor_config_regs.v'),
            (Join-Path $vu 'hbm_lite_controller_cnn.v'), (Join-Path $vu 'atee_top_cnn.v'),
            (Join-Path $root 'testbench\atee_cnn_tb.v')
    & "$viv\xvhdl.bat" -work xil_defaultlib @vhdl
    if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
    & "$viv\xvlog.bat" -work xil_defaultlib @vlog
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & "$viv\xelab.bat" xil_defaultlib.atee_cnn_tb -s atee_cnn_snap
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
}
if ($BuildOnly) { return }

for ($k = $From; $k -le $To; $k++) {
    $out = Join-Path $base "img$k"
    if (Test-Path (Join-Path $out 'cnn_dump.txt')) { "img$k already done"; continue }
    & $py (Join-Path $root 'scripts\atee_cnn_prep.py') $k $snap $Layers
    if ($LASTEXITCODE -ne 0) { throw "prep failed for image $k" }
    Remove-Item cnn_dump.txt -ErrorAction SilentlyContinue
    $t0 = Get-Date
    & "$viv\xsim.bat" atee_cnn_snap -runall -log xsim_run.log | Out-Null
    $dt = ((Get-Date) - $t0).TotalSeconds
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item cnn_ref.json, xsim_run.log, cnn_params.txt $out -Force
    if (Test-Path cnn_dump.txt) { Move-Item cnn_dump.txt $out -Force }
    $line = Select-String -Path xsim_run.log -Pattern '^CNN_DONE' | Select-Object -First 1
    "img$k : $($line.Line)  [$([int]$dt) s]"
}
