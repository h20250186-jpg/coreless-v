# NEW script (2026-11-12). Vivado 2026.1 gate test, step (c): simulate the
# I2SRV32-V repo's OWN design (top FPGA_WRAPPER) on conv8_3 in 2026.1 xsim,
# with the IP generated in the 2026.1 COPY (external_2026/iisc_copy/, see
# scripts/v2026_gate_b2.tcl): all 19 IP simulation models come from the
# upgraded .xcix of the copy, compiled against 2026.1's precompiled IP
# libraries. Compared with the 2019.1 baseline (run_iisc_conv_sizes.ps1 -Size 8):
#   - clk_wiz_0: the IP's own simulation model (MMCM), NOT our behavioural clock
#   - div_gen_0/1, xbip_dsp48_macro_0 (now dsp_macro 1.0): 2026.1 IP models
#   - block memories: 2026.1 blk_mem_gen 8.4 rev 13 models; init images are the
#     .mif files the IP generated from conv8_3's COE files
#   - xbip_dsp48_macro_1/_2: still OUR assumed-function stand-ins (not in repo)
# Testbench external/iisc_sim/iisc_tb_conv.v and their RTL are compiled
# unchanged (from the ORIGINAL repo folder, read-only use).
# -MainImage ip   : mainMem initialised from the IP's own .mif (from code.coe,
#                   the file their .xci names; approved 2026-11-12)
# -MainImage xmem : mainMem.mif replaced in the simulation directory by the
#                   image of xmem.coe, the program image behind the 2019.1
#                   3,181-cycle baseline (the IP configuration is unchanged)
# Nothing in rtl/, the original repo or the 2019.1 install is modified.
param([ValidateSet('ip','xmem')][string]$MainImage = 'ip')
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
$work = Join-Path $root ("sim_build_2026\iisc_conv8_3_$MainImage")
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
& "$viv\xvlog.bat" -version

# ---- extract the 2026.1 simulation files and .mif images from the copy's .xcix
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ipdir = Join-Path $work 'ip'
$simv = @(); $simvhd = @()
foreach ($x in Get-ChildItem $ipd -Filter *.xcix) {
    $ip = $x.BaseName
    $want = @{}
    foreach ($line in Get-Content (Join-Path $lst "files_$ip.txt")) {
        $p = $line.Split("`t")
        if ($p.Count -lt 4) { continue }
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
Write-Host "2026.1 IP simulation files: $($simv.Count) Verilog, $($simvhd.Count) VHDL"
$simv + $simvhd | ForEach-Object { Write-Host "   $_" }
Get-ChildItem $work -Filter *.mif | ForEach-Object { Write-Host ("   mif {0,-22} {1} lines" -f $_.Name, (Get-Content $_.FullName | Measure-Object -Line).Lines) }

# ---- per-size parameters / reference data for the exactness check (as 2019.1)
& $py (Join-Path $root 'scripts\gen_conv_sizes.py') "8" $work
if ($LASTEXITCODE -ne 0) { throw 'gen_conv_sizes failed' }
if ($MainImage -eq 'xmem') {
    $tmp = Join-Path $work 'xmem_mif'
    & $py (Join-Path $glue 'gen_mif.py') (Join-Path $repo 'benchmarks\benchmarks\conv\conv8_3\Outputfiles') $tmp
    if ($LASTEXITCODE -ne 0) { throw 'gen_mif failed' }
    Copy-Item (Join-Path $tmp 'mainMem.mif') (Join-Path $work 'mainMem.mif') -Force
    Write-Host "mainMem.mif REPLACED by the xmem.coe image (2019.1 baseline program image)"
}

# ---- VHDL: IP models + FPU + vector unit (mypack first, exe_unit/wrapper last)
$vhdl = @($simvhd)
$vhdl += Get-ChildItem (Join-Path $rtl 'FPU\fpu') -File | Where-Object { $_.Extension -in '.vhd','.vhdl' } | ForEach-Object { $_.FullName }
$vu = Join-Path $rtl 'vector_unit'
$vhdl += 'mypack','alu','count_gen','lsu','stall_gen','dmem_addr_xbar','vrf_bank','multicycle_ops','vminmax','xoutreg','cpu_inf','exe_unit','wrapper' | ForEach-Object { Join-Path $vu "$_.vhd" }
$fv = @('-work xil_defaultlib') + ($vhdl | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' })
$fv | Set-Content -Encoding ascii (Join-Path $work 'vhdl.f')
& "$viv\xvhdl.bat" -f vhdl.f
if ($LASTEXITCODE -ne 0) { throw 'xvhdl failed' }

# ---- Verilog: IP models + stand-ins + their RTL + testbench
$vlog = @($simv)
$vlog += (Join-Path $glue 'xbip_dsp48_macro_missing.v')
$vlog += Get-ChildItem $rtl -Recurse -File -Filter *.v | Where-Object { $_.Name -notin 'defines.v','timescale.v','uart_defines.v' } | ForEach-Object { $_.FullName }
$vlog += (Join-Path $repo 'Source code\testbench\FPGA_WRAPPER.v')
$vlog += (Join-Path $glue 'iisc_tb_conv.v')
$vlog += (Join-Path $VIVADO2026_ROOT 'data\verilog\src\glbl.v')
# --relax: 2026.1 xvlog rejects their `endcase;` (stray ';' in a sequential
# block, e.g. dcache_biu.v:188) with ERROR VRFC 10-2096 by default; 2019.1 did
# not. --relax is xvlog's own option to relax strict language checks; the RTL is
# not edited.
$f = @('--relax', '-work xil_defaultlib', ('-i "' + ($rtl -replace '\\','/') + '"'), '-d itlb_def=1', '-d test_tlb=1', '-d hardware_test=0')
$f += $vlog | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' }
$f | Set-Content -Encoding ascii (Join-Path $work 'vlog.f')
& "$viv\xvlog.bat" -f vlog.f
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }

& "$viv\xelab.bat" -L xil_defaultlib -L blk_mem_gen_v8_4_13 -L div_gen_v5_1_26 -L dsp_macro_v1_0_10 -L xbip_utils_v3_0_16 -L xbip_pipe_v3_0_12 -L xbip_dsp48_wrapper_v3_0_7 -L xbip_multadd_v3_0_24 -L axi_utils_v2_0_12 -L mult_gen_v12_0_25 -L unisims_ver -L unimacro_ver -L secureip --relax xil_defaultlib.iisc_tb_conv xil_defaultlib.glbl -s iisc_conv_snap
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
& "$viv\xsim.bat" iisc_conv_snap -runall
