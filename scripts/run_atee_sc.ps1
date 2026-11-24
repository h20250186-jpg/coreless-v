# NEW script (2026-11-17, scalar-operand variant). Runs Coreless-V's
# scalar-operand controller (rtl/vector_unit/atee_top_sc.v +
# hbm_lite_controller_sc.v + ibuf_ram.v), testbench testbench/atee_sc_tb.v,
# Vivado 2019.1 xsim. BRAM-only, no DMA, ENABLE_DIV=0. Nothing from archive/
# is compiled; no existing RTL/script is changed.
# Usage:
#   powershell -File scripts\run_atee_sc.ps1 -Mode conv -Size 8|16|32|64 [-Distinct]
#   powershell -File scripts\run_atee_sc.ps1 -Mode cnn -Layers 1|2|3 -From 0 -To 99 [-Tag name]
# Output: sim_build\atee_sc\<Tag>\<run>\ (cnn_dump.txt, cnn_ref.json, xsim_run.log)
param([string]$Mode = 'cnn', [int]$Size = 8, [switch]$Distinct, [int]$Layers = 3,
      [int]$From = 0, [int]$To = 0, [string]$Tag = '', [switch]$BuildOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$viv  = Join-Path $VIVADO2019_ROOT 'bin'
$py   = $PYTHON
$root = Split-Path -Parent $PSScriptRoot
$vu   = Join-Path $root 'rtl\vector_unit'
if (-not $Tag) { $Tag = if ($Mode -eq 'conv') { 'conv' } else { "L$Layers" } }
$base = Join-Path $root "sim_build\atee_sc\$Tag"
$snap = Join-Path $base $(if ($Mode -eq 'conv') { "snap_conv$Size$(if ($Distinct) { 'd' })" } else { "snap_${From}_$To" })
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
    & "$viv\xvlog.bat" -work xil_defaultlib @vlog
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & "$viv\xelab.bat" xil_defaultlib.atee_sc_tb -s atee_sc_snap | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
}
if ($BuildOnly) { return }

function Run-One([string]$out, [string[]]$prepArgs) {
    if (Test-Path (Join-Path $out 'cnn_dump.txt')) { "$(Split-Path -Leaf $out) already done"; return }
    & $py (Join-Path $root 'scripts\atee_sc_prep.py') @prepArgs
    if ($LASTEXITCODE -ne 0) { throw "prep failed: $prepArgs" }
    Remove-Item cnn_dump.txt -ErrorAction SilentlyContinue
    $t0 = Get-Date
    & "$viv\xsim.bat" atee_sc_snap -runall -log xsim_run.log | Out-Null
    $dt = ((Get-Date) - $t0).TotalSeconds
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item cnn_ref.json, xsim_run.log, cnn_params.txt $out -Force
    if (Test-Path cnn_dump.txt) { Move-Item cnn_dump.txt $out -Force }
    $line = Select-String -Path xsim_run.log -Pattern '^CNN_DONE' | Select-Object -First 1
    "$(Split-Path -Leaf $out) : $($line.Line)  [$([int]$dt) s]"
}

if ($Mode -eq 'conv') {
    $name = "conv$Size" + $(if ($Distinct) { '_distinct' } else { '' })
    $pa = @('conv', "$Size", $snap); if ($Distinct) { $pa += '--distinct' }
    Run-One (Join-Path $base $name) $pa
} else {
    for ($k = $From; $k -le $To; $k++) {
        Run-One (Join-Path $base "img$k") @('cnn', "$k", $snap, "$Layers")
    }
}
