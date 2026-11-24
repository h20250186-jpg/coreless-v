# NEW (2026-11-19, task H). Compiles one vector-unit tree from
# sim_build_h/trees/<Tree>/vector_unit (built by scripts/h_trees.py) plus the given
# Verilog sources, in the CURRENT directory, Vivado 2019.1. Dot-source it.
# Memory and divider models follow what the tree's own files instantiate:
#   exe_unit uses dmem_bram       -> our behavioural dmem_bram.vhd
#   exe_unit uses DMEM_0..7 (IP)  -> THEIR blk_mem_gen sim wrappers + blk_mem_gen_v8_4.v
#                                    (external/ip_extracted, as scripts/run_iisc_baseline.ps1),
#                                    DMEM_n.mif written all-zero (their wrappers load it at t=0)
#   multicycle_ops uses div_gen_behav -> our div_gen_behav.vhd
#   multicycle_ops uses div_gen_0/1   -> THEIR div_gen sim wrappers, library v5_1_17 -> v5_1_15
#                                        (as scripts/run_iisc_baseline.ps1)
# Usage: . scripts\h_compile.ps1; H-Compile -Tree min -Vlog @(...) -Top atee_sc_tb -Snap atee_sc_snap [-Debug]
function H-Compile([string]$Tree, [string[]]$Vlog, [string]$Top, [string]$Snap, [switch]$Debug) {
    . (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
    $viv  = Join-Path $VIVADO2019_ROOT 'bin'
    $root = Split-Path -Parent $PSScriptRoot
    if (-not (Test-Path (Join-Path $root 'rtl'))) { $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
    $vu   = Join-Path $root "sim_build_h\trees\$Tree\vector_unit"
    $ipx  = Join-Path $root 'external\ip_extracted'
    if (-not (Test-Path (Join-Path $vu 'exe_unit.vhd'))) { throw "tree $Tree not built" }
    $ipDmem = -not (Select-String -Path (Join-Path $vu 'exe_unit.vhd') -Pattern 'DMEM0: dmem_bram' -Quiet)
    $ipDiv  = -not (Select-String -Path (Join-Path $vu 'multicycle_ops.vhd') -Pattern 'div_gen_behav' -Quiet)
    $vhdl = @()
    if ($ipDiv) {
        foreach ($n in 'div_gen_0','div_gen_1') {
            (Get-Content (Join-Path $ipx "$n\sim\$n.vhd") -Raw).Replace('div_gen_v5_1_17','div_gen_v5_1_15') | Set-Content -Encoding ascii "$n.vhd"
            $vhdl += (Join-Path (Get-Location) "$n.vhd")
        }
    }
    $names = 'mypack','alu','count_gen','lsu','stall_gen'
    if (-not $ipDmem) { $names += 'dmem_bram' }
    $names += 'dmem_addr_xbar','vrf_bank'
    if (-not $ipDiv) { $names += 'div_gen_behav' }
    $names += 'multicycle_ops','vminmax','xoutreg','cpu_inf','exe_unit','wrapper'
    $vhdl += $names | ForEach-Object { Join-Path $vu "$_.vhd" }
    & "$viv\xvhdl.bat" -work xil_defaultlib @vhdl | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }
    $vl = @()
    if ($ipDmem) {
        $vl += (Join-Path $ipx 'mainMem\simulation\blk_mem_gen_v8_4.v')
        $vl += 0..7 | ForEach-Object { Join-Path $ipx "DMEM_$_\sim\DMEM_$_.v" }
        $zero = (('0' * 32) + "`n") * 16384
        0..7 | ForEach-Object { [IO.File]::WriteAllText((Join-Path (Get-Location) "DMEM_$_.mif"), $zero) }
    }
    $vl += $Vlog
    & "$viv\xvlog.bat" -work xil_defaultlib @vl | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    $ea = @('-L','xil_defaultlib')
    if ($ipDiv) { $ea += '-L','div_gen_v5_1_15' }
    if ($Debug) { $ea += '-debug','typical' }
    & "$viv\xelab.bat" @ea "xil_defaultlib.$Top" -s $Snap | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
    "compiled tree $Tree (DMEM: $(if ($ipDmem) {'THEIR IP model, WRITE_FIRST'} else {'dmem_bram, READ_FIRST'}); divider: $(if ($ipDiv) {'THEIR div_gen IP model'} else {'div_gen_behav'}))"
}
