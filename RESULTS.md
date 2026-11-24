# ATEE-Lite — results (state of 2026-10-12)

> **Note (2026-11-23):** From 2026-11-23 the design is called Coreless-V in all publications; ATEE-Lite remains its internal name in code, file names and the records below. New entries from now on use "Coreless-V (ATEE-Lite)".

> **Note (2026-11-24, this public copy only):** local absolute paths of the author's machine are replaced by placeholders: `<VIVADO_2026_ROOT>` (Vivado 2026.1 install), `<XILINX_ROOT>` (Vivado 2019.1 install parent), `<AUTHOR_LOCAL>` (files on the author's machine that are not part of this package). Nothing else differs from the project record.

Every number below carries its source. Source labels used:

- **measured here** — produced on this machine by the named script; simulator Vivado xsim 2019.1, synthesis/implementation Vivado 2019.1.
- **spreadsheet-unverified** — read from `benchmarks/Benchmarking Results.xlsx` in the I2SRV32-V repository. Not reproduced here; their own design measured 3,181 cycles on conv8_3 on this machine.
- **paper Table III/IV, Virtex-7 XC7VX485T** — figures from the I2SRV32-V paper's own tables, entered as supplied by the project owner. The paper itself was not available on this machine, so these were not read from it here and were not reproduced. They are for a different device (Virtex-7 XC7VX485T) from every measured figure in this file.
- **projected** — arithmetic on measured parts; no full run exists.

Standing caveats:

- **Device.** All synthesis, timing and power figures are measured on Artix-7 **xc7a200tfbg676-2**, a stand-in chosen because it is the largest device installed. It is NOT the Genesys 2 target (Kintex-7 XC7K325T), for which no device support is available here.
- **DMA.** Only the 157,251-cycle figure uses the archived DMA controller. Everything else is BRAM-only, no DMA, no scalar CPU; the testbench writes the configuration registers.
- **Benchmark.** conv8_3 = 8x8x1 input, 3x3 kernel, 16 filters, 6x6x16 = 576 outputs, taken from the I2SRV32-V repository's own conv8_3 test.

## 1. Cycles — conv8_3

### 1a. Ablation chain (ours)

| Step | Cycles | Result check | DMA | Source / script |
|---|---|---|---|---|
| Original design, vl=1, everything in DMEM bank 0 | 157,251 | 576/576 | YES | measured here, `scripts/run_conv8_3_regression.ps1` (frozen copies in `archive/cpu_and_dma/`) |
| Step 5: vl=8 convoy, output-stationary, weights loaded per tap | 12,387 | 576/576 | no | measured here, `scripts/run_conv8_3_step5.ps1` |
| Step 6: weight-stationary (negative result, archived) | 13,251 | 576/576 | no | measured here, `scripts/run_conv8_3_step6.ps1` |
| Multi-MAC: weights preloaded, 3 loads + 3 MACs per convoy, wait for DONE | 4,719 | 576/576 | no | measured here, `scripts/run_conv8_3.ps1 -EarlyClear 0` (before the sequential divider) |
| + early clear (8 cycles after the last slot) | 3,387 | 576/576 | no | measured here, `scripts/run_conv8_3.ps1` (before the sequential divider) |
| + sequential output-size divider (+16 cycles per layer) — LIVE | **3,403** | 576/576 | no | measured here, `scripts/run_conv8_3.ps1` |

- 157,251 is not on the same footing as the rows below it: it includes DMA loading of DMEM from a simulated DRAM.
- All BRAM-only rows also pass 576/576 on a second data set with distinct per-filter weights (the 16 conv8_3 filters are identical).
- The sequential divider was added to meet timing (section 3); it costs exactly 16 cycles per layer.

### 1b. Other measured variants (ours, live controller, no DMA)

| Variant | Cycles | Check | Source |
|---|---|---|---|
| conv8_3 with ReLU (fused 4+4+1 convoys) | 3,619 | 576/576, incl. ReLU golden with 180 negative pre-activation outputs on the distinct-per-filter set | measured here, `run_conv8_3.ps1 -Activation 1` |
| MNIST conv1 shape, bias omitted, no ReLU (28x28, 3x3, 16 filters) | 62,283 | 10,816/10,816 | measured here, `run_conv8_3.ps1 -Workload mnist` |
| MNIST conv1 shape, bias omitted, ReLU | 66,339 | 10,816/10,816 | measured here, `-Workload mnist -Activation 1` |
| vl=16, both output-channel groups per pass, no ReLU | 2,583 | **projected** (36 x 70 + 3 x 20 + 3); isolated test only, no controller built | per-pixel 70 cycles measured here, `scripts/run_convoy_vl16.ps1` |
| vl=16, ReLU | 2,691 | **projected** (36 x 73 + 63) | per-pixel 73 cycles measured here |

MNIST caveats: bias omitted (no bias path in the controller); products kept as low 32 bits, so outputs are wrapped values, not a numerically meaningful inference; 60% of outputs are zero; the golden has no upstream reference (two independent local implementations agree).

### 1c. Comparison with I2SRV32-V

| Item | Cycles | Source | Method / caveats |
|---|---|---|---|
| ATEE-Lite, conv8_3, no ReLU | 3,403 | measured here | Layer-busy window of the hardware controller, includes weight preload; excludes loading DMEM and reading results. |
| I2SRV32-V, their design, their conv8_3 program: conv2d() entry to return | 3,181 | measured here, `scripts/run_iisc_baseline.ps1` | Behavioural xsim of their `FPGA_WRAPPER`. 226 cycles before the first OUTER_LOOP fetch + 2,955 after. err_count == 0. |
| same run: reset release to conv2d entry | 816 | measured here | boot + UART init |
| same run: reset release to main returning | 28,888 | measured here | includes the program's own 576-element check loop |
| Spreadsheet, CONV2D sheet, row "8 x 8 / 3 x 3", cell F3 (time header "Vector", 4.996 us x 50) | 250 | spreadsheet-unverified | their own design measured 3,181 on conv8_3 |
| Spreadsheet, same row, cell C3 (time header "Scalar o3 SPRAM", 622.6/16 us x 50) | 1,946 | spreadsheet-unverified | their own design measured 3,181 on conv8_3. Earlier project notes treated this as the vector figure; in the spreadsheet it is under the scalar -O3 header. |
| Spreadsheet, same row, cell E3 (scalar o0) | 13,307 | spreadsheet-unverified | — |
| Spreadsheet decode, vector: 4.996 us x 16 = 79.936 us; x 50 cycles/us | 3,996.8 (3,997) | arithmetic on a spreadsheet-unverified cell | Equals the reset release -> conv2d return measured here: 816 + 3,181 = 3,997 cycles. Reading the vector time cell as a per-filter figure (the scalar cells carry an explicit /16, the vector cell does not) is an interpretation; the sheet does not state it. |
| Spreadsheet decode, scalar -O3: 622.6 us x 50 cycles/us | 31,130 | arithmetic on a spreadsheet-unverified cell | Unverified and not reproducible here: no scalar source or image for conv8_3 in the repository. |
| Spreadsheet, CNN sheet, "Convolution with 16 filters" (vector / scalar) | 123,750 / 6,510,400 | spreadsheet-unverified | their own design measured 3,181 on conv8_3 |
| Spreadsheet, CNN sheet, "Convolution with Max-pooling 16 filters" (vector / scalar) | 56,300 / 6,560,100 | spreadsheet-unverified | same |

Caveats on the 3,181 measurement:

- The two windows are different things: theirs is a software function call on a scalar core driving the vector unit; ours is a hardware controller's busy time.
- Substitutions in their simulation: their own behavioural block-memory, divider and DSP wrappers (library versions of Vivado 2019.1 instead of 2020.2); a behavioural clock model for `clk_wiz_0`; and assumed-function stand-ins for `xbip_dsp48_macro_1/_2`, which their RTL instantiates but their repository does not ship.
- The stand-ins do not affect the count: they sit only in the instruction-TLB replacement logic, and inside the conv2d window there were 0 TLB misses, 0 replacement writes and 0 changes on any stand-in output (before the window: 1 miss, 1 replacement write).
  - *Correction note (2026-10-19):* this check is INCOMPLETE. A data TLB IS instantiated (`tlb dtlb` at `dcache_dpram.v:401`; its `d_replacement_algo` at `tlb.v:371` contains `EVA_update` and therefore the same stand-ins). Only the instruction TLB was probed. Whether the data-TLB replacement logic is active inside the conv2d window has NOT been measured, so "the stand-ins do not affect the count" is not established. The 3,181-cycle figure itself is unchanged.
  - *Note (2026-10-19, later the same day):* the data TLB has now been probed and a sensitivity test run; the 3,181-cycle count does NOT change between two different stand-in functions. See "Data-TLB stand-in probe (2026-10-19)".
- Why 3,181 differs from both spreadsheet figures has not been determined. The spreadsheet's scalar time cells are divided by 16 in their formulas; the meaning of that division is not stated there.
- Their scalar version was not run: the repository has no scalar source or image for conv8_3 and no RISC-V toolchain is installed here.

## 2. Area — post-route, Artix-7 xc7a200tfbg676-2 (stand-in)

Source for all rows: measured here, Vivado 2019.1 non-project flow, no timing exceptions, clock-only constraint.

| | Dividers present (default build) | Dividers removed (`ENABLE_DIV=0`) | Dividers removed + sequential output-size divider |
|---|---|---|---|
| Script | `scripts/synth_atee.tcl` | `scripts/synth_atee_nodiv.tcl` | `scripts/synth_atee_nodiv.tcl` (after the controller change) |
| Slice LUTs (of 133,800) | 64351 | 25108 | 25096 |
| Slice registers (of 267,600) | 18707 | 15169 | 15193 |
| Slices (of 33,450) | 21866 | 10056 | 10123 |
| Block RAM tiles (of 365) | 128 | 128 | 128 |
| DSP48E1 (of 740) | 61 | 63 | 63 |
| `u_config` LUTs / FFs | 980 / 577 | 981 / 621 | 413 / 577 |
| `u_hbm_lite` (controller) LUTs / FFs / DSP | 661 / 246 / 18 | 654 / 261 / 18 | 825 / 330 / 18 |
| `u_vec_unit` (inherited vector unit + DMEM) LUTs / FFs / DSP | 39158 / 17884 / 43 | 23461 / 14287 / 45 | 23881 / 14286 / 45 |
| LUTs owned by the top level | 23581 | 38 | — |

- "Dividers" are this project's behavioural replacement (`div_gen_behav.vhd`) of the Xilinx divider IP in the inherited core: 16 instances, one combinational 32-bit divide each. 23,544 of the 23,581 top-level LUTs in the default build are that divider logic, left at the top level by synthesis.
- With `ENABLE_DIV=0` a divide instruction issued from the interface pins writes zero; the controller never issues one. All six workloads are bit-exact with unchanged cycle counts in that build.

### I2SRV32-V, the paper's own area figures (different device)

| Block | LUT | FF | BRAM | DSP | Source |
|---|---|---|---|---|---|
| Vector pipeline | 35,737 | 19,896 | 32 | 43 | paper Table III/IV, Virtex-7 XC7VX485T |
| Scalar pipeline | 41,996 | 22,032 | 27 | 24 | paper Table III/IV, Virtex-7 XC7VX485T |
| Memory + peripherals | 1,201 | 470 | 256 | 0 | paper Table III/IV, Virtex-7 XC7VX485T |

Not measured here; a different device family from the stand-in used for every measured row in this file.

### I2SRV32-V compute blocks, out-of-context, same stand-in device (measured here, 2026-10-12/13)

Their RTL, unmodified, `-mode out_of_context`, xc7a200tfbg676-2, clock only (clk 20 ns; clk_x2 10 ns where present), no mainMem, no UART/peripherals. Script `scripts/synth_iisc_ooc.tcl vector|scalar|both`; reports in `synth_build/iisc_ooc_*`. IP regenerated in Vivado 2019.1 from their `.xci` parameters (0 parameters differing for every IP used). In the scalar core, `xbip_dsp48_macro_1/_2` (ITLB replacement logic) are OUR hand-written assumed-function stand-ins, because their repository does not ship them.

| Run | Stage | LUTs | Registers | Block RAM tiles | DSP | WNS (clk, 20 ns) | Derived max frequency | Worst path |
|---|---|---|---|---|---|---|---|---|
| Vector unit alone (`vector_top`, incl. 8 DMEM banks and their div_gen IP) | post-synthesis | 44355 | 39665 | 116 | 48 | -17.803 ns (estimate) | — | inside their signed divider IP |
| Vector unit alone | **post-route** (67,774 of 67,774 nets routed) | 43625 | 22455 | 116 | 48 | -22.609 ns, 11040 of 45895 endpoints failing | 1000/42.609 = 23.47 MHz | inside their signed divider IP `GEN_DIVIDERs[3]` (42.594 ns, 161 levels, 144 CARRY4) |
| Scalar core alone (`cpu`, vector unit as a black box) | post-synthesis ONLY | 43783 | 22291 (20458 FF + 1833 latches) | 35.5 | 32 | -95.963 ns (estimate), 2326 of 36824 endpoints failing | — | `Mult_Div_unit__Stall__reg` to `FP__RD_Data_Int__EX_MEM_reg[0]` (115.918 ns, 437 levels, 367 CARRY4) |
| Scalar + vector together (`cpu`, real vector unit, added run) | post-synthesis | 88748 | 61932 | 151.5 | 80 | -97.405 ns (estimate) | — | — |
| Scalar + vector together | **post-route** (129,224 of 129,224 nets routed) | 86235 | 43955 (42122 FF + 1833 latches) | 143 | 80 | -124.828 ns, 37329 of 80769 endpoints failing | 1000/144.828 = 6.90 MHz | DMEM0 block RAM in the vector unit to `FP_EX/OUTPUT__reg_reg[5]` (144.669 ns, 497 levels, 386 CARRY4) |
| of which `VECTOR_UNIT` (hierarchy row of the post-route report) | post-route | 46767 | 22194 | 116 | 48 | | | |
| of which everything else = scalar core (total minus the row above) | post-route | 39468 | 21761 | 27 | 32 | | | |

*Correction note (2026-10-19) on the "Scalar + vector together" row: the −124.828 ns / 6.90 MHz timing was measured WITHOUT their timing exceptions; see "IISc timing with their own exceptions". Also, the stand-ins `xbip_dsp48_macro_1/_2` are in BOTH the instruction TLB and the data TLB (`fdem/db1/dt1/dd/dtlb`), not only the ITLB as stated above.*

- **Scalar core alone has no implementation result.** `opt_design` refuses a design containing a black box (`DRC INBB-3`), so the scalar-alone numbers are post-synthesis and its WNS is a synthesis estimate. The combined run was added to obtain routed numbers; its scalar row is a subtraction, not a separate run.
- clk_x2 (10 ns) domain meets timing in every run (post-route combined: +0.725 ns; clk to clk_x2 +0.298 ns). Hold is met in every run.
- Their divider IP (`div_gen_0/1`) is configured Radix2, 32-bit, clocks_per_division 1, latency set manually to 4.
- Registers drop between synthesis and route in the vector unit (39665 to 22455) because `opt_design` removes logic; no source was changed. In the combined run `opt_design` also reduced the branch predictor (`BPU`) to 1 LUT and removed its block RAMs (151.5 to 143 tiles). The combined run's 786 critical warnings at synthesis are from their RTL (tristate cells converted to logic, unconnected `vcsr_quant` pins).
- Whether any of the failing paths is intended by its authors to take several clock cycles is not known here; no multicycle or false-path exception was applied, as for our own design.
- These are out-of-context results: block ports are not constrained and are not placed on pins.
### I2SRV32-V, whole design (FPGA_WRAPPER) on the same device — not obtained

| Item | Value | Source |
|---|---|---|
| Synthesis of their `FPGA_WRAPPER` on xc7a200tfbg676-2 | FAILED: `ERROR: [Synth 8-5833] Design has more instantiated block-RAMs than device capacity` | measured here, `scripts/synth_iisc.tcl`, `synth_build/vivado_iisc.log` |
| Block RAM cells synthesized | 402 RAMB36E1 + 11 RAMB18E1 (device: 365 tiles) | same log, Report Cell Usage |
| LUT1–6 cells / flip-flops / latches / DSP48E1 | 100,238 / 60,498 / 1,833 / 80 | same log, Report Cell Usage |

- These are raw cell counts printed by a failed synthesis run, not a utilization report. They are whole-design totals (scalar core + vector unit + 1 MB main memory + caches + UART); no per-block split exists, and they are not comparable with the post-route figures above.
- Their IP was regenerated in Vivado 2019.1 from the parameters in their `.xci` files (19 of 19 created; generics identical to their shipped wrappers except the device family). `xbip_dsp48_macro_1/_2` are not shipped and were replaced by hand-written, assumed-function stand-ins for this run.
- `mainMem` (262,144 x 32) alone is 256 RAMB36. No larger device is installed here.
- Stack check before any reduced-memory variant (none built): the program is linked with `arch/riscv.ld`, `__stacktop` = 0x000FEFFC (word 261,119 of 262,144). Measured on the `mainMem` port over the whole run: 497 enabled cycles, 0 writes, highest address accessed 0x000FFFFC, 24 reads at 0x000FFFA0-0x000FFFFC, highest address below 0x40000 is 0x000210FC.

## 3. Timing — 50 MHz target (20.000 ns), post-route, Artix-7 xc7a200tfbg676-2 (stand-in)

Source: measured here, same runs as section 2. Maximum frequency is derived as 1000 / (20 − WNS).

| Build | Constraint | WNS | Failing endpoints | Derived max frequency | Worst path |
|---|---|---|---|---|---|
| Dividers present | clock only | −63.044 ns | 17907 of 41167 | 12.04 MHz | behavioural divider (83.025 ns, 333 logic levels) |
| Dividers present | clock + 5 ns I/O delays | −62.342 ns | 24938 of 60412 | 12.14 MHz | same divider |
| Dividers removed | clock only | −11.346 ns | 726 of 29675 | 31.90 MHz | controller's combinational `/ stride` (31.099 ns) |
| Dividers removed | clock + 5 ns I/O delays | −11.519 ns | 5165 of 46366 | 31.73 MHz | same |
| Dividers removed + sequential output-size divider | clock only | **+0.251 ns (met)** | 0 of 29868 | 50.64 MHz | inside the inherited vector unit (19.466 ns, 27 levels incl. 2 DSP48E1) |
| Dividers removed + sequential output-size divider | clock + 5 ns I/O delays | −3.453 ns | 327 of 46499 | — | port-to-port path through the vector unit (`vl[2]` to `XRF_DATAWR[5]`) |

- Hold is met in every run.
- The 5 ns I/O delays are a first-pass assumption (25% of the period) with no board-level basis; the failing paths in the last row are on the scalar-core interface ports and in the inherited `exe_unit`, none in the controller.
- The +0.251 ns margin is on a stand-in device with only the clock constrained; it is not a board-level result.
- I2SRV32-V on the same device: no timing result (synthesis failed, section 2).

## 4. Power — Artix-7 xc7a200tfbg676-2 (stand-in), 50 MHz

| Build | Method | Total | Dynamic | Static | Tool confidence | Source |
|---|---|---|---|---|---|---|
| Dividers present | vectorless estimate, post-route | 1.057 W | 0.918 W | 0.139 W | Low | measured here, `synth_atee.tcl` |
| Dividers removed | vectorless estimate, post-route | 0.598 W | 0.460 W | 0.138 W | Low | measured here, `synth_atee_nodiv.tcl` |
| Dividers removed + sequential divider | vectorless estimate, post-route | 0.614 W | 0.476 W | 0.138 W | Low | measured here |
| Dividers removed + sequential divider | **SAIF from post-implementation functional simulation of conv8_3, layer-busy window (3,403 cycles)** | **0.379 W** | 0.242 W | 0.137 W | High | measured here, `scripts/run_power_saif.ps1`, `scripts/power_report_saif.tcl` |
| I2SRV32-V vector processor | as published; method not stated in the figures supplied | 597 mW | 333 mW | 264 mW | — | paper Table III/IV, Virtex-7 XC7VX485T |
| I2SRV32-V scalar processor | same | 496 mW | 235 mW | 261 mW | — | paper Table III/IV, Virtex-7 XC7VX485T |
| I2SRV32-V, "PowerV" | cell value 597, no unit, method or device stated in the sheet (same value as the paper's vector total) | — | — | — | — | spreadsheet-unverified |
| I2SRV32-V, "PowerS" | cell value 496, same (same value as the paper's scalar total) | — | — | — | — | spreadsheet-unverified |

SAIF run details: routed netlist, unisim models, no timing annotation (glitch activity not captured); nets and ports of the 59 design module scopes were logged; Vivado matched 25,597 of 52,376 design nets (49%) and propagated the rest. Dynamic power by hierarchy: `u_vec_unit` 0.237 W, `u_hbm_lite` 0.003 W, `u_config` 0.001 W. By type: block RAM 0.128 W, signals 0.052 W, clocks 0.033 W, slice logic 0.029 W.

*Correction note (2026-11-12):* "the 59 design module scopes" above is wrong as a description of what was logged. 40 of the 59 scope names did not resolve, so only 19 scopes' design nets were logged. The figures are unchanged. See "vl=16 power, full chip, SAIF (2026-11-12)", "SAIF scope coverage". The vl=16 power figures are in that section.

I2SRV32-V on the same device and method: no power result (synthesis failed, section 2).

## 5. Energy — conv8_3, no ReLU

Ours: SAIF-based power of section 4 x layer-busy time. T = 3,403 cycles x 20 ns = 68.06 µs. Source: measured here (power to 3 decimals as reported by the tool).

| Quantity | Total power basis (0.379 W) | Dynamic only (0.242 W) |
|---|---|---|
| Whole layer | 25.795 µJ | 16.471 µJ |
| Per output value (576) | 44.78 nJ | 28.59 nJ |
| Per output spatial position (36) | 716.5 nJ | 457.5 nJ |
| Per MAC (5,184) | 4.976 nJ | 3.177 nJ |

Excludes loading DMEM and reading results back. Stand-in device.

| I2SRV32-V figure | Value | Source |
|---|---|---|
| CONV2D sheet, "Energy (nJ/pixel)" vector, formula `G6*597/(62*62)` (the 64 x 64 row) | 55.134 | spreadsheet-unverified; their own design measured 3,181 cycles on conv8_3 |
| CONV2D sheet, "Energy (nJ/pixel)" scalar | 764.897 | spreadsheet-unverified; same |
| Their design, conv2d window, same device and method as ours | not obtained | synthesis failed (section 2) |

The spreadsheet's "pixel" is one of 62 x 62 output positions of a 64 x 64 image; it is a different image size and a different power basis from the rows above.

## 6. Documented hazards of the inherited core

Neither is fixed in RTL; both are handled by scheduling rules in `hbm_lite_controller.v`.

| # | Hazard | Where | Effect | Evidence | Rule in use |
|---|---|---|---|---|---|
| 1 | Load-use stall path | `exe_unit.vhd` (STALLER, stall branch of the chaining logic) | A load in slot i−1 whose destination is read by slot i: `stall` toggles every other cycle for the whole convoy and element 0 of the consumer uses a stale operand | Failure measured here (`convoy_tb`, tests V1/V1b). Root cause is an RTL reading, not separately proven | Never place a load in the slot directly ahead of an instruction that reads its destination |
| 2 | Slot-7 store | `dmem_addr_xbar.vhd`: each of the eight per-bank processes ends in an unconditional `else` that hands the bank to slot 7 | A store in slot 7 is written into every bank not claimed by slots 0..6 | Structural, from the RTL; measured instance here (`convoy_multi_tb` L3M3S: 4 of 8 stored elements overwritten) | Never place a store in slot 7. Stores in slots 0..6 are safe |
| 3 | Read enable not gated by DONE (related) | same file | A broadcast (strided, stride 0) load holds one bank and collides with unit-stride accesses | Measured here (`convoy_tb` V3a–d) | No broadcast loads; each input pixel is replicated across the 8 banks and loaded unit-stride |
| 4 | vl > 8 with an empty slot | `vrf_bank.vhd` takes the register offset from each slot's own counter | Elements 8..15 land in the wrong register for the banks of empty slots | Measured here (`convoy_vl16_tb`: 6/8 per pass with empty slots) | Applies to the vl=16 design point only: every slot must hold a running no-op |
| 5 | Element counter wrap | `count_gen.vhd`, 7-bit counter | A slot held with `start` for 128 cycles re-runs its instruction | RTL reading | Always clear or overwrite a slot once done |

Also changed in the inherited core: `count_gen.vhd` `>=` → `>` so that vl = N runs N elements (it ran N−1 before).

## 7. Limits of the live design

- Taps per layer (input channels x kernel height x kernel width) ≤ 16: all tap weights are held in vector registers v16..v31. Layers beyond that (3x3 with 2 input channels, 5x5) are not supported; no chunked-preload scheme has been designed or tested.
- Output channels must be a multiple of 8; each input pixel is stored 8 times.
- No bias path.
- Strides other than 1 are verified only at module level (`outsize_div_tb`: 962,544 operations, 0 mismatches), not through a full layer.

## Out-of-context synthesis (method consistency)

Added 2026-10-19. Purpose: section 2 sets our FULL-CHIP build beside the I2SRV32-V OUT-OF-CONTEXT runs; this section runs our blocks out of context too. No number elsewhere in this file was changed.

- Script: `scripts/synth_atee_ooc.tcl -tclargs <top>` (new; derived from `scripts/synth_atee_nodiv.tcl`, which is unchanged). Logs `synth_build/vivado_atee_ooc_<top>.log`, reports `synth_build/atee_ooc_<top>/`.
- Tool: Vivado v2019.1 (64-bit), build 2552052. Part: **xc7a200tfbg676-2** (Artix-7 stand-in, NOT the Genesys 2 Kintex-7 XC7K325T).
- Method: `synth_design -mode out_of_context`, then opt / place / phys_opt / route. Clock constraint only (`clk` 20.000 ns), no exceptions, no tuning. Generics as in the final build: `ENABLE_DIV=0` on `atee_top` and `v_wrapper`; all other parameters at their RTL defaults (`EARLY_CLEAR=1`; sequential output-size divider present). Sources: the 20 files of `rtl/vector_unit/` used by the final build, none from `archive/`, DMA, CPU or the IISc repository.
- Run 3 (controller + configuration registers) is not one module: `hbm_lite_controller` (which contains `outsize_div`) and `tensor_config_regs` were synthesized separately and summed.
- Max frequency is derived as 1000 / (20 − WNS). Every row: 0 failing setup endpoints, hold met, all nets routed with 0 errors.

| Top | Stage | LUTs | FFs | BRAM tiles | DSP | WNS | Derived max frequency | Source |
|---|---|---|---|---|---|---|---|---|
| `atee_top` (config regs + controller + vector unit + 8 DMEM banks) | post-synthesis | 25109 | 15193 | 128 | 63 | +2.103 ns | 1000/17.897 = 55.87 MHz | measured here, 2019.1 |
| `atee_top` | **post-route** (39,271 nets routed) | 25095 | 15193 | 128 | 63 | +0.641 ns | 1000/19.359 = 51.66 MHz | measured here, 2019.1 |
| `v_wrapper` (vector unit + 8 DMEM banks) | post-synthesis | 24170 | 14289 | 128 | 45 | +2.961 ns | 1000/17.039 = 58.69 MHz | measured here, 2019.1 |
| `v_wrapper` | **post-route** (36,490 nets routed) | 24160 | 14289 | 128 | 45 | +0.379 ns | 1000/19.621 = 50.97 MHz | measured here, 2019.1 |
| `hbm_lite_controller` (incl. `outsize_div`) | post-synthesis | 694 | 330 | 0 | 18 | +2.361 ns | 1000/17.639 = 56.69 MHz | measured here, 2019.1 |
| `hbm_lite_controller` | post-route (1,677 nets routed) | 688 | 330 | 0 | 18 | +2.191 ns | 1000/17.809 = 56.15 MHz | measured here, 2019.1 |
| `tensor_config_regs` | post-synthesis | 221 | 578 | 0 | 0 | +17.498 ns | 1000/2.502 = 399.68 MHz | measured here, 2019.1 |
| `tensor_config_regs` | post-route (682 nets routed) | 221 | 578 | 0 | 0 | +17.800 ns | 1000/2.200 = 454.55 MHz | measured here, 2019.1 |
| Controller + config regs, SUM of the two runs above | post-synthesis | 915 | 908 | 0 | 18 | — | — | arithmetic on the two runs |
| Controller + config regs, SUM | post-route | 909 | 908 | 0 | 18 | — | — | arithmetic on the two runs |

- The 454.55 / 399.68 MHz figures for `tensor_config_regs` are what the formula gives for its slack; they are above what the device's clocking supports and only say that the block is far from limiting.
- Worst post-route paths: `atee_top` from `u_vec_unit/.../EXE_MEM_v0_DATA_reg[1][6]` to `X_REGS/Xoutreg_reg[2][31]` (19.225 ns, 28 levels); `v_wrapper` from `EXE_MEM_v0_DATA_reg[1][22]` to `EXE_MEM_ALU_y_reg[3][21]` (19.578 ns, 26 levels); `hbm_lite_controller` from `comb_input_addr4` to `vec_RS1_reg[27]` (17.767 ns, 17 levels).
- Hierarchy of the out-of-context `atee_top` post-route: `u_config` 412 LUT / 577 FF; `u_hbm_lite` 826 / 330 / 18 DSP; `u_vec_unit` 23880 / 14286 / 128 BRAM / 45 DSP; top level 10 LUT. The standalone `tensor_config_regs` (221 LUT) and the `u_config` row inside `atee_top` (412 LUT) differ because synthesis optimizes across the block boundary differently when the block is not standalone.

Side by side (all xc7a200tfbg676-2, Vivado 2019.1, clock only):

| Design | Method | Stage | LUTs | FFs | BRAM tiles | DSP | Timing at 20 ns | Source |
|---|---|---|---|---|---|---|---|---|
| ATEE-Lite `atee_top` | full chip (I/O buffers, ports on pins) | post-route | 25,096 | 15,193 | 128 | 63 | met, +0.251 ns, 50.64 MHz | section 2/3 of this file, measured here |
| ATEE-Lite `atee_top` | out of context | post-route | 25,095 | 15,193 | 128 | 63 | met, +0.641 ns, 51.66 MHz | this section, measured here |
| ATEE-Lite `v_wrapper` | out of context | post-route | 24,160 | 14,289 | 128 | 45 | met, +0.379 ns, 50.97 MHz | this section, measured here |
| I2SRV32-V `cpu` + vector unit | out of context | post-route | 86,235 | 43,955 | 143 | 80 | −124.828 ns, 6.90 MHz | section 2 of this file, measured here |
| I2SRV32-V `vector_top` alone | out of context | post-route | 43,625 | 22,455 | 116 | 48 | −22.609 ns, 23.47 MHz | section 2 of this file, measured here |

*Correction note (2026-10-19) on the "I2SRV32-V `cpu` + vector unit" row: −124.828 ns / 6.90 MHz was measured WITHOUT any timing exception. Their own exceptions could not be applied to this out-of-context scope as written; see "IISc timing with their own exceptions". The figure stands as recorded, but it is not their frequency with their constraints.*

Caveats: the I2SRV32-V scalar core uses our assumed-function stand-ins for `xbip_dsp48_macro_1/_2`; ATEE-Lite's vector unit is built with `ENABLE_DIV=0` (no vector divider), while the I2SRV32-V vector unit contains its 16 `div_gen` instances; the I2SRV32-V `vector_top` also contains its instruction decode and scalar-interface logic.

## Vivado 2026.1 evaluation

Not started (checked 2026-10-19): Vivado 2026.1 is not installed on this machine. The only Vivado install on any drive and in the Windows uninstall registry is "Xilinx Design Tools Vivado HL Design Edition 2019.1" at `<XILINX_ROOT>`; `vivado` is not on PATH. No 2026.1 number exists in this file.

### Gate test (2026-11-12) — STOPPED AT (b)

- **Install:** Vivado 2026.1 at `<VIVADO_2026_ROOT>`. The tool reports: "A valid Vivado Design Suite BASIC license has been detected … will expire on 12-nov-2027."
- **Untouched:** the 2019.1 install, the RTL, the existing scripts and testbenches, and `external/I2SRV32-V-v1-master`. The newest file in its IP folder is still dated 22 June 2024.
- **New scripts:** `scripts/v2026_gate_a.tcl` and `scripts/v2026_gate_b.tcl`. Logs are in `synth_build_2026/gate_a/` and `synth_build_2026/gate_b/`.

**(a) Parts and licence: PASS.**

| Part | `get_parts` | Trivial synth_design (8-bit counter) |
|---|---|---|
| xc7vx485tffg1761-2 (IISc's VC707 part) | FOUND, family virtex7 | OK: "Got license for feature 'Vivado_Synthesis' and/or device 'xc7vx485t'", 0 errors, 8 FDRE |
| xc7k325tffg900-2 (Genesys 2 part) | FOUND, family kintex7 | OK: same message for 'xc7k325t', 0 errors, 8 FDRE |

Only synthesis was licence-checked. Implementation and simulation licensing on these parts has not been exercised.

**(b) Their ORIGINAL 2020.2 IP in 2026.1: FAIL (9 of 19 IPs).**

- **Setup:**
  - Their repo has no Vivado project (`.xpr`), only RTL, 19 `.xcix` containers and `constraints.xdc`.
  - `Source code/` was copied to `external_2026/iisc_copy/`: 144 files, 207,146,908 B, all 19 `.xcix` hash-identical to the originals.
  - A NEW 2026.1 project was created there (`proj_2026`, part xc7vx485tffg1761-2) and the 19 original `.xcix` were added.
  - `report_ip_status` before and after, then `upgrade_ip` + `generate_target all` per IP.
  - Their RTL and our `xbip_dsp48_macro_1/_2` stand-ins (copied in) were added to the project. They were not synthesized.
- **Before:** all 19 were locked: "customized with software release 2020.2 … has a different revision in the IP Catalog".

| IP | Upgrade | Result |
|---|---|---|
| BTB_mem, PHT_mem, dcache, tag_ram (blk_mem_gen 8.4 rev 4 → 13) | success, with warnings | upgraded and generated. The upgrade adds output ports `rsta_busy`, `rstb_busy`. |
| blk_mem_gen_v7_3, blk_mem_gen_v7_3_2 (same) | success (with warnings for `_v7_3`, which adds `rsta_busy`) | upgraded and generated |
| clk_wiz_0 (clk_wiz 6.0 rev 6 → 19) | success, with warnings | upgraded and generated. "attempt to modify the value of disabled parameter 'CLKOUT3_REQUESTED_OUT_FREQ' … has been ignored". This is the same unused output that differed in the 2019.1 regeneration (§"IISc design on the same stand-in device"). |
| div_gen_0, div_gen_1 (div_gen 5.1 rev 17) | clean | upgraded and generated |
| xbip_dsp48_macro_0 | replaced: "xbip_dsp48_macro (3.0) … has been replaced in the IP Catalog by 'DSP Macro (1.0)'" | upgraded to `dsp_macro:1.0` and generated; log notes "Added parameter c_square_fcn with value false". That the generated module keeps the name `xbip_dsp48_macro_0` was NOT checked. |
| **DMEM_0 … DMEM_7** | **FAILED** | "Unable to open file: ../../../../python_scripts/dmem_bank*N*.coe" → "Validation failed for parameter 'Coe File(Coe_File)' … No COE file loaded" → "'upgrade_ip' failed due to earlier errors" |
| **mainMem** | **FAILED** | same, "Unable to open file: ../../../../code.coe" |

- **Cause of the 9 failures:** the original `.xci` reference memory-initialisation files by paths relative to the authors' machine (`python_scripts/dmem_bank0..7.coe`, `code.coe`). No `python_scripts` folder exists anywhere in their repo. Every benchmark ships its own set instead, e.g. `benchmarks/benchmarks/conv/conv8_3/Outputfiles/code.coe` and `dmem_bank0..7.coe`. So the failure is a missing input file, not a tool or device incompatibility. Which benchmark's COE set the authors had in `python_scripts/` when they built the IP is not recorded.
- **(c) not run** (gated on (b)). No 2026.1 simulation, synthesis or implementation of either design exists. The Virtex-7 plan stays NOT STARTED.

### Gate test re-run (2026-11-12/13) — (b) PASS with conv8_3 init files, checks 1–3 PASS, (c) PASS on the baseline program image

Approved by the user on 2026-11-12. In the COPY only, the 9 IPs above were pointed at conv8_3's own init files. Their `python_scripts/` folder is not in the repo.

- **New scripts:** `scripts/v2026_gate_b2.tcl` (upgrade, init files, IP synthesis, elaboration), `scripts/v2026_compare_ip_params.py` (check 1), `scripts/v2026_check3_elab.tcl` (check 3 netlist query) and `scripts/run_iisc_conv8_3_2026.ps1` (step c). Logs are in `synth_build_2026/gate_b2/` and `sim_build_2026/`.
- **Note on the first (b) run:** `upgrade_ip` writes back into the `.xcix` containers, so the first run had changed all 19 copied `.xcix` files. Before every re-run, the copy was restored from the originals (hash check: 0 of 19 differ). The original repo is still untouched.
- **Init files:**
  - `code.coe` and `dmem_bank0..7.coe` from `benchmarks/benchmarks/conv/conv8_3/Outputfiles` were copied (hash-identical) to `external_2026/iisc_copy/conv8_3_coe/`.
  - `upgrade_ip` still returns an error for these 9 IPs, after a partial upgrade. Its log says "CAUTION (success, with warnings)" and "Load Init File … Restoring to an old valid value of 'false'".
  - The script then set `Load_Init_File = true` and `Coe_File = ../../../conv8_3_coe/<file>`.
  - The saved `.xci` inside each `.xcix` records that path. The generated `.mif` equals the COE word for word: DMEM_0 166/166, DMEM_7 165/165, mainMem 82,881/82,881.
  - The project file still lists the original COE paths as stale file entries, which gives 9 "Could not find the file" critical warnings when the project is reopened. They have no effect on the IP.

**(b) re-run: PASS.** `GB2 SUMMARY ok=19 fail=0`. All 19 IPs were upgraded and generated, and then synthesized out of context ("synth_design Complete!", 19 of 19). That is synthesis only.

**Check 1: key parameters, copy vs original `.xci`: PASS, with the differences below.** Both the user parameters and the model parameters (the `C_*` generics of each generated sim wrapper) were compared against the original 2020.2 `.xci`.

| IP(s) | Parameter | Original | 2026.1 copy | Cause / effect |
|---|---|---|---|---|
| DMEM_0..7, mainMem | Coe_File | `../../../../python_scripts/dmem_bankN.coe`, `../../../../code.coe` | `../../../conv8_3_coe/<same name>` | the approved change |
| BTB_mem, PHT_mem, dcache, tag_ram, mainMem, blk_mem_gen_v7_3 | EN_SAFETY_CKT / C_EN_SAFETY_CKT | false / 0 | true / 1 | Set by the upgrade: the value was a default in 2020.2, and 2026.1's default with reset pins is true. It adds the `rsta_busy`/`rstb_busy` outputs, which their RTL leaves unconnected. All 6 have their reset pins tied to system reset (`rst`/`RST`/`rst_n`). blk_mem_gen_v7_3_2 already had it set to true. |
| clk_wiz_0 | CLKOUT3_REQUESTED_OUT_FREQ | 200.000 | 100.000 | an output marked unused; the same difference as in the 2019.1 regeneration |

- **Unchanged on all 19 IPs:** every other user parameter. That includes depth, width, read latency, memory type, operating mode, port enables, reset pins and pipeline stages.
- **blk_mem_gen:** all 75 `C_*` model parameters equal except `C_EN_SAFETY_CKT`.
- **div_gen_0/1:** all 17 `C_*` equal.
- **xbip_dsp48_macro_0 (now dsp_macro 1.0):** all 51 `C_*` of the original are present with equal values.
- **clk_wiz_0:** its wrapper carries no `C_*`, so the MMCME2_ADV attributes of the 2026.1 RTL were compared with the 2020.2 netlist instead. CLKIN1_PERIOD 5.0 (200 MHz in), CLKFBOUT_MULT_F 5, DIVCLK_DIVIDE 1, CLKOUT0_DIVIDE_F 20 (50 MHz core clock), CLKOUT1_DIVIDE 10 (100 MHz clk_x2), BANDWIDTH OPTIMIZED and COMPENSATION ZHOLD are all equal. The unused CLKOUT2..6 and REF_JITTER1 are no longer written out, so the primitive defaults apply, and those equal the 2020.2 values.

**Check 2: xbip_dsp48_macro_0 → dsp_macro 1.0: PASS.** The generated module is still named `xbip_dsp48_macro_0`, with ports `CLK`, `A[17:0]`, `B[17:0]`, `P[35:0]` (from the `.veo` and the sim wrapper; internally it is `dsp_macro_v1_0_10`). That is the same as the 2020.2 netlist and as the 8 instances in their RTL: `EVA_update.v:1100-1109`, `in1..in5` 18 bit, `op1..op4` 36 bit.

**Check 3: RTL elaboration of FPGA_WRAPPER, 2026.1, xc7vx485tffg1761-2: PASS.**
- `synth_design -rtl` completed with 0 errors, 0 critical warnings and 0 "module not found". The defines are those of their simulation: itlb_def=1, test_tlb=1, hardware_test=0.
- The netlist query found 0 cells with IS_BLACKBOX. Every IP and stand-in instance resolved: mainMem 1, DMEM_0..7 1 each, dcache 4, tag_ram 2, BTB_mem 4, PHT_mem 1, blk_mem_gen_v7_3 2, blk_mem_gen_v7_3_2 2, clk_wiz_0 1, div_gen_0 8, div_gen_1 8, xbip_dsp48_macro_0 8, xbip_dsp48_macro_1 4, xbip_dsp48_macro_2 4.
- The IPs resolve through their out-of-context stubs. xbip_dsp48_macro_1/_2 are OUR assumed-function stand-ins, as before.
- The first elaboration log hit Vivado's 100-message limit, so the result was re-checked with `v2026_check3_elab.tcl`.

**(c) conv8_3 in 2026.1 xsim**

- **Build:**
  - Every IP simulation model comes from the 2026.1 copy, against 2026.1's precompiled libraries: blk_mem_gen_v8_4_13, div_gen_v5_1_26 and dsp_macro_v1_0_10.
  - clk_wiz_0 is the IP's own MMCM model, not our behavioural clock.
  - Their RTL, `FPGA_WRAPPER.v` and our testbench `external/iisc_sim/iisc_tb_conv.v` are compiled unchanged.
  - One tool option was needed: xvlog `--relax`. Without it, 2026.1 rejects their `endcase;` (`dcache_biu.v:188`) with "ERROR: [VRFC 10-2096] empty statement in sequential block", which 2019.1 accepted. With `--relax` it becomes a warning (39 occurrences). No RTL was edited.
- **BASIC licence:** no licence, feature or capacity message appears in the compile, elaboration or simulation logs. Nothing was limited.

| mainMem image | conv2d entry → return | reset → conv2d entry | reset → main returns | err_count | Exact outputs |
|---|---|---|---|---|---|
| `xmem.coe` (the image of the 2019.1 baseline; the IP's `mainMem.mif` replaced in the sim directory, IP configuration unchanged) | **3,181 cycles** (226 entry → OUTER_LOOP) | 816 | 28,888 | **0** (1 write, value 0) | **576/576** vs their expected_output and vs the Python reference (read latency calibrated L=1, 576/576 expected_output reads reproduce the file) |
| `code.coe` (the file their `.xci` names; the IP's own `.mif`) | NOT REACHED | NOT REACHED | — | — | — |

- **The `xmem.coe` run** reproduces the 2019.1 baseline exactly, number for number, including the ITLB/DTLB probe counts.
- **The `code.coe` run:** the core never fetched conv2d (0x9d0). The heartbeat showed `pc = 00001188` at cycles 500,000, 1,000,000 and 1,500,000. The run was stopped by hand after 52 minutes of wall-clock time.
  - `code.coe` is a DIFFERENT build of the program from `xmem.coe`: 82,881 words against 262,144, with 13,852 of the shared words different.
  - Its stack set-up is `auipc sp,0x3f` (stack near 0x3FFFC, the `link.ld` layout), against `auipc sp,0xff` in `xmem.coe` (0xFEFFC, `riscv.ld`, the shipped `riscv-spike.dump`).
  - It also holds non-zero words at 0x41000–0x4D824, which `xmem.coe` does not.
  - Both images are identical at 0x1188 (`0x0f40006f`).
  - Why the `code.coe` build does not reach conv2d has NOT been determined. It has not been run in 2019.1 either, so it is not established whether 2026.1 plays any part. The `xmem.coe` result shows that 2026.1 with the upgraded IP reproduces the baseline.
- **Not done:** any Virtex-7 or Kintex-7 implementation. Only out-of-context IP synthesis and RTL elaboration were run on xc7vx485tffg1761-2.

## Virtex-7 XC7VX485T, Vivado 2026.1

Measured 2026-11-13, Vivado 2026.1 (BASIC licence), part **xc7vx485tffg1761-2**: IISc's own VC707 part, NOT the Genesys 2 Kintex-7 target.
- **Run conditions:** each run was launched detached, one at a time, on mains power, with default synthesis and implementation directives.
- **Checkpoints:** written after every stage (synth, opt, place, phys_opt, route) to `synth_build_2026/v7_xc7vx485t/<run>/post_<stage>.dcp`, with `stage.txt` timestamps.
- **New scripts:** `scripts/v7_impl_atee.tcl` (vl16 | vl8), `scripts/v7_impl_iisc.tcl`, `scripts/launch_vivado2026_detached.ps1`, `scripts/v7_summarize.py`, and `scripts/v7_iisc_analyze.tcl` (read-only analysis). Logs are in `synth_build_2026/v7_xc7vx485t/logs/`.
- **Licence:** every implementation stage of every run logged "Got license for feature 'Vivado_Implementation' and/or device 'xc7vx485t'", and synthesis logged the same for 'Vivado_Synthesis'.

### Runs and stages reached

| Run | Design | Constraints | synth | opt | place | phys_opt | route | Wall time |
|---|---|---|---|---|---|---|---|---|
| 1 | ATEE-Lite vl=16 (`atee_top_vl16`), full chip, ENABLE_DIV=0 | 20 ns on `clk` only; no I/O delays, no exceptions (as the 2019.1 full-chip runs) | 17:33 | 17:35 | 17:39 | 17:40 | **17:45** | 27 min |
| 2 | ATEE-Lite vl=8 (`atee_top`), full chip, ENABLE_DIV=0 | same | 18:00 | 18:01 | 18:06 | 18:06 | **18:10** | 25 min |
| 3 | IISc full system, top `FPGA_WRAPPER`, main memory included, not out of context | their `constraints.xdc` exactly as written (hash-identical to the repo's), pins included; clocks from clk_wiz_0's own XDC | 18:49 | 18:58 | 19:21 | 19:24 | **19:40** | 1 h 29 min (incl. 8 min mainMem IP resynthesis) |

- **Run 3, first launch:** it stopped before synthesis on a quoting error in my script (`read_xdc` split the path at the space in "Source code"). It was relaunched from scratch, and that first log was overwritten.
- **Run 3, init file:** mainMem's init file was set to `xmem.coe` (user decision 2026-11-13) and its IP was regenerated and resynthesized with `-force`. A first unforced attempt had reported "sub-design is up-to-date, no action was taken".
- **Run 3, sources:** their RTL from the copy; defines itlb_def=1, test_tlb=1, hardware_test=0 (only `itlb_def` is tested in their RTL); OUR stand-ins for xbip_dsp48_macro_1/_2.

### Results, post-route

| | Run 1: ATEE vl=16 | Run 2: ATEE vl=8 | Run 3: IISc FPGA_WRAPPER |
|---|---|---|---|
| Nets routed | 39,492 of 39,492, 0 errors | 39,644 of 39,644, 0 errors | 134,114 of 134,114, 0 errors |
| Slice LUTs (of 303,600) | 25,407 (8.37%) | 24,940 (8.21%) | 87,259 (28.74%) |
| Slice registers (of 607,200) | 15,166 FF, 0 latches | 15,145 FF, 0 latches | 44,273 = 42,440 FF + 1,833 latches |
| Block RAM tiles (of 1,030) | 128 (128 RAMB36) | 128 | 399 (394 RAMB36 + 10 RAMB18) |
| DSP48E1 (of 2,800) | 61 | 61 | 76 |
| Bonded IOB | 258 | 257 | 11 |
| Setup WNS / TNS | **+1.810 ns** / 0.000 | **+2.723 ns** / 0.000 | **−6.193 ns** / −8,871.041 ns |
| Failing setup endpoints | 0 of 29,796 | 0 of 29,761 | 3,748 of 88,287 |
| Hold WHS / THS | +0.030 / 0.000 (0 failing) | +0.049 / 0.000 (0 failing) | +0.060 / 0.000 (0 of 119,998 failing) |
| Timing at 50 MHz | **MET** | **MET** | **NOT MET** |
| Derived max frequency | 1000/18.190 = 54.98 MHz | 1000/17.277 = 57.88 MHz | core clock: 1000/26.193 = 38.18 MHz |
| Worst path | `EXE_MEM_counts_reg[0][0]` → `EXE_MEM_ALU_y_reg[2][30]`, 18.091 ns, 26 levels (inherited vector unit) | `EXE_MEM_counts_reg[0][0]` → `EXE_MEM_ALU_y_reg[1][20]`, 17.231 ns, 21 levels (inherited vector unit) | inside their div_gen IP `GEN_DIVIDERs[7]…signed_divider`, 25.886 ns (logic 14.993, route 10.893), 161 levels (144 CARRY4) |

The 2019.1 Artix-7 stand-in figures for the same designs (§3, "vl=16 power, full chip, SAIF") were +0.251 ns (vl=8) and +0.312 ns (vl=16). Those were measured on a different part and with a different tool version, and are not superseded: both sets stand, each labelled by device.

### Run 3: their timing exceptions and per-clock timing

- **Exceptions: 34 of 34 match**, on the synthesized netlist and again on the routed netlist. Each `-from`/`-to`/`-through` list is non-empty (`exceptions_match_post_synth.txt`, `exceptions_match_post_route.txt`).
  - The 101 "No pins matched" warnings in the log come from the pass during synthesis, while the IPs are still black boxes.
  - When the IP netlists are linked, `constraints.xdc` is re-applied with no "No pins matched". The only warnings left are 24 "is not a valid startpoint" and 100 "is not a valid endpoint". These are output or data pins that their wildcard pin lists include (e.g. `.../SIMPLE_PRIM36.ram/DOADO[31]`, `sel_pipe_reg[1]/Q`). Vivado drops those pins and applies the exception to the valid ones.
  - `report_exceptions` produced no file (the call was guarded and its error not recorded), so the match count rests on the object probe.
- **Clocks (from clk_wiz_0):** clk_in1_p 200 MHz (5.000 ns) → clk_out1_clk_wiz_0 **50 MHz** (core) and clk_out2_clk_wiz_0 **100 MHz** (clk_x2).

| Clock | Setup WNS | TNS | Failing / total endpoints | Hold WHS | Hold failing | Met? |
|---|---|---|---|---|---|---|
| clk_out1_clk_wiz_0, 50 MHz core | −6.193 ns | −8,871.041 ns | 3,748 / 82,549 | +0.060 ns | 0 / 96,704 | **NO** |
| clk_out2_clk_wiz_0, 100 MHz clk_x2 | +5.185 ns | 0.000 | 0 / 5,104 | +0.091 ns | 0 / 5,104 | yes |
| clk_out1 → clk_out2 | +4.076 ns | 0.000 | 0 / 3,134 | +0.121 ns | 0 | yes |
| clk_out2 → clk_out1 | +7.789 ns | 0.000 | 0 / 42 | +0.102 ns | 0 | yes |

- **Against their claim:** according to the user's reading of the paper, IISc claim about +0.4 ns slack at 50 MHz. That claim is not reproduced here: −6.193 ns, with their exceptions applied as written.
- **Where the 3,748 failing core-clock endpoints are** (read-only analysis of the routed checkpoint, `scripts/v7_iisc_analyze.tcl`):
  - 1,087 inside their div_gen IP (`GEN_DIVIDERs`)
  - 522 elsewhere in the vector unit
  - 64 in the scalar FPU
  - 2,075 elsewhere in the scalar core
- **Worst path ending outside the divider IP:** −4.321 ns, datapath 23.623 ns, 45 levels, from a DMEM1 block RAM (`VECTOR_UNIT/.../DMEM1/...ramloop[14]...`) to `cpu1/fdem/db1/biu1/FSM_onehot_wb_fsm_state_cur_reg[2]/D`. So the core clock fails even without the divider paths.
- **Not determined:** whether their implementation used other constraints, tool settings or an older divider configuration. Their repo has one XDC, and it is the one applied here.

### Run 3: utilization split as in their Table III

Hierarchy rows from `post_route_utilization_hier.rpt`. Vector pipeline = the `VECTOR_UNIT` row. Scalar pipeline = `cpu1` minus `VECTOR_UNIT`. Main memory + peripherals + I/O = top minus `cpu1`. Block RAM is counted in tiles (RAMB18 = ½).

| Block | LUT (here) | Registers (here) | BRAM tiles (here) | DSP (here) | Their Table III (LUT / FF / BRAM / DSP) |
|---|---|---|---|---|---|
| Vector pipeline (`VECTOR_UNIT`) | 46,479 | 22,098 | 116 (112 + 8×½) | 44 | 35,737 / 19,896 / 32 / 43 |
| Scalar pipeline (`cpu1` − `VECTOR_UNIT`) | 39,425 | 21,700 (incl. the 1,833 latches) | 27 | 32 | 41,996 / 22,032 / 27 / 24 |
| Main memory + peripherals + I/O (top − `cpu1`) | 1,355 | 475 | 256 | 0 | 1,201 / 470 / 256 / 0 |
| Total | 87,259 | 44,273 | 399 | 76 | 78,934 / 42,398 / 315 / 67 (sum of their three rows) |

Of the third row: `em1` (main-memory emulator incl. mainMem) has 629 LUT / 42 regs / 256 tiles, `uart_snd` 449 LUT / 360 regs. Their Table III figures are THEIRS-QUOTED from §2 ("I2SRV32-V, the paper's own area figures"). The main-memory row agrees closely, and the vector and scalar rows do not. Why has NOT been determined. Their vector BRAM count (32) is far below the 116 tiles their own `vector_top` uses here, and the stand-in `xbip_dsp48_macro_1/_2` sit in the scalar part.

### Control logic, same subtraction method as "Provenance audit"

| Design | Method | Value |
|---|---|---|
| IISc, Virtex-7 full system | `cpu1` row − `VECTOR_UNIT` row (same run) | **39,425 LUT** (Artix-7 out-of-context `cpu` run: 39,468) |
| ATEE vl=16, Virtex-7 full chip | total − `u_vec_unit` row (same run) | **1,102 LUT** (row sum `u_config` + `u_hbm_lite` = 412 + 731 = 1,143) |
| ATEE vl=8, Virtex-7 full chip | total − `u_vec_unit` row (same run) | **1,162 LUT** (row sum 409 + 793 = 1,202) |

Basis caveat: ours is clock-only, while theirs carries their 34 exceptions and pin constraints. Both are full-chip runs with the same tool and the same part.

### Run 3: repo build vs their paper (2026-11-14, read-only analysis)

Sources: their paper ("A Soft RISC-V Vector Processor for Edge-AI", VLSID 2022; local copy `<AUTHOR_LOCAL>\A_Soft_RISC-V_Vector_Processor_for_Edge-AI.pdf`, text extracted with PyMuPDF; part of the text is in a shifted font encoding and was decoded by a fixed +29 character offset, and the numbers inside Table III and the slack figure did not survive extraction); their repo's original .xci; their RTL; the routed Run 3 checkpoint, analysed with `scripts/v7_iisc_analyze.tcl`, `v7_iisc_analyze2.tcl` and `v7_iisc_analyze3.tcl` (all read-only; reports `analysis*_*.rpt/.txt` in the run directory). Nothing was re-implemented.

**1. Vector scratchpad (DMEM) size: the repo has 4× the paper's.**

| | Paper | Repo build (Run 3) |
|---|---|---|
| Per bank | 16 KB ("one bank of a 16 KB software-controlled scratchpad memory" per lane) | 16,384 × 32 bit = 64 KB (`DMEM_0..7.xci`: Write_Depth_A 16384, Write/Read_Width_A 32, Single_Port_RAM, Algorithm Minimum_Area) |
| Total | 128 KB ("a total capacity of 128 KB for the vector memory") | 512 KB |
| BRAM tiles | 32 (their Table III, vector row) | 116 = 8 × (14 RAMB36 + 1 RAMB18). Per bank: 12 RAMB36 at width 9, 2 RAMB36 at width 2, 1 RAMB18 at width 1 |

What sets the size in the repo: the IP parameter Write_Depth_A = 16384; `VMEM_ADDR_WIDTH := 14` in `rtl/vector_unit/mypack.vhd:25` ("Change this when DMEM ADDR WIDTH Changes"); the hard-coded `generic map(VMEM_ADDR_WIDTH=>14)` in `wrapper.vhd:92` (default 14 also in `exe_unit.vhd:23` and `cpu_inf.vhd:49`). Their own comment, `cpu_inf.vhd:36`: "Changed : May 28 2021: To Increase the size of Scratchpad Memory from 128 kB to 512 kB". So the repo is a build made after the configuration the paper describes. Arithmetic, not run: a 4,096 × 32 bank built from 4K × 9 primitives takes 4 RAMB36, × 8 = 32 tiles, which is exactly their Table III BRAM figure. conv8_3's own bank images use word indices 0..91 only (165–166 words per COE).

**2. Dividers.** Each of the 8 slots instantiates `multicycle_ops` (`exe_unit.vhd:319`, GEN_DIVIDERs) with two div_gen 5.1 IPs: `div_gen_0` signed and `div_gen_1` unsigned. Both use Radix2, 32-bit dividend/quotient and divisor, remainder output, latency 4 (Manual), 1 clock per division, divide-by-zero detect, NonBlocking. That makes 16 dividers. The paper does not mention division. Its VAU examples are vadd, vmacc, vmin, vmax, vargmax and vslide, and "divi" or "quotient" appears nowhere in the extracted text, in either encoding. In Run 3, post-route, site LUTs:

| | LUT |
|---|---|
| 8 × `GEN_DIVIDERs[i]` rows, sum | 23,244 |
| of which div_gen IP cores (`U0` rows): signed 8 × 1,243 = 9,944; unsigned 9,164 | 19,108 |
| of which `multicycle_ops` own logic (7 × 81 + 3,569 in slot 7) | 4,136 |

Primitive count (`analysis2`): 24,554 LUT, 5,126 CARRY4 and 7,370 FF are named under GEN_DIVIDERs. Primitive counts exceed site counts because of LUT combining.

**3. Vector-unit LUT breakdown, Run 3 (site LUTs, `analysis2_vector_hier.rpt`).**

| Sub-block | LUT |
|---|---|
| Dividers (GEN_DIVIDERs, above) | 23,244 |
| VRF banks (GEN_VRFS[0..7], `vrf_bank`) | 11,220 |
| CPU interface (`VECTOR_CPU_INF`, `cpu_inf`: host access to VRF/SPRAM) | 3,123 |
| Scalar-register output (`X_REGS`, `Xoutreg`) | 2,405 |
| Element counters (GEN_COUNTERS[0] row; the other seven have no row of their own in the report) | 1,941 |
| `exe_unit` own logic: the DMEM crossbar and VEC/CPU muxes, register-read crossbars, pipeline glue | 1,763 |
| ALUs (GEN_ALUs[0..7]) | 1,072 |
| vmin/vmax (GEN_VMINMAX[0..7]) | 1,019 |
| Not attributed to a listed row (DMEM IP output muxes, LSUs and remaining counters, which have no rows; cross-hierarchy LUT combining) | 496 |
| `vector_top` own | 196 |
| **VECTOR_UNIT total** | **46,479** |

The crossbars and LSUs are not separate instances after synthesis. Of the 2,091 LUT primitives owned directly by `exe_unit`, 1,602 are named after the DMEM bank pin they drive (`DMEM0_i_*` … `DMEM7_i_*`: the DMEM address/data/write-enable crossbar with the CPU mux). The DMEM IP output muxes are 31 LUT primitives per bank. Vector total minus dividers = 46,479 − 23,244 = 23,235, which is below the paper's 35,737. The dividers alone therefore do not account for the difference in either direction, and no single block here explains the 10,742 LUT gap. NOT determined.

**4. Worst path outside the divider (−4.321 ns) vs the paper's named critical path.** The paper says: "although the vector unit could run at 100 MHz frequency as a stand-alone unit, the bus interface logic for the host CPU to directly access the VRF and SPRAM forms the critical path in the entire design", with a positive slack (the value did not survive text extraction; about 0.4 ns on the user's reading).

| | |
|---|---|
| From → to | `DMEM1` block RAM (`ramloop[14]`, RAMB36E1) → `db1/biu1/FSM_onehot_wb_fsm_state_cur_reg[2]` (D-cache Wishbone BIU state) |
| Data path | 23.623 ns = logic 4.305 ns (18.2%) + route 19.318 ns (81.8%); BRAM clock-to-out 1.800 ns |
| Logic levels | 45 (CARRY4 1, LUT2 3, LUT3 4, LUT4 5, LUT5 7, LUT6 23, MUXF7 1, MUXF8 1) |
| Cells by hierarchy | DMEM IP 2 (the RAMB36 and 1 output-mux LUT6), `VECTOR_CPU_INF` 21, D-TLB 1, rest of `dcache_top` 20, `biu1` 3 (incl. the endpoint FF) |
| BRAM cascade | none: 0 connected CASCADEIN/OUT pins in any of the 8 banks. The 16K depth is a 4-way depth split per bit group, resolved by one LUT6 output mux (one level on this path) |

Reading: the path starts in the SPRAM and goes through `cpu_inf` ("Vector Memory and Register Interface with CPU"), the block the paper names. But 24 of its 45 levels are in the scalar D-cache/TLB/Wishbone logic, and it ends there. The cells placed under `VECTOR_CPU_INF` carry scalar-pipeline signal names (`BTB_Write_Data`, `ALU_Result__ex_mem`, `proc_addr_in_port1`, `non_cacheable`, `Load_Store_Op__ID_EX`), so the 21-cell figure is netlist hierarchy after cross-boundary optimisation, not necessarily RTL origin. Whether this is the path the paper means, and why it fails here when they report positive slack, is NOT determined. It is consistent with the paper's description in where it starts, and it fails on routing delay (81.8%).

## Paper-configuration experiment (128 KB scratchpad), Virtex-7, 2026-11-14 — EXPERIMENT, does not replace Runs 1–3

Approved by the user (CLAUDE.md DECIDED 2026-11-14). Implementation only, Vivado 2026.1, xc7vx485tffg1761-2. The vector scratchpad is set to the paper's size: 4,096 × 32 bit = 16 KB per bank, 128 KB in total. Every repo-build figure above stands.

### IISc FPGA_WRAPPER, paper configuration

- **Copy:** `external_2026/iisc_paper_cfg/`, made from `iisc_copy` (the upgraded 2026.1 .xcix, RTL, constraints, stand-ins, conv8_3 COE files). `.orig` files are kept beside each edited file. `iisc_copy` and the original repo are untouched.
- **IP:** DMEM_0..7 `Write_Depth_A` 16384 → 4096, set in the script's ipprep stage. Read back as `DMEM_<n> Write_Depth_A=4096 Write_Width_A=32 Coe=dmem_bank<n>.coe` for all 8. The init files were kept, because conv8_3's bank images have 165–166 words, which fit in 4,096. mainMem → xmem.coe, as in Run 3.
- **RTL, every occurrence of the same parameter (14 → 12):**

| File:line | Before | After |
|---|---|---|
| `mypack.vhd:25` | `constant VMEM_ADDR_WIDTH : INTEGER := 14;` | `:= 12;` |
| `mypack.vhd:104` (component `cpu_inf` default) | `generic(DMEM_ADDR_WIDTH : integer :=14);` | `:=12` |
| `wrapper.vhd:66` (component `exe_unit` default) | `generic(VMEM_ADDR_WIDTH : integer :=14);` | `:=12` |
| `wrapper.vhd:92` | `exe_unit generic map(VMEM_ADDR_WIDTH=>14)` | `=>12` |
| `exe_unit.vhd:23` (entity default) | `generic(VMEM_ADDR_WIDTH : integer :=14);` | `:=12` |
| `cpu_inf.vhd:49` (entity default) | `generic(DMEM_ADDR_WIDTH : integer :=14);` | `:=12` |

- **Not changed, because they are different constants:**
  - the defaults `DMEM_ADDR_WIDTH := 10` in `dmem_addr_xbar.vhd:28` and `mypack.vhd:318`, which are always overridden by the explicit map in `exe_unit`;
  - the CPU decode window `DMEM_END = x"0017FFFC"` in `cpu_inf.vhd:78` (512 KB). Addresses above 128 KB in that window therefore alias (row = addr[16:5]). conv8_3 does not use them.
  - No Verilog file uses the width (`vector_top.v` and `v_wrapper.v` pass no generic).
- **Flow:** as Run 3, `scripts/v7_impl_iisc_papercfg.tcl`: their `constraints.xdc` unchanged, top FPGA_WRAPPER, main memory included, a checkpoint after every stage. Output is in `synth_build_2026/v7_xc7vx485t/iisc_paper_cfg_experiment/`. The first launch stopped in ipprep on a reporting line in my script (it asked for a `Read_Depth_A` property this IP does not have) and was relaunched unchanged otherwise; its log is kept as `logs/iisc_paper_cfg_experiment_attempt1.log`.
- **Stages reached:** ipprep 18:40, synth 19:13, opt 19:18, place 19:38, phys_opt 19:43, route 20:06 (all 2026-11-14), then reports. Routing: 129,949 of 129,949 nets, 0 errors. Exceptions: `V7P EXCEPTIONS post_synth: 34 of 34 match`, `V7P EXCEPTIONS post_route: 34 of 34 match`.

**Utilization, split as their Table III** (same method as "Run 3: utilization split as in their Table III"; BRAM in tiles):

| Block | Paper configuration (LUT / registers / BRAM / DSP) | Repo build, Run 3 | Their Table III |
|---|---|---|---|
| Vector pipeline (`VECTOR_UNIT`) | **45,351 / 22,002 / 32 / 42** | 46,479 / 22,098 / 116 / 44 | 35,737 / 19,896 / 32 / 43 |
| Scalar pipeline (`cpu1` − `VECTOR_UNIT`) | 39,330 / 21,695 / 27 / 32 | 39,425 / 21,700 / 27 / 32 | 41,996 / 22,032 / 27 / 24 |
| Main memory + peripherals + I/O (top − `cpu1`) | 1,351 / 475 / 256 / 0 | 1,355 / 475 / 256 / 0 | 1,201 / 470 / 256 / 0 |
| Total | 86,032 / 44,172 (42,339 FF + 1,833 latches) / **315** / 74 | 87,259 / 44,273 / 399 / 76 | 78,934 / 42,398 / **315** / 67 |

- **BRAM:** the scratchpad size accounts for the whole BRAM difference. The vector unit takes 32 tiles, equal to their Table III, and the total of 315 equals the sum of their three rows.
- **LUTs:** the vector unit drops by only 1,128 (46,479 → 45,351), to 9,614 above their 35,737. The vector LUT gap is NOT explained by the scratchpad size.
- **DSP:** the vector unit has 42 (Run 3: 44; their table: 43).
- **Control logic, same subtraction:** 39,330 LUT.

**Timing, post-route, their constraints as written:**

| Clock | Setup WNS | TNS | Failing / total endpoints | Hold WHS | Met? |
|---|---|---|---|---|---|
| clk_out1 (core, 50 MHz) | **−6.393 ns** | −11,156.177 ns | 7,001 / 80,458 | +0.064 ns | **NOT met** (Run 3: −6.193 ns, 3,748 failing) |
| clk_out2 (clk_x2, 100 MHz) | +4.417 ns | 0 | 0 / 5,104 | +0.092 ns | met |
| clk_out1 → clk_out2 | +4.055 ns | 0 | 0 / 3,134 | +0.110 ns | met |
| clk_out2 → clk_out1 | +7.629 ns | 0 | 0 / 42 | +0.105 ns | met |

- Derived core-clock maximum: 1000 / 26.393 = 37.89 MHz (Run 3: 38.18 MHz).
- Failing core-clock endpoints by area (one path per endpoint, same classification as `scripts/v7_iisc_analyze.tcl`): divider IP 1,061; vector unit outside the divider 3,585; FPU 62; rest of the scalar core 2,293. Run 3 had 1,087 / 522 / 64 / 2,075. Why the vector-unit count is higher here is NOT determined.
- **Worst path inside the divider:** −6.393 ns, datapath 26.097 ns (logic 14.777 + route 11.320), 161 levels, within `GEN_DIVIDERs[5]` signed div_gen.
- **Worst path outside the divider:** −4.712 ns, datapath 24.489 ns (logic 4.797 + route 19.692 = 80.4%), 47 levels, from the D-cache tag RAM (`db1/dt1/dd/tag_w0`, RAMB36) to `db1/dt1/drf1/proc_data_buff_reg[17]`. This is scalar D-cache logic, not the vector bus interface.
- **Against the paper's claim** (positive slack, about +0.4 ns at 50 MHz on the user's reading): **not reproduced** with the scratchpad at the paper's size either. The scratchpad size is therefore not the cause of the timing gap; the cause is NOT determined.

### ATEE-Lite vl=16, paper configuration — NOT RUN (status)

- **Copy:** `external_2026/atee_paper_cfg/vector_unit/`: the 20 source files of the vl=16 full-chip build, with `.orig` beside each edited file. Our RTL has no existing parameter for the size, because `wrapper.vhd` hard-codes it. Edits, 14 → 12:
  - `mypack.vhd:25` (constant `VMEM_ADDR_WIDTH`), `mypack.vhd:104` (component `cpu_inf` default), `mypack.vhd:230` (component `dmem_bram` default `ADDR_WIDTH`);
  - `dmem_bram.vhd:7` (entity default `ADDR_WIDTH`);
  - `exe_unit.vhd:23` (entity default), `wrapper.vhd:67` (entity default), `wrapper.vhd:94` (`generic map(VMEM_ADDR_WIDTH=>12, …)`);
  - `cpu_inf.vhd:49` (entity default).
  - `DMEM_END` is unchanged, as for IISc.
- **Script:** `scripts/v7_impl_atee_papercfg.tcl` (settings as Run 1). It was launched at 20:14 and **stopped by me at START, before synthesis**. The battery status had changed to 1 (discharging, 50%), and the run rules require mains power. No result exists. It is to be relaunched unchanged on mains power.
- **Capacity note:** at 4,096 words per bank (32,768 words in all), CONV2D 3x3 64x64 no longer fits on the vl=16 controller. Its input alone, replicated 16x, is 64 × 64 × 16 = 65,536 words.

### ATEE-Lite vl=16, paper configuration — RESULT (relaunched 2026-11-14 20:19 on mains power, unchanged)

Stages: START 20:19, synth 20:35, opt 20:36, place 20:41, phys_opt 20:41, route 20:46, reports 20:47. Routing: 39,528 of 39,528 nets, 0 errors. `V7AP SOURCES 20 files, all from …/external_2026/atee_paper_cfg/vector_unit: 1`. The stopped first attempt is kept as `stage_attempt1_stopped.txt` / `logs/atee_vl16_paper_cfg_experiment_attempt1_stopped.log`.

| | 128 KB (paper configuration) | 512 KB (Run 1, repo build) |
|---|---|---|
| Slice LUTs | 24,617 | 25,407 |
| Flip-flops / latches | 15,068 / 0 | 15,166 / 0 |
| Block RAM tiles | **32** (32 RAMB36) | 128 |
| DSP48E1 | 58 | 61 |
| Bonded IOB | 245 | 258 |
| Hierarchy `u_config` / `u_hbm_lite` / `u_vec_unit` LUTs | 412 / 727 / 23,515 | 412 / 731 / 24,305 |
| Control logic (total − `u_vec_unit`) | 1,102 | 1,102 |
| WNS / TNS | **+3.091 ns** / 0 (0 of 28,114 failing) | +1.810 ns / 0 |
| Hold WHS | +0.076 ns, met | +0.030 ns, met |
| Max frequency (1000 / (20 − WNS)) | **59.14 MHz** | 54.98 MHz |
| Worst path | 16.884 ns, 25 levels, `EXE_MEM_v0_DATA_reg[0][15]` → `X_REGS/Xoutreg_reg[7][30]` (inherited vector unit) | inside the vector unit |

ATEE meets 50 MHz at both sizes. At 128 KB it is 2.25 BRAM tiles smaller per bank (4 against 16). Our vector unit uses 4 RAMB36 per bank, the same count as the 32 in their Table III.

## Virtex-7 power (2026-11-14) — Simulation: Vivado 2019.1 xsim (2026.1 BASIC simulator limited to 50,000 instances); netlist, implementation and power analysis: 2026.1

Designs: the repo-build Runs 1–3 above (512 KB scratchpad), routed on xc7vx485tffg1761-2. Decision and reason: CLAUDE.md, DECIDED (2026-11-14), Task B flow. The 2026.1 simulator's own message on the vl=16 netlist: `ERROR: The current Vivado Simulator license tier you have, BASIC, does not meet the requirement to run the number of instances in this design. Number of instances in this design, 54308, exceed maximum allowed 50000.`

**Flow, the same for every design:**
1. The routed checkpoint goes through `write_verilog -mode funcsim` in 2026.1 (`scripts/v7_power_export.tcl`).
2. Post-implementation FUNCTIONAL simulation (unisim models, no timing annotation) runs in 2019.1 xsim. The install is used as is and was not modified.
3. A SAIF is recorded over the window.
4. 2026.1 `read_saif` + `report_power` run on the same routed checkpoint (`scripts/v7_power_report.tcl`).

Drivers: `scripts/v7_power_atee.ps1`, `scripts/v7_power_iisc.ps1`. SAIF scripts: `testbench/v7_power_saif_atee.tcl`, `testbench/v7_power_saif_iisc.tcl`. Hierarchy list: `scripts/v7_power_hiercells.tcl`. Outputs are in `synth_build_2026/v7_power/<design>/sim_<mode>/`. Workload: conv8_3 data, no ReLU, BRAM-only, no DMA.

### SAIF logging fix

- **Cause, measured with a probe in xsim:** `get_objects $scope/*` on an escaped scope such as `/…/VECTOR_EXE_UNIT_PIPE/\GEN_ALUs[1].alu_gen ` does not resolve. It falls back to the testbench's own top-level signals (77 objects, the first being `/atee_conv_vl16_tb/clk`). That is why the earlier runs logged design nets for only 19 of their 59 listed scopes.
- **Fix ("new" mode):** walk the design breadth-first from `dut`, entering each scope with `current_scope` and listing it with `get_objects *` / `get_scopes *`. Descend only into the hierarchical (non-primitive) cells Vivado lists for that checkpoint, which keeps the walk out of the primitive models. On the probe, `current_scope` + `get_objects *` gave 349 objects, all inside `\GEN_ALUs[1].alu_gen `.
- **"old" mode** reproduces the earlier logging, for the "before" figure.

| Netlist | Old logging: scopes logged / nets matched by report_power | New logging: scopes logged / nets matched |
|---|---|---|
| ATEE vl=16, Virtex-7 | 19 of 59 / **51%** (27,445 of 54,065) | 59 (dut + 58 of 58 cells) / **100%** (54,065 of 54,065) |
| ATEE vl=8, Virtex-7 | 19 of 59 / **51%** (27,090 of 53,289) | 59 (dut + 58 of 58) / **100%** (53,289 of 53,289) |
| ATEE vl=16, Artix-7 (cross-check) | 19 of 59 / 49% (25,500 of 52,516), the recorded run | 59 (dut + 58 of 58) / **100%** (52,516 of 52,516) |

### Validation gates (CLAUDE.md DECIDED 2026-11-14)

**Gate 1, functional equivalence in 2019.1 xsim.** Every ATEE netlist run reproduces the RTL result.

| Netlist | Layer-busy cycles | Outputs | RTL reference |
|---|---|---|---|
| ATEE vl=16, Virtex-7 (new and old logging) | 2,599 | 576/576 bit-exact vs reference and vs THEIR expected | 2,599 |
| ATEE vl=8, Virtex-7 (new and old logging) | 3,403 | 576/576 bit-exact, 0 errors | 3,403 |
| ATEE vl=16, Artix-7 (new logging) | 2,599 | 576/576 | 2,599 |

xsim console, vl=16 Virtex-7, new logging:
```
SAIF window opens at 47840 ns (after 2392 cycles of reset, DMEM load and configuration)
SAIF MODE new: logging 47040 nets/ports from 59 scopes (dut + 58 of 58 hierarchical cells listed by Vivado; not found: 0)
SAIF window closes at 99820 ns: 2599 clock cycles with layer_busy = 1
  cfg_error                       : 0
  layer-busy cycles               : 2599
  bit-exact vs reference           : 576 / 576 (max |diff| 0)
  bit-exact vs THEIR expected     : 576 / 576 (max |diff| 0)
  STATUS                          : ** PASS **
```
xsim console, vl=8 Virtex-7, new logging:
```
SAIF window opens at 27360 ns (after 1368 cycles of reset, DMEM load and configuration)
SAIF MODE new: logging 50330 nets/ports from 59 scopes (dut + 58 of 58 hierarchical cells listed by Vivado; not found: 0)
SAIF window closes at 95420 ns: 3403 clock cycles with layer_busy = 1
  Bit-exact matches       : 576 / 576
  Errors (|diff| > 10)    : 0
  Max absolute error      : 0
  ATEE cycle count        : 3403 cycles
  STATUS                  : ** PASS **
```

**IISc: gate 1 could NOT be run. The flow is BLOCKED for this design.**
- **Two problems in 2019.1:**
  - 2019.1 xvlog fails on the 1,704,045-line netlist with `syntax error near ':'` reported at line 1,048,575 (= 2²⁰ − 1), on an ordinary wire declaration. Read as two parts split at module boundaries (`scripts/split_netlist.py`, no line changed), the true error location appears at part01 line 404,706: `` `pragma protect begin_protected ``.
  - The netlist holds **4 encrypted blocks** written by "Xilinx Encryption Tool 2026.1", each with a `xilinxt_2026.1-2030.x` key block (plus third-party simulator keys). The IP cores are defined only inside them: `div_gen_0_div_gen_v5_1_26` is instantiated 8 times with no clear-text definition, and so are the block-memory cores, e.g. `mainMem_blk_mem_gen`. 2019.1 has no 2026.1 Xilinx key.
- **So the IISc routed netlist cannot be simulated in 2019.1 xsim, and 2026.1 BASIC refuses it** (164,873 primitive cells, far above 50,000).
- The ATEE netlists contain no IP and are not affected.
- **No IISc power was computed.** No other method was substituted (an RTL-SAIF on the netlist would not be the same method). The testbench for this flow (`testbench/v7_iisc_netlist_tb.v`) was written but never ran.

**Gate 3, hybrid-flow cross-check on the Artix-7 vl=16 build** (recorded: 0.394 W total / 0.257 W dynamic / 0.137 W static, 49% matched, all in 2019.1). 2026.1 warns on opening the 2019.1 checkpoint ("failed integrity check (1)… missing checksum") and then opens it.

| | Total | Dynamic | Static | Matched | Confidence |
|---|---|---|---|---|---|
| Recorded (2019.1 sim, 2019.1 report_power, old logging) | 0.394 | 0.257 | 0.137 | 49% | High |
| Old SAIF file re-reported in 2026.1 | 0.394 | 0.257 | 0.137 | 49% (25,500 of 52,516) | High |
| Hybrid flow, new logging (2019.1 sim, 2026.1 report_power) | 0.386 | **0.249** | 0.137 | 100% (52,516 of 52,516) | High |

Difference in dynamic: −0.008 W = **−3.1%** (below the 10% limit). The tool version contributes 0: 2026.1 reproduces the 2019.1 figures exactly on the same SAIF. The whole difference comes from the logging fix. The nets that were previously unlogged had been estimated slightly high by vectorless propagation (signals 0.061 → 0.057 W, slice logic 0.034 → 0.031 W; clocks 0.033 and block RAM 0.128 W unchanged).

### Results, ATEE-Lite on Virtex-7 (repo-build size), new logging

| | ATEE vl=16 | ATEE vl=8 |
|---|---|---|
| Total on-chip | **0.504 W** | **0.491 W** |
| Dynamic | **0.252 W** | **0.240 W** |
| Device static | 0.251 W | 0.251 W |
| Tool confidence | High | High |
| Design nets matched | 100% (54,065 of 54,065) | 100% (53,289 of 53,289) |
| By type: clocks / slice logic / signals / block RAM / DSP / I/O | 0.034 / 0.035 / 0.056 / 0.128 / <0.001 / <0.001 W | 0.033 / 0.030 / 0.048 / 0.128 / <0.001 / <0.001 W |
| Dynamic by hierarchy: `u_vec_unit` / `u_hbm_lite` / `u_config` | 0.248 / 0.003 / 0.001 W | 0.235 / 0.003 / 0.001 W |
| Window (layer busy) | 2,599 cycles × 20 ns = 51.98 µs | 3,403 cycles × 20 ns = 68.06 µs |
| **Energy per layer, total** | **26.19792 µJ** (0.504 × 51.98) | **33.41746 µJ** (0.491 × 68.06) |
| **Energy per layer, dynamic** | **13.09896 µJ** (0.252 × 51.98) | **16.33440 µJ** (0.240 × 68.06) |
| Old logging, for reference (51% matched) | 0.514 / 0.262 / 0.252 W | 0.497 / 0.246 / 0.251 W |

- The device static power (0.251 W) is that of the much larger XC7VX485T. It is 0.137 W on the Artix-7 xc7a200t, so total power and total energy are not comparable across the two parts; dynamic is the like-for-like quantity.
- vl=16 / vl=8 dynamic energy per layer: 13.09896 / 16.33440 = 0.801925.
- The energies come from power figures the tool reports to 3 decimals. They exclude loading DMEM and reading back the results.
- Their paper's Table IV power (vector processor 597 mW total / 333 mW dynamic / 264 mW static) was measured on THEIR 6-layer CNN, by their own post-implementation functional simulation with vector-based estimation (paper §H). It was not measured on conv8_3. No IISc conv8_3 power exists from this flow (blocked, above), so no measured power or energy ratio against IISc is given.

## Virtex-7 power: RTL-SAIF method (all three designs)

**Method "RTL-SAIF"**, a second power method, separately labelled. It does not alter or replace the netlist-SAIF results above. Decision and reason: CLAUDE.md DECIDED (2026-11-14), RTL-SAIF. The netlist-SAIF flow cannot run on the IISc design (2026.1-encrypted IP unreadable by 2019.1; the 2026.1 BASIC simulator is limited to 50,000 instances; the IISc netlist has 164,873 primitives).

- **Simulation:** behavioural RTL simulation in **Vivado 2026.1 xsim, for all three designs.** The RTL designs are within the BASIC instance limit; 2019.1 was not needed. IISc uses the 2026.1 IP simulation models of the copy's upgraded IP, and the xmem.coe program image, as in Run 3.
  - ATEE: ENABLE_DIV=0, as in the Virtex-7 builds. vl=8 uses `-d DIV_OFF`; vl=16 uses the new second top `testbench/v7_divoff_vl16.v` (a defparam), with the testbench unchanged. conv8_3 data, no ReLU, BRAM-only, no DMA.
- **SAIF:** `testbench/v7_rtlsaif.tcl`, `log_saif [get_objects -r <tb>/dut/*]`. Excluded: ATEE's 8 `DMEM*/ram` memory arrays (no netlist nets). IISc: no exclusion; 37,261 objects logged, 0 rejected.
  - A breadth-first walk with `current_scope` was tried first. It did not reach the VHDL generate scopes (21 SAIF instances against 101 with `-r`) and was replaced; with `-r` the vl=16 match share was unchanged (1,528 nets).
- **Power:** `scripts/v7_rtlsaif_report.tcl` runs `read_saif -strip_path <tb>/dut` + `report_power` (2026.1) on each routed Virtex-7 checkpoint: Runs 1 and 2 (ATEE), Run 3 (IISc, 512 KB repo build, their constraints). The clock is the nominal 50 MHz. **IISc fails timing at 50 MHz (core-clock WNS −6.193 ns); its power is computed at the nominal 50 MHz anyway.**
- **Match by category:** `report_switching_activity -signal_rate -type register|bram_enable|bram_wr_enable|dsp -all`. Each pin's signal-rate source is reported as S (from the SAIF), P (propagated), D (default). "From SAIF" counts S.
- **Drivers:** `scripts/v7_rtlsaif_atee.ps1 -Design vl16|vl8`, `scripts/v7_rtlsaif_iisc.ps1` (detached via `scripts/launch_ps_detached.ps1`). Outputs are in `synth_build_2026/v7_power_rtlsaif/`.

### Gate: RTL reproduces the cycle counts and exact outputs — PASS for all three

| Design | Window cycles | Outputs |
|---|---|---|
| ATEE vl=16 | 2,599 (layer busy) | 576/576 bit-exact vs reference and vs THEIR expected |
| ATEE vl=8 | 3,403 (layer busy) | 576/576 bit-exact, 0 errors, `DIVIDER: REMOVED (ENABLE_DIV=0)` |
| IISc | conv2d() 3,181 (entry at 816, return at 3,997); main returns at 28,888 | err_count written once, value 0; Y 576/576 exact vs THEIR expected and vs Python reference at the calibrated latency L=1 |

IISc xsim console (conv2d window run):
```
[IISC] cycle 816: conv2d entered (PC = 0x9d0)
RS window iisc_conv opens at 16920 ns (after 846 steps of 20 ns)
RS logging 37261 objects (get_objects -r below dut: 37261; 0 excluded by RS_SKIP/RS_NODESCEND; 0 rejected by log_saif)
[IISC] cycle 3997: conv2d returned (PC = 0xe98)
RS window iisc_conv closes at 80540 ns: 3181 steps of 20 ns
[IISC] cycle 28888: main returned (PC = 0xec, final loop)
  conv2d entry  -> conv2d return     : 3181 cycles
  err_count == 0                     : YES
    L=1: expected_output[] covered 576/576, captured value == file 576 | Y covered 576/576, exact vs THEIR expected 576 (max |diff| 0), exact vs Python ref 576 (max |diff| 0)
  calibrated latency: L=1 (576 of 576 expected_output[] reads reproduce the file)
```

### Results (RTL-SAIF, Virtex-7, 50 MHz nominal)

| | ATEE vl=16 | ATEE vl=8 | IISc, conv2d() window |
|---|---|---|---|
| Total on-chip | 0.559 W | 0.543 W | 0.975 W |
| Dynamic | 0.307 W | 0.291 W | 0.706 W |
| Device static | 0.252 W | 0.252 W | 0.269 W |
| Tool confidence | Medium | Medium | Medium |
| Design nets matched | 3% (1,528 of 54,065) | 3% (1,443 of 53,289) | 8% (14,594 of 191,553) |
| Registers from SAIF (Q pins) | 3.1% (465 of 15,166) | 2.8% (418 of 15,145) | 10.5% (4,474 of 42,440) |
| BRAM enable pins from SAIF | 0% (0 of 256) | 0% (0 of 256) | 0% (0 of 808) |
| BRAM write-enable pins from SAIF | 2.1% (32 of 1,536) | 8.3% (128 of 1,536) | 26.9% (1,288 of 4,788) |
| DSP pins from SAIF | 0% (0 of 2,385) | 0% (0 of 2,389) | 5.8% (156 of 2,698) |
| By type: clocks / slice logic / signals / block RAM / DSP / I/O (+ MMCM) | 0.034 / 0.043 / 0.086 / 0.129 / 0.015 / <0.001 | 0.033 / 0.038 / 0.076 / 0.128 / 0.015 / <0.001 | 0.093 / 0.150 / 0.246 / 0.092 / 0.014 / 0.004 (MMCM 0.107) |
| Window | 2,599 cycles = 51.98 µs | 3,403 cycles = 68.06 µs | 3,181 cycles = 63.62 µs |
| Energy per layer, total | 29.05682 µJ | 36.95658 µJ | 62.02950 µJ |
| Energy per layer, dynamic | 15.95786 µJ | 19.80546 µJ | 44.91572 µJ |

**IISc, whole run** (reset release → main returns, 28,888 cycles = 577.76 µs; separate simulation, which again gives err_count 0 and 576/576 at L=1). `RS window iisc_all closes at 578360 ns: 28888 steps of 20 ns`.

| | Total | Dynamic | Static | Confidence | Nets matched | Registers / BRAM en / BRAM wr-en / DSP from SAIF | Energy, whole run (total / dynamic) |
|---|---|---|---|---|---|---|---|
| IISc whole run | 0.968 W | 0.698 W | 0.269 W | Medium | 8% (14,594 of 191,553) | 10.5% / 0% / 26.9% / 5.8% (as the conv2d window) | 559.27168 / 403.27648 µJ |

By type (whole run): clocks 0.097, slice logic 0.150, signals 0.233, block RAM 0.094, MMCM 0.107, DSP 0.013, I/O 0.004 W. The whole-run energy includes boot, UART init and their 576-element check loop; it is not a per-layer figure.

**Same-method comparison, conv8_3 dynamic energy per layer (RTL-SAIF on both sides):** ATEE vl=16 15.95786 µJ against IISc 44.91572 µJ = 0.355285. ATEE vl=8 19.80546 µJ = 0.440947 of IISc. Caveats:
- the windows differ: our layer-busy window against their conv2d() call;
- the match shares are low and differ (3% against 8%);
- the method's bias is calibrated only for ATEE (+21–22%), not for IISc;
- IISc is evaluated at a 50 MHz clock its implementation does not meet.

Headline ratios rows 26–27.

### Calibration against the netlist-SAIF figures (ATEE)

| | RTL-SAIF dynamic | Netlist-SAIF dynamic ("Virtex-7 power (2026-11-14)") | Difference |
|---|---|---|---|
| ATEE vl=16 | 0.307 W | 0.252 W | **+21.8%** ((0.307 − 0.252) / 0.252 = 0.218254) |
| ATEE vl=8 | 0.291 W | 0.240 W | **+21.3%** (0.212500) |

**Reading.** The match shares are low: 3% of nets for ATEE, 8% for IISc. The rest of the activity is propagated from the matched nets. On ATEE this method overestimates dynamic power by about 21–22% against the netlist-SAIF reference (100% matched). By type, the excess is in signals (0.086 vs 0.056 W, vl=16), slice logic (0.043 vs 0.035 W) and DSP (0.015 vs <0.001 W); clocks and block RAM agree.

Why the match is low (from the SAIF and the reports):
- xsim writes the VHDL generate scopes as `GEN_ALUs\(0\)/alu_gen`, where the netlist has `GEN_ALUs[0].alu_gen`.
- VHDL array and record signals (the vector pipeline registers) are not written to the SAIF at all.
- Synthesized register and DSP names differ from the RTL signal names.

The vector units of both designs are VHDL. The IISc scalar core is Verilog, which is part of why its match share is higher. The RTL-SAIF bias for IISc has not been calibrated (no netlist-SAIF reference exists for it) and need not be +21%.

## Provenance audit

Added 2026-10-19. No number recorded elsewhere in this file was changed. Checkpoint figures below were read with `scripts/audit_lut_provenance.tcl` (new, read-only: opens routed checkpoints, writes nothing; log `synth_build/vivado_audit_lut.log`, Vivado 2019.1).

### The I2SRV32-V "scalar core" figure, 39,468 LUT

It is **one run minus one row of the same run**: section 2, row "Scalar + vector together, post-route" (86235), minus the row "of which `VECTOR_UNIT` (hierarchy row of the post-route report)" (46767). 86,235 − 46,767 = 39,468. It is NOT 86,235 minus the separate "Vector unit alone" run (43,625).

| Figure | LUT | Run | Top / scope | Stage | Script, date |
|---|---|---|---|---|---|
| cpu + vector | 86,235 | `synth_build/iisc_ooc_both/` | top `cpu`, out of context. Includes the scalar pipeline (integer, FPU, CSR, interrupts, branch predictor), I-cache + ITLB (`mh`), D-cache + bus interface (`db1`), and the vector unit with its 8 DMEM scratchpad banks and 16 `div_gen` instances. Excludes `mainMem` (main/instruction memory, 1 MB), UART, PWM, LED/switch logic and `clk_wiz_0`, which sit in `FPGA_WRAPPER`. IP wrappers: regenerated from their `.xci`; `xbip_dsp48_macro_1/_2` are our assumed-function stand-ins. | post-route | `scripts/synth_iisc_ooc.tcl -tclargs both`, synthesis started 2026-10-12, route finished 2026-10-13 13:40 |
| `VECTOR_UNIT` row | 46,767 | the same run, hierarchical utilization report row `fdem/Pipeline/VECTOR_UNIT` (confirmed in the checkpoint: `report_utilization -cells` gives 46767) | `vector_top` as instantiated inside `cpu` | post-route | same |
| scalar core | 39,468 | arithmetic on the two rows above | everything in `cpu` that is not `VECTOR_UNIT` | post-route (derived) | — |
| vector alone | 43,625 | `synth_build/iisc_ooc_vector/` | top `vector_top`, out of context, incl. 8 DMEM banks (120 block-RAM primitives, all under `DMEM*`) and 16 `div_gen` instances | post-route | `scripts/synth_iisc_ooc.tcl -tclargs vector`, 2026-10-12 (route finished 20:24) |
| scalar alone | 43,783 | `synth_build/iisc_ooc_scalar/` | top `cpu` with `vector_top` as a black box | post-SYNTHESIS only (cannot be implemented with a black box) | `scripts/synth_iisc_ooc.tcl -tclargs scalar`, 2026-10-12 |

Script note: the vector and scalar runs used the first version of `scripts/synth_iisc_ooc.tcl` (modes `vector|scalar`). Before the `both` run the file was accidentally emptied by a failed edit and rewritten in full with a third mode; the `vector` and `scalar` paths in the rewrite are the same logic. The file on disk is the rewritten one.

### Why 86,235 − 43,625 = 42,610 ≠ 39,468 (the 3,142 LUT)

The 3,142 is not a missing component. It is the difference between two measurements of the same `vector_top` RTL in two different implementation runs:

    46,767 (VECTOR_UNIT inside the cpu run) − 43,625 (vector_top alone) = 3,142
    86,235 − 46,767 = 39,468   (recorded; closes exactly)
    86,235 − 43,625 = 42,610   (mixes two runs)

Breakdown from the checkpoints (slice LUTs as reported by `report_utilization -cells`):

| | inside `cpu` run | `vector_top` alone run | difference |
|---|---|---|---|
| whole vector unit | 46,767 | 43,625 | 3,142 |
| `vector_top` own logic (outside `VEC_EXE_UNIT`) | 197 | 231 | −34 |
| `VEC_EXE_UNIT` (their `v_wrapper`) | 46,571 | 43,394 | 3,177 |
| the 16 divider IP instances | 19,097 | 19,073 | 24 |
| LUT primitives (each LUT cell counted once) | 51,001 | 47,782 | 3,219 |

So the same RTL produced about 3.1k more LUTs, almost all outside the dividers, when its ports were driven by the real scalar core than when its ports were free out-of-context ports. Why the implementation differs by that much was not investigated further.

Also: in the hierarchical report, instance rows do not sum exactly to their parent. In the `cpu` run the `Pipeline` children sum to 64,910 against the `Pipeline` row of 64,791. Slice-LUT rows count LUT sites, and one site can hold LUTs of two instances (reading of the metric, not separately proven). LUT primitive counts do sum exactly: 96,248 in total = 51,001 in `VECTOR_UNIT` + 45,247 outside it.

### Scope and stage parity with our out-of-context runs

All runs: Vivado 2019.1, xc7a200tfbg676-2, out of context, clock only, post-route (except "scalar alone").

| I2SRV32-V run | Our counterpart | Stage parity | Scope parity |
|---|---|---|---|
| `vector_top` alone, 43,625 | `v_wrapper`, 24,160 | yes, both post-route | Both include the 8 scratchpad banks (theirs 112 RAMB36 + 8 RAMB18 = 116 tiles; ours 128 tiles). Theirs also includes its 16 dividers (19,073 LUT) and a `vector_top` decode/interface layer (231 LUT). The module-level match to our `v_wrapper` is their `VEC_EXE_UNIT` row, 43,394. |
| `cpu` + vector, 86,235 | `atee_top`, 25,095 | yes, both post-route | Both exclude main memory and peripherals. Theirs carries a full scalar core with caches, FPU and branch predictor; ours carries the controller and configuration registers. |
| scalar core 39,468 (derived, in context) | ours in context: 25,095 − 23,880 = 1,215 | yes, both derived the same way from post-route runs | as above |
| scalar alone 43,783 | `hbm_lite_controller` 688 + `tensor_config_regs` 221 = 909 | NO: theirs is post-synthesis only | Theirs cannot be routed standalone (black box). Compare 39,468 with our in-context 1,215 instead. |

None of our runs needs redoing for parity.

### The 18 DSP48E1 in `hbm_lite_controller`

All 18 are in the controller's own address and loop-size arithmetic; none is in `outsize_div` (0 DSP under `u_outsize`). Cell names in the routed checkpoint:

- 12 from the per-instruction address expressions, `hbm_lite_controller.v` lines 190–199:
  - `comb_input_addr*`, 8 cells: `ic_cnt*input_plane_size`, `oh_cnt*stride`, `ow_cnt*stride`, `(...)*input_w`.
  - `comb_weight_addr1`, 1 cell: `tap_idx*output_c`.
  - `comb_output_addr*`, 3 cells: `oh_cnt*output_w`, `(...)*output_c`.
- 6 from the S_INIT2 layer-size products, lines 442, 443 and 469:
  - `input_plane_size0`, `input_plane_size0__0`, `input_plane_size_reg`: `input_h*input_w`.
  - `kernel_size0`: `kernel_h*kernel_w`.
  - `taps_total_reg` and `taps_left`: `input_c*kernel_size`, with the line-209 subtraction `taps_total - chunk_base` mapped onto the DSP.

The mapping of cell names to RTL lines is a reading of the names; Vivado does not report source lines for these cells.

## LUT decomposition

Inputs, all slice LUTs, Vivado 2019.1, xc7a200tfbg676-2, out of context, post-route, measured here:

| Input | Value | Source |
|---|---|---|
| I2SRV32-V `cpu` + vector, total | 86,235 | section 2, "Scalar + vector together" (`iisc_ooc_both`) |
| its `VECTOR_UNIT` | 46,767 | same run, hierarchy row |
| its 16 divider IP instances | 19,097 | same run, `report_utilization -cells` over the 16 `signed_divider` / `unsigned_divider` instances (`audit_lut_provenance.tcl`) |
| ATEE-Lite `atee_top`, total | 25,095 | "Out-of-context synthesis (method consistency)" (`atee_ooc_atee_top`) |
| its `u_vec_unit` | 23,880 | same run, hierarchy row (confirmed with `report_utilization -cells`) |

Arithmetic, one consistent pair of runs, each split by its own hierarchy:

    total difference                 86,235 − 25,095            = 61,140
    (1) scalar core -> controller    (86,235 − 46,767) − (25,095 − 23,880)
                                   =  39,468 − 1,215            = 38,253
    (2) dividers removed             19,097 − 0                 = 19,097
    (3) remainder, named below       (46,767 − 19,097) − 23,880 =  3,790
    check                            38,253 + 19,097 + 3,790    = 61,140

- (1) Their non-vector logic is the scalar core with FPU, caches, ITLB, branch predictor, CSR and interrupt logic. Ours is `u_hbm_lite` + `u_config` + 10 LUT of top-level glue.
  - *Correction note (2026-10-19):* the scalar core also contains a DATA TLB (`fdem/db1/dt1/dd/dtlb`, instantiated at `dcache_dpram.v:401`), whose replacement logic uses the same stand-ins. No number in this decomposition changes.
- (2) Our `ENABLE_DIV=0` build has no divider logic.
- (3) Non-divider vector-unit difference. It contains their `vector_top` decode/interface layer (197 LUT in this run), differences between their `v_wrapper` and ours (count_gen fix, DMEM implemented as `dmem_bram.vhd` instead of their `DMEM_n` IP), and run-to-run implementation effects.

How robust term (3) is: it depends on the pairing and the metric.

| Variant | Term (3) | Arithmetic |
|---|---|---|
| in-context, slice LUTs (above) | 3,790 | (46,767 − 19,097) − 23,880 |
| standalone runs, slice LUTs | 392 | (43,625 − 19,073) − 24,160 |
| in-context, LUT primitives | −16 | (51,001 − 24,811) − 26,206 |

With LUT primitives, terms (1) and (2) are 43,738 (45,247 − 1,509) and 24,811; the total is 68,533 = 96,248 − 27,715. Terms (1) and (2) are large in every variant. Term (3) ranges from −16 to 3,790 and should be quoted only with its variant.

## IISc timing with their own exceptions

Added 2026-10-19. **Status: NOT RUN.** Task 3 was stopped before implementation, because their exceptions as written match nothing in the out-of-context design. No timing, area or frequency number in this section comes from a new implementation run.

### Exceptions file

- `scripts/iisc_timing_exceptions.xdc` (new). Every ACTIVE `set_false_path` and `set_multicycle_path` line of `external/I2SRV32-V-v1-master/Source code/constraints/constraints.xdc`, copied verbatim; their file is unchanged. A check after writing found 0 lines differing from the source.
- Contents: 34 exceptions + 3 variable definitions. Source line numbers are recorded in the file's header.

| Kind | Count | Source lines | Notes |
|---|---|---|---|
| `set_false_path` from I-cache tag RAM clock pins | 1 | 1 | |
| `set_false_path` on `em1/Main` (main memory) | 4 | 3, 4, 7, 8 | |
| `set_false_path -setup` from `rst_reg/C` | 1 | 10 | |
| `set_multicycle_path -setup` through FPADD/FPMULT/FPDIV/FPSQRT, SP and DP | 8 | 12–19 | multipliers 4, 3, 3, 2, 15, 6, 12, 5 |
| `set_multicycle_path -hold` through the same 8 cells | 8 | 21–28 | |
| `set_false_path` from vector-unit DMEM / D-cache tag RAM clock pins | 12 | 96–99, 103, 104, 106, 107, 108, 110, 111, 112 | ACTIVE in their file. Targets: UART `wb_dat_is_reg`, D-cache data buffers, `DCache_Write_Data_w0_temp_reg`, bus-interface FSM and `bus_reg_reg` |
| `set _xlnx_shared_iN [get_pins ...]` (plain Tcl variables) | 3 | 102, 105, 109 | needed by lines 103, 106, 110 |
| commented-out `#set_multicycle_path` (vector DMEM, D-cache tags) | 6 | 89–94 | NOT copied; left disabled as in their file |

The earlier brief expected 24 exceptions (16 multicycle + 7 BRAM false paths + 1 reset). The file actually has 34 active exceptions. The difference is the 12 active false paths of lines 96–112. Their file is 113 lines including the final line break; `Get-Content` reports 112.

### Clock period

`clk_wiz_0` in their IP: `CLKOUT1_REQUESTED_OUT_FREQ` = 50.000 MHz (the core clock `clk`) and `CLKOUT2_REQUESTED_OUT_FREQ` = 100.000 MHz (`clk_x2`), from `PRIM_IN_FREQ` = 200.000 MHz. Source: `external/ip_xci/clk_wiz_0.xci`, extracted from their `Source code/IP/clk_wiz_0.xcix`. So the 20 ns period (and 10 ns for clk_x2) already used for their out-of-context runs matches their own configuration. The 50 MHz comparison assumption holds.

### Which exceptions match the out-of-context design

Script: `scripts/check_iisc_exceptions.tcl` (new, read-only; opens `synth_build/iisc_ooc_both/post_route.dcp`, top `cpu`; log `synth_build/vivado_check_iisc_exceptions.log`). An exception counts as matching only if every one of its `-from` / `-to` / `-through` lists is non-empty.

- **Verbatim: 0 of 34 match.** Every path in their file is written from their top `FPGA_WRAPPER` (`cpu1/...`, `em1/...`, `rst_reg`, `uart_snd/...`); in a run whose top is `cpu` none of these names exists. All three `_xlnx_shared` variables evaluate to 0 pins.
- Consequence: a run with the file applied verbatim would apply no exception, and its timing would be that of the existing run. It was not launched.
- **For information only, with the `cpu1/` prefix removed** (this rebases their constraints, which is an adjustment and is not used in any recorded run): 23 of 34 match.
  - All 16 FPU multicycle paths match (1 cell each).
  - 7 false paths match: line 1 (4 pins), lines 97, 98, 104, 103, 106 and 110 (the last three through the `_xlnx_shared` variables, 256 pins each).
  - 11 still match nothing:
    - the 4 `em1/Main` false paths — expected, `mainMem` is outside this scope;
    - `rst_reg/C` — `rst_reg` is in `FPGA_WRAPPER`;
    - lines 96, 99, 107, 108, 111 and 112, whose `-to` is in `uart_snd/...`, outside this scope.
- **What-if, ANALYSIS ONLY** (rebased exceptions applied in memory to the EXISTING routed placement, which was optimized without them; not a valid result):
  - WNS −44.738 ns (before −124.828 ns).
  - Worst path from `fdem/db1/dt1/dd/dtlb/cam/output_data_reg[4]` to `fdem/db1/dt1/drf0/DCache_Write_Data_w0_temp_reg[230]`, 64.695 ns, 42 logic levels.
  - WHS +0.059 ns.
  - Report: `synth_build/iisc_ooc_both/exceptions_check/whatif_rebased_timing_summary.rpt`.

### Re-rooted run, status (2026-10-20)

- **Run 1** (`synth_build/vivado_iisc_ooc_exceptions.log`, started 2026-10-19 22:40): did not finish. The match check passed (`IISC_EXC CHECK SUMMARY 23 of 23 active exceptions match`). The process was killed mid-routing when the session hosting it ended (no Vivado error, no crash file). Its last log line, at 2026-10-20 18:49, was in router "Phase 4.3 Global Iteration 2" with `Number of Nodes with overlaps = 5233`. The machine slept for part of the run (02:22–13:51 on 2026-10-20). Vivado CPU time last read at 19:04 was 57,225 s. No routed or placed checkpoint survived; no timing number exists from this run.
- **Run 2** relaunched 2026-10-20 19:16 with the same script and inputs, detached from the session. Log `synth_build/vivado_iisc_ooc_exceptions_run2.log`.
- **Deadline:** by decision, 2026-10-21 09:00. If routing has not completed by then it is stopped by `scripts/stop_iisc_route_at_deadline.ps1` (scheduled task), and the result is recorded here as non-convergence, with no constraint loosened.
- *Note (2026-10-20, later) — superseded by decision.*
  - **Run 1** was lost to a laptop crash at 18:49 on 2026-10-20, in routing pass 2 at 5,233 overlapping nodes, after about 16 CPU-hours (57,225 s at the last reading).
  - **Run 2** was started at 19:16. Stopping it was decided the same evening. When the decision was taken, its log had NOT reached routing: the last line was in `phys_opt_design` "Phase 5 Critical Cell Optimization", after `place_design` finished. So it has no routing pass or overlap count. *Correction (2026-11-11, from the final log):* that reading was taken before the stop; by the stop the run had entered `route_design`. The log's last write is 19:52:38, in router "Phase 3 Initial Routing", the first routing pass, with "Number of Unrouted Nets = 128942, Partially Routed Nets = 498, Node Overlaps = 782" as the last status printed. No rip-up pass had started, so there is still no pass-2 overlap count comparable with run 1's. Stopped by decision at 19:53:59 on 2026-10-20 by the user, PIDs 11820 (`cmd.exe`) and 10372 (`vivado.exe`); afterwards no Vivado process was running. The scheduled task `ATEE_IISc_route_deadline` was unregistered and `scripts/stop_iisc_route_at_deadline.ps1` deleted at the same time.
  - Neither run completed routing. No constraint was loosened. IISc timing on this stand-in is not pursued further (see CLAUDE.md "Decisions and open caveats").

### Needs a decision before Task 3 can be run

1. Rebase their exceptions onto top `cpu` (strip `cpu1/`) and re-implement. That is an adjustment of their constraints, so it was not done without approval.
2. Or implement with top `FPGA_WRAPPER`, where the paths are valid. That needs `mainMem`, which does not fit xc7a200t (section 2).

Area would not be expected to change with exceptions; it was not re-measured.

## Headline ratios (2026-10-19)

Every ratio below is computed from rows already recorded in this file; no new measurement. "Wording" is the phrase to use in the report and slides. Where a figure needs a qualifier, the qualifier is part of the wording.

| # | Ratio | Formula | Inputs (source row in this file) | Exact result | Wording |
|---|---|---|---|---|---|
| 1 | Cycles, conv8_3, ours vs IISc | 3,403 / 3,181 | 3,403: §1a, row "+ sequential output-size divider … LIVE"; 3,181: §1c, row "I2SRV32-V, their design, their conv8_3 program: conv2d() entry to return" | 1.069789 (ours 6.98% more cycles) | "within 7% of IISc's cycle count" |
| 2 | Control logic, IISc vs ours | 39,468 / 1,215 | 39,468: "Provenance audit", row "scalar core"; 1,215: "Provenance audit", parity table, "ours in context: 25,095 − 23,880 = 1,215" | 32.484 | "about 32x less control logic" |
| 3 | LUTs, out of context | 86,235 / 25,095 | 86,235: §2, "Scalar + vector together, post-route"; 25,095: "Out-of-context synthesis (method consistency)", row "`atee_top` post-route" | 3.4363 | "3.4x fewer LUTs" |
| 4 | Registers, out of context | 43,955 / 15,193 | 43,955: §2, same row as #3 (42,122 FF + 1,833 latches); 15,193: same row as #3 | 2.8931 | "2.9x fewer registers (their count includes 1,833 latches)" |
| 4b | Flip-flops only | 42,122 / 15,193 | same rows, FF part only | 2.7725 | "2.8x fewer flip-flops" |
| 5 | Ablation, original design to live | 157,251 / 3,403 | 157,251: §1a, row "Original design, vl=1, everything in DMEM bank 0"; 3,403: as #1 | 46.210 | "46x fewer cycles than the original design (which also included DMA loading)" |
| 6 | vs IISc scalar -O3 | 31,130 / 3,403 | 31,130: §1c, row "Spreadsheet decode, scalar -O3: 622.6 us x 50 cycles/us" (spreadsheet-unverified); 3,403: as #1 | 9.1478 | "about 9x fewer cycles than their published scalar figure (from their spreadsheet, unverified)" |
| 7a | Decomposition share: control replacement | 38,253 / 61,140 | "LUT decomposition", terms (1) and total | 0.625662 = 62.57% | "62.6% of the LUT difference" |
| 7b | Decomposition share: dividers removed | 19,097 / 61,140 | "LUT decomposition", term (2) | 0.312349 = 31.23% | "31.2%" |
| 7c | Decomposition share: residual | 3,790 / 61,140 | "LUT decomposition", term (3), in-context slice-LUT variant | 0.061989 = 6.20% | "6.2% residual (in-context slice-LUT variant)" |
| 8 | vl=16 projection vs IISc | (3,181 − 2,583) / 3,181 | 2,583: §1b, row "vl=16 … no ReLU" (projected); 3,181: as #1 | 0.187991 = 18.80% | "PROJECTED 18.8% fewer cycles" |
| 9 | IISc dynamic energy, indicative | 0.333 W × 3,181 × 20 ns | 0.333 W: §4, row "I2SRV32-V vector processor", dynamic (paper Table III/IV, Virtex-7 XC7VX485T); 3,181: as #1 | 21.18546 µJ | "about 21.2 µJ (indicative: paper power on Virtex-7 × our measured cycle count)" |
| 10 | Cycles, CONV2D 3x3 16x16, ours vs IISc (added 2026-11-11) | 18,123 / 15,033 | "CONV2D 3x3 at image sizes 8 / 16 / 32 / 64", rows 16x16 | 1.205548 (ours 20.55% more cycles) | "20.6% more cycles than IISc at 16x16" |
| 11 | Cycles, CONV2D 3x3 32x32, ours vs IISc | 82,891 / 67,009 | same section, rows 32x32 | 1.237013 (ours 23.70% more cycles) | "23.7% more cycles than IISc at 32x32" |
| 12 | Cycles, CONV2D 3x3 64x64, ours vs IISc | 353,739 / 284,140 | same section, rows 64x64 (IISc value identical in the original-stand-in and tied-to-0 runs) | 1.244946 (ours 24.49% more cycles) | "24.5% more cycles than IISc at 64x64" |
| 13 | Per-filter time vs Klessydra-T, 8 / 16 / 32 | (ours/16 × 20 ns) / Klessydra-T published µs | ours: same section; Klessydra-T: THEIRS-QUOTED (IISc Table VIII, from their ref. [3]), 120 MHz | 0.429238 / 1.069582 / 1.740238 | "per-filter equivalent: 0.43x / 1.07x / 1.74x Klessydra-T's published time (different clocks, quoted values)" |
| 14 | Per-filter time vs RI5Cy, 8 / 16 / 32 | (ours/16 × 20 ns) / RI5Cy published µs | ours: same section; RI5Cy: THEIRS-QUOTED (IISc Table VIII, from their ref. [3]), 91.4 MHz | 0.091557 / 0.137229 / 0.166088 | "per-filter equivalent: 0.09x / 0.14x / 0.17x RI5Cy's published time (quoted values)" |
| 15 | vl=16 controller, cycles vs IISc, 8 / 16 / 32 / 64 (added 2026-11-11, later) | 2,599 / 3,181; 13,799 / 15,033; 63,079 / 67,009; 269,159 / 284,140 | "vl=16 controller", results table; IISc: "CONV2D 3x3 at image sizes" (64x64 from the stand-ins-tied-to-0 run) | 0.817039 / 0.917914 / 0.941351 / 0.947276 | "vl=16: 18.3% / 8.2% / 5.9% / 5.3% fewer cycles than IISc at 8 / 16 / 32 / 64" |
| 16 | vl=16 vs vl=8, cycles, 8 / 16 / 32 / 64 | 2,599 / 3,403; 13,799 / 18,123; 63,079 / 82,891; 269,159 / 353,739 | "vl=16 controller"; "CONV2D 3x3 at image sizes" | 0.763738 / 0.761408 / 0.760987 / 0.760897 | "vl=16 takes about 24% fewer cycles than vl=8" |
| 17 | vl=16, control logic, IISc vs ours | 39,468 / 1,219 | "Provenance audit"; "vl=16 controller", synthesis | 32.377358 | "about 32x less control logic (vl=16 design)" |
| 18 | vl=16, LUTs out of context, IISc vs ours | 86,235 / 25,129 | §2; "vl=16 controller", synthesis | 3.431692 | "3.4x fewer LUTs (vl=16 design)" |
| 19 | vl=16, flip-flops, IISc vs ours | 42,122 / 15,212 | §2; "vl=16 controller", synthesis (0 latches) | 2.768998 | "2.8x fewer flip-flops (vl=16 design)" |
| 20 | vl=16 per-filter time vs Klessydra-T, 8 / 16 / 32 | (cycles/16 × 20 ns) / published µs: 3.24875/9.91, 17.24875/21.18, 78.84875/59.54 | "vl=16 controller"; Klessydra-T THEIRS-QUOTED (IISc Table VIII, from their ref. [3]) | 0.327825 / 0.814389 / 1.324299 | "vl=16 per-filter equivalent: 0.33x / 0.81x / 1.32x Klessydra-T's published time (quoted, different clock)" |
| 21 | vl=16 dynamic energy per layer vs IISc, INDICATIVE (added 2026-11-12) | 13.35886 µJ / 21.18546 µJ | 13.35886 = 0.257 W × 2,599 × 20 ns: "vl=16 power, full chip, SAIF", energy table; 21.18546: #9 | 0.630567 (vl=16 36.94% less) | "indicative: about 37% less dynamic energy per conv8_3 layer than IISc's published dynamic power × their measured cycles (different device and power method)" |
| 22 | Control logic on Virtex-7, IISc vs ours vl=16 (added 2026-11-13) | 39,425 / 1,102 | "Virtex-7 XC7VX485T, Vivado 2026.1", control-logic table | 35.775862 | "about 36x less control logic (vl=16, Virtex-7 full chip; theirs with their own constraints, ours clock-only)" |
| 23 | Control logic on Virtex-7, IISc vs ours vl=8 | 39,425 / 1,162 | same table | 33.928571 | "about 34x less control logic (vl=8, Virtex-7 full chip)" |
| 24 | LUTs on Virtex-7, IISc processor (`cpu1`, no main memory or peripherals) vs ours vl=16 full chip | 85,904 / 25,407 | same section, results and Table III split | 3.381115 | "3.4x fewer LUTs (vl=16, Virtex-7)" |
| 25 | LUTs on Virtex-7, IISc `cpu1` vs ours vl=8 full chip | 85,904 / 24,940 | same | 3.444427 | "3.4x fewer LUTs (vl=8, Virtex-7)" |
| 26 | RTL-SAIF dynamic energy per conv8_3 layer, ours vl=16 / IISc (added 2026-11-14) | 15.95786 µJ / 44.91572 µJ | "Virtex-7 power: RTL-SAIF method (all three designs)" | 0.355285 | "RTL-SAIF, same method both: about 64% less dynamic energy per conv8_3 layer than IISc (vl=16; low match shares, IISc at a nominal 50 MHz it does not meet)" |
| 27 | RTL-SAIF dynamic energy per conv8_3 layer, ours vl=8 / IISc | 19.80546 µJ / 44.91572 µJ | same | 0.440947 | "RTL-SAIF: about 56% less (vl=8), same caveats" |
| 28 | MAIN DESIGN (SC, added 2026-11-19). Control logic on Virtex-7, IISc vs SC | 39,425 / 2,163 | "Main design: scalar-operand variant (SC) …", item 1 | 18.226999 | "about 18x less control logic (SC, Virtex-7 full chip; theirs with their own constraints, ours clock-only)" |
| 29 | SC: LUTs on Virtex-7, IISc `cpu1` vs SC full chip | 85,904 / 25,419 | same item 1; Run 3 | 3.379519 | "3.4x fewer LUTs (SC, Virtex-7)" |
| 30 | SC: cycles, CONV2D 5x5 32x32 (32 filters) vs IISc | 162,276 / 297,549 | same section, item 3; "Paper benchmark rows, measured on their design" | 0.545376 | "45% fewer cycles than IISc on CONV2D 5x5 (layer-busy vs their function call)" |
| 31 | SC: cycles, MATMUL 16 / 32 / 64 vs IISc | 1,210 / 4,737; 9,006 / 20,993; 70,128 / 113,921 | same | 0.255436 / 0.429000 / 0.615584 | "74% / 57% / 38% fewer cycles than IISc (their MATMUL 32 program computes a wrong matrix)" |
| 32 | SC: per-filter time vs Klessydra-T, 3x3 8 / 16 / 32, 5x5 32, MATMUL 64 | SC µs / published µs (item 4 table) | item 4; Klessydra-T THEIRS-QUOTED (IISc Table VIII, from their ref. [3]), 120 MHz | 0.176337 / 0.427172 / 0.691426 / 0.902496 / 0.511631 | "per-filter equivalent below Klessydra-T's published time in every Table VIII column (quoted, different clock)" |
| 33 | SC: per-filter time vs RI5Cy, same columns | same | item 4; RI5Cy THEIRS-QUOTED, 91.4 MHz | 0.037613 / 0.054807 / 0.065989 / 0.051500 / 0.711598 | "per-filter equivalent below RI5Cy's published time in every column (quoted)" |
| 34 | SC vs vl=16, netlist-SAIF dynamic energy per conv8_3 layer, Virtex-7 | 6.57060 µJ / 13.09896 µJ | "Main design … item 2"; "Virtex-7 power (2026-11-14)" | 0.501612 | "netlist-SAIF: SC halves the dynamic energy per conv8_3 layer of the vl=16 design" |
| 35 | SC vs IISc, RTL-SAIF dynamic energy per cnn_demo image (inference) | 1,075.36508 µJ / 3,596.33232 µJ | "Main design … item 2", RTL-SAIF table | 0.299017 | "RTL-SAIF, same method both: about 70% less dynamic energy per cnn_demo image than IISc (low match shares 3% / 8%; IISc at a nominal 50 MHz it does not meet; IISc bias uncalibrated)" |
| 36 | SC vs IISc, RTL-SAIF dynamic energy per conv8_3 layer | 9.56232 µJ / 44.91572 µJ | same | 0.212895 | "RTL-SAIF: about 79% less per conv8_3 layer (same caveats; on conv8_3 the SC RTL-SAIF figure is itself +45.5% above netlist-SAIF)" |

Rows 10–14 caveats: cycle ratios use the same two windows as #1 (our layer-busy time vs their conv2d() call). Rows 13–14 divide a 16-filter run by 16 to compare with single-filter published times; that division is our construction, not a measurement of a single-filter run. Ours runs slower than IISc in cycles at every size, and the gap grows with size (#1, #10–#12). These rows are for the vl=8 controller. Rows 15–20 (added 2026-11-11, later) are for the vl=16 controller: it takes fewer cycles than IISc at every size, with the margin shrinking as size grows. #15 at 64x64 uses 284,140, identical in both IISc stand-in runs.

Check: 38,253 + 19,097 + 3,790 = 61,140; the three shares sum to 100.00%.

Caveats that go with these ratios:

- **#4.** 43,955 counts 1,833 latches as registers. Flip-flops alone give 2.77 (row 4b).
- **#5.** 157,251 used the archived DMA controller and is "not on the same footing" as the BRAM-only rows (§1a note). Its date in the records is 2026-10-03 (re-confirmed); no April date is recorded anywhere in this project, so "April to now" is not supported by this file.
- **#6.** 31,130 is 622.6 µs × 50. In the spreadsheet the scalar time cell H3 is `622.6/16` (= 1,946 cycles). Reading 622.6 µs as the whole 16-filter run is the same per-filter interpretation as the vector decode, which the sheet does not state. The figure also assumes their scalar run was at 50 MHz. The scalar version cannot be reproduced here.
- **#7c.** The residual depends on the pairing and metric: 3,790 (in-context, slice LUTs), 392 (standalone, slice LUTs: 0.64% of 61,140), −16 (in-context, LUT primitives). Quote it only with its variant.
- **#8.** 2,583 is a PROJECTION; no vl=16 controller exists. It is arithmetic on per-pixel counts measured BEFORE the sequential output-size divider (+16 cycles per layer). With the +16: 2,599, giving (3,181 − 2,599) / 3,181 = 0.182961 = 18.30%.
- **#9.** This mixes a published power figure (Virtex-7, method not stated) with a cycle count measured here on a different window definition. It is not comparable with our SAIF-based 16.471 µJ dynamic on the Artix-7 stand-in (§5); no ratio between the two is given.
  *Note 2026-11-12:* at the user's request, row #21 now gives such a ratio for the vl=16 design (0.630567), labelled INDICATIVE. Every caveat above applies to it: published Virtex-7 power with an unstated method, against SAIF on the Artix-7 stand-in, and different window definitions. No ratio is given for the vl=8 design.

## Data-TLB stand-in probe (2026-10-19)

Question: does the 3,181-cycle IISc baseline depend on the two stand-ins `xbip_dsp48_macro_1/_2`? Their repository does not ship them, and they sit in the replacement logic of BOTH TLBs. Only the instruction TLB had been probed before.

- **Testbench:** `external/iisc_sim/iisc_tb_dtlb.v`, a new copy of `iisc_tb.v` (unchanged). It keeps the ITLB probes and adds the same probes on `fdem/db1/dt1/dd/dtlb/d_replacement_algo`: miss, replacement write enable, EVA_en, update_EVA, EVA_addr changes, and the P outputs of the four stand-in instances.
- **Run script:** `scripts/run_iisc_baseline_dtlb.ps1 [-StandIn assumed|zero]`, a new copy of `run_iisc_baseline.ps1` (unchanged) with its own work directory.
- **Settings:** same program image, defines and substitutions as the 3,181 run.
- **Windows:** before conv2d / inside it (fetch of 0x9d0 to fetch of 0xe98) / after. Each count is cycles with the signal high, or cycles with a change.

| Signal | assumed stand-ins (A*B+C, (D+A)*B+C), as in the 3,181 run | stand-ins tied to 0 (`xbip_dsp48_macro_zero.v`) |
|---|---|---|
| conv2d entry -> return | **3,181 cycles** | **3,181 cycles** |
| reset release -> conv2d entry / -> main returns | 816 / 28,888 | 816 / 28,888 |
| err_count == 0 | YES (1 write, value 0) | YES (1 write, value 0) |
| ITLB miss / replacement we / EVA_en | 1\|0\|0 each | 1\|0\|0 each |
| ITLB update_EVA / EVA_addr changes | 0\|0\|6 / 1\|0\|0 | 0\|0\|6 / 1\|0\|0 |
| ITLB stand-in P changes | 1\|0\|18 | 1\|0\|0 |
| **DTLB miss** | 1\|**1**\|0 | 1\|**1**\|0 |
| **DTLB replacement we** | 1\|**1**\|0 | 1\|**1**\|0 |
| **DTLB EVA_en** | 1\|**1**\|0 | 1\|**1**\|0 |
| DTLB update_EVA | 0\|0\|8 | 0\|0\|8 |
| **DTLB EVA_addr changes** | 1\|**1**\|0 | 1\|**1**\|0 |
| DTLB stand-in P changes | 1\|0\|3 | 1\|0\|0 |

Source: measured here, xsim (Vivado 2019.1), behavioural simulation of their `FPGA_WRAPPER`.

Findings:

- The data TLB IS active inside the conv2d window: 1 miss, 1 replacement write, 1 EVA_en cycle and 1 EVA_addr change.
- No stand-in output changed inside the window, and update_EVA was 0 there.
- Because there was activity, the sensitivity test was run. With every stand-in output tied to 0 the conv2d count is unchanged (3,181), err_count is 0, and every other count except the stand-in outputs themselves is identical.
- Conclusion: the 3,181-cycle baseline does not depend on the stand-ins, for these two functions. This is shown for two different assumed functions, not proven for every possible function of the original IP.
- The "1" in the before-conv2d stand-in column is the first transition after reset.

## CONV2D 3x3 at image sizes 8 / 16 / 32 / 64 (2026-11-11)

Their own benchmark programs `benchmarks/benchmarks/conv/conv{8,16,32,64}_3`, run on BOTH designs.

### Benchmarks (read from their files)

| Program | Input | Kernel | Filters (`N_FILT_LAYER1`) | Outputs | Expected-output file |
|---|---|---|---|---|---|
| conv8_3 | 8x8 | 3x3 | 16 | 576 (6x6x16) | `app/c/expected_output.c` |
| conv16_3 | 16x16 | 3x3 | 16 | 3,136 (14x14x16) | same file name |
| conv32_3 | 32x32 | 3x3 | 16 | 14,400 (30x30x16) | same file name |
| conv64_3 | 64x64 | 3x3 | 16 | 61,504 (62x62x16) | same file name |

- `main.c`, `app/asm/conv2d.S`, `app/c/ker.c` and `app/c/bias.c` are byte-identical across the four programs. Only `IMG_SIZE`, the image and the memory images differ.
- The kernel is `ker[tap*16+f] = tap+1`: all 16 filters are identical. The bias is all zero.
- Code addresses are the same at every size: conv2d 0x9d0, return 0xe98, final loop 0xec.
- Python reference (`scripts/gen_conv_sizes.py`) vs THEIR `expected_output[]`: 576/576, 3,136/3,136, 14,400/14,400 and 61,504/61,504 exact, max |diff| 0 at every size. The 8x8 files it writes are identical to the recorded `testbench/test1_*.hex`.

### IISc design (their FPGA_WRAPPER, their program; behavioural xsim, Vivado 2019.1)

Same method, substitutions and defines as the 3,181-cycle conv8_3 baseline. Script `scripts/run_iisc_conv_sizes.ps1 -Size S [-StandIn assumed|zero]`, testbench `external/iisc_sim/iisc_tb_conv.v` (new copies; the originals are unchanged). Logs in `sim_build/iisc_conv_logs/`.

| Size | Boot (reset -> conv2d entry) | conv2d entry -> return | Reset -> conv2d return | Reset -> main returns | err_count | Y exact vs THEIR expected | Y exact vs Python ref | Max \|diff\| |
|---|---|---|---|---|---|---|---|---|
| 8x8 | 816 | **3,181** | 3,997 | 28,888 | 0 | 576 / 576 | 576 / 576 | 0 |
| 16x16 | 816 | **15,033** | 15,849 | 153,957 | 0 | 3,136 / 3,136 | 3,136 / 3,136 | 0 |
| 32x32 | 816 | **67,009** | 67,825 | 701,549 | 0 | 14,400 / 14,400 | 14,400 / 14,400 | 0 |
| 64x64 | 816 | **284,140** | 284,956 | 2,991,271 | 0 | 61,504 / 61,504 | 61,504 / 61,504 | 0 |

- **Exactness method.** After conv2d returns, main()'s check loop reads `Y[i]` and `expected_output[i]` over the vector unit's processor interface. The testbench records `proc_dout` against the address presented L = 0..3 cycles earlier. L is calibrated on the `expected_output[]` reads, whose values are known: at L = 1 every read reproduces the file (576 / 3,136 / 14,400 of each); L = 0, 2, 3 do not. Their Y values captured at L = 1 are reported above.
- **Their own check** allows ±10 (`err_limit = 10` in `main.c`). The capture shows their outputs are EXACT at 8, 16 and 32, so the tolerance is never used.
- **64x64 status (completed 2026-11-11 19:18).** The 64x64 row is the run with the ORIGINAL assumed stand-ins (sim_build/iisc_conv_logs/iisc_conv64_assumed.txt), with calibration L=1 reproducing 61,504/61,504 expected_output[] reads. The stand-ins-tied-to-0 run gives the same conv2d count, 284,140 (reached conv2d return at cycle 284,956, as before its 17:22 interruption); its main-return, err_count and exactness were still running when this was recorded. *Note (2026-11-11 19:37): the tied-to-0 run has completed: 816 / 284,140 / 284,956 / 2,991,271 cycles, err_count 0, Y 61,504/61,504 exact (L=1, 61,504/61,504 calibration reads), identical to the original-stand-in run.*
- **Stand-in check.** Cycles with the signal high or with a change, before conv2d | inside conv2d | after:

| Size | ITLB update_EVA | ITLB stand-in output changes | DTLB miss / replacement we | DTLB stand-in output changes | Same counts with stand-ins tied to 0? |
|---|---|---|---|---|---|
| 8x8 | 0 \| 0 \| 6 | 1 \| 0 \| 18 | 1 \| 1 \| 0 each | 1 \| 0 \| 3 | yes ("Data-TLB stand-in probe") |
| 16x16 | 0 \| 1 \| 34 | 1 \| 3 \| 125 | 1 \| 1 \| 0 each | 1 \| 0 \| 22 | yes: 816 / 15,033 / 153,957, err_count 0, Y 3,136/3,136 exact |
| 32x32 | 0 \| 5 \| 155 | 1 \| 15 \| 617 | 1 \| 1 \| 0 each | 1 \| 0 \| 120 | yes: 816 / 67,009 / 701,549, err_count 0, Y 14,400/14,400 exact |
| 64x64 | 0 \| 68 \| 661 | 1 \| 88 \| 2,644 | 1 \| 4 \| 0 each | 1 \| 17 \| 553 | yes: 816 / 284,140 / 2,991,271, err_count 0, Y 61,504/61,504 exact (tied-to-0 run completed 19:37) |

  At 16 and 32 the stand-in outputs DO change inside the conv2d window, so the sensitivity runs were required. The cycle counts and outputs are identical with the stand-ins tied to 0.

### ATEE-Lite (live vl=8 controller, no ReLU, EARLY_CLEAR default, BRAM-only, no DMA)

Built from THEIR input image and kernel (`scripts/gen_conv_sizes.py`), same layout as conv8_3 (input replicated 8x, weights and outputs OC-innermost). Script `scripts/run_conv_sizes.ps1 -Size S [-Distinct]`, testbench `testbench/atee_conv_sizes_tb.v` (new). Memory layout for every size: input at 0x100000, weights at 0x120000, output at 0x121000.

| Size | Layer-busy cycles | Bit-exact vs Python ref | Bit-exact vs THEIR expected | DMEM used |
|---|---|---|---|---|
| 8x8 | **3,403** | 576 / 576 | 576 / 576 | 4,928 B = 4.8125 KB of 512 KB (0.94%) |
| 16x16 | **18,123** | 3,136 / 3,136 | 3,136 / 3,136 | 21,312 B = 20.8125 KB (4.06%) |
| 32x32 | **82,891** | 14,400 / 14,400 | 14,400 / 14,400 | 90,944 B = 88.8125 KB (17.35%) |
| 64x64 | **353,739** | 61,504 / 61,504 | 61,504 / 61,504 | 377,664 B = 368.8125 KB (72.03%) |
| 16x16, distinct mixed-sign weights `w[tap][oc] = 3*oc + tap - 19` | 18,123 | 3,136 / 3,136 | n/a | 21,312 B |

- Max |diff| is 0 in every row. Every size fits; none was skipped.
- The 8x8 run reproduces the recorded 3,403 with the relocated memory layout.
- Cycle model: every count equals (output pixels × 2 OC groups × 46) + 91, where 91 = 72 weight preload + 3 init + 16 output-size divider. For example 3,844 × 2 × 46 + 91 = 353,739.

### Their Table VII, per-filter reading (CONV2D-3x3 vector cycles 250 / 991 / 4,238 / 17,750)

Reading tested: 16 × table value − measured boot cycles = measured conv2d cycles.

| Size | Table VII value (paper; = spreadsheet CONV2D cells F3–F6) | 16 × value − 816 | Measured conv2d | Measured − predicted |
|---|---|---|---|---|
| 8x8 | 250 | 3,184 | 3,181 | −3 (−0.094%) |
| 16x16 | 991 | 15,040 | 15,033 | −7 (−0.047%) |
| 32x32 | 4,238 | 66,992 | 67,009 | +17 (+0.025%) |
| 64x64 | 17,750 | 283,184 | 284,140 | +956 (+0.338%) |

The reading holds at every size to within 0.34%. Equivalently, 16 × table value is within 0.34% of reset → conv2d return (4,000 vs 3,997; 15,856 vs 15,849; 67,808 vs 67,825; 284,000 vs 284,956). Our reading: their Table VII value is the full program's reset → conv2d-return time (boot included) divided by the 16 filters. The table does not say this; the arithmetic is consistent with it.

### Their Table VIII, per-filter equivalents (single-filter conv 3x3)

Per-filter equivalent = 16-filter cycles / 16; time at 50 MHz = cycles × 20 ns. Klessydra-T and RI5Cy are THEIRS-QUOTED from IISc's Table VIII, originally from their ref. [3], at their own clocks.

| Size | Ours: cycles / 16 | Ours µs | IISc conv2d / 16 | IISc µs | IISc (reset -> return) / 16 | IISc µs | IISc published | Klessydra-T published (120 MHz) | RI5Cy published (91.4 MHz) |
|---|---|---|---|---|---|---|---|---|---|
| 8x8 | 212.6875 | 4.25375 | 198.8125 | 3.97625 | 249.8125 | 4.99625 | 4.99 | 9.91 | 46.46 |
| 16x16 | 1,132.6875 | 22.65375 | 939.5625 | 18.79125 | 990.5625 | 19.81125 | 19.81 | 21.18 | 165.08 |
| 32x32 | 5,180.6875 | 103.61375 | 4,188.0625 | 83.76125 | 4,239.0625 | 84.78125 | 84.75 | 59.54 | 623.85 |

- IISc's published values match (reset → conv2d return) / 16 at 50 MHz to within 0.04 µs, i.e. they include boot. Their conv2d call alone, per filter, is 0.80 / 0.95 / 0.99 of the published value at 8 / 16 / 32.
- These are 16-filter runs divided by 16, not single-filter runs: a real single-filter program would not amortise the weight preload (ours) or the setup (theirs) the same way. No single-filter program was run on either design.
- Ours is faster than Klessydra-T's published time at 8x8 and slower at 16x16 and 32x32 (ratios in "Headline ratios", rows 13–14).

## Comparison ledger (2026-11-11)

One row per comparison with IISc or other work. Basis: MEASURED-BOTH | OURS-MEASURED/THEIRS-QUOTED | PROJECTED | NOT-DONE. Section names refer to this file. All our hardware figures are Vivado 2019.1 on the Artix-7 xc7a200tfbg676-2 stand-in unless stated.

| Comparison | Ours (value + source row) | Theirs (value + source) | Basis | Assumptions | Caveats | Status |
|---|---|---|---|---|---|---|
| Cycles, conv8_3 (8x8, 3x3, 16 filters) | 3,403 (§1a, live row) | 3,181 (§1c, their design simulated here) | MEASURED-BOTH | same program data; their simulation uses behavioural IP models | different windows: our layer-busy vs their conv2d() call; stand-ins shown not to matter | done; ratio 1.0698 ("Headline ratios" #1) |
| Cycles, CONV2D 3x3 16x16 | 18,123 ("CONV2D 3x3 at image sizes", ATEE table) | 15,033 (same section, IISc table) | MEASURED-BOTH | as above | as above | done; 1.2055 (#10) |
| Cycles, CONV2D 3x3 32x32 | 82,891 (same) | 67,009 (same) | MEASURED-BOTH | as above | as above | done; 1.2370 (#11) |
| Cycles, CONV2D 3x3 64x64 | 353,739 (same) | 284,140 (same; original stand-ins, identical with stand-ins tied to 0) | MEASURED-BOTH | as above | as above | done; 1.2449 (#12) |
| Output exactness, CONV2D 3x3 8/16/32/64 | bit-exact n/n at every size (same section) | exact n/n at 8/16/32/64 (their Y captured in their own check loop) | MEASURED-BOTH | read latency calibrated on known expected_output[] reads | their check tolerates ±10; exactness is our measurement | done |
| LUTs, compute blocks out of context | 25,095 ("Out-of-context synthesis", atee_top post-route) | 86,235 (§2, "Scalar + vector together", post-route) | MEASURED-BOTH | same tool, part, stage, clocks | stand-in part; their TLB stand-ins; ours ENABLE_DIV=0 | done; 3.4363 (#3) |
| Control logic | 1,215 ("Provenance audit", in-context subtraction) | 39,468 (same section, in-context subtraction) | MEASURED-BOTH | both = total − vector-unit row of the same run | slice-LUT rows overlap slightly; decomposition residual is variant-dependent | done; 32.484 (#2) |
| Flip-flops | 15,193 FF, 0 latches (out-of-context atee_top) | 42,122 FF + 1,833 latches = 43,955 registers (§2) | MEASURED-BOTH | | quote 2.77 for flip-flops alone; 2.89 counts their latches | done (#4, #4b) |
| Block RAM / DSP | 128 tiles / 63 DSP (out-of-context atee_top) | 143 tiles / 80 DSP (§2, cpu + vector) | MEASURED-BOTH | neither includes main memory | their caches included; opt_design removed their branch-predictor RAMs; our 18 DSP are controller address arithmetic | done; no ratio recorded |
| Clock frequency | 51.66 MHz out of context, 50.64 MHz full chip, timing met ("Out-of-context synthesis"; §3) | 50 MHz = their clk_wiz_0 configuration (§"IISc timing with their own exceptions"); our implementation of their cpu without exceptions: 6.90 MHz, not their frequency | OURS-MEASURED/THEIRS-QUOTED | | their timing with their exceptions did NOT converge on the stand-in; no frequency claim against IISc | not replicated; deferred to the Virtex-7 run |
| Dynamic power | 0.242 W SAIF, conv8_3, Artix-7 stand-in (§4) | 333 mW dynamic, vector processor (paper Table III/IV, Virtex-7 XC7VX485T, measured on their CNN) | OURS-MEASURED/THEIRS-QUOTED | | different device, workload and method | not comparable as is; no ratio |
| Energy per layer, conv8_3 | 16.471 µJ dynamic / 25.795 µJ total (§5) | 21.18546 µJ indicative = 0.333 W × 3,181 × 20 ns (#9) | OURS-MEASURED/THEIRS-QUOTED | their power applied to our measurement of their cycles | mixes device, workload and method | indicative only; no ratio |
| IISc scalar, conv8_3 | 3,403 (§1a) | 31,130 = 622.6 µs × 50 (spreadsheet CONV2D H3 without its /16; spreadsheet-unverified) | OURS-MEASURED/THEIRS-QUOTED | 50 MHz scalar clock; /16 interpretation | no scalar source in their repo; cannot reproduce | quoted only; 9.1478 (#6) |
| vl=16 design point vs IISc, conv8_3 | 2,583 PROJECTED (§1b) | 3,181 (§1c) | PROJECTED | per-pixel counts measured in isolation | no vl=16 controller; predates the +16 divider (2,599 with it) | projection only (#8). *Superseded 2026-11-11: the vl=16 controller was built and measured 2,599, see the next row.* |
| vl=16 controller, cycles vs IISc, CONV2D 3x3 8 / 16 / 32 / 64 (added 2026-11-11, later) | 2,599 / 13,799 / 63,079 / 269,159 ("vl=16 controller", results) | 3,181 / 15,033 / 67,009 / 284,140 ("CONV2D 3x3 at image sizes") | MEASURED-BOTH | same windows as the vl=8 rows | 64x64 IISc value confirmed by the original-stand-in run | done; 0.8170 / 0.9179 / 0.9414 / 0.9473 ("Headline ratios" #15) |
| vl=16 controller, LUTs / control logic / flip-flops | 25,129 / 1,219 / 15,212 ("vl=16 controller", synthesis, out of context, post-route) | 86,235 / 39,468 / 42,122 (§2; "Provenance audit") | MEASURED-BOTH | same tool, part, method | stand-in part | done (#17–#19) |
| vl=16 controller, dynamic power and energy per layer, conv8_3 (added 2026-11-12) | 0.257 W dynamic / 0.394 W total, SAIF, High confidence, 49% nets matched; 13.35886 µJ dynamic / 20.48012 µJ total per layer; full chip, timing met (WNS +0.312 ns) ("vl=16 power, full chip, SAIF") | 333 mW dynamic (paper Table III/IV, Virtex-7, their CNN); indicative energy 21.18546 µJ = 0.333 W × 3,181 × 20 ns (#9) | OURS-MEASURED/THEIRS-QUOTED | their power applied to our measurement of their cycles | different device, workload and power method; INDICATIVE | indicative ratio 0.630567 ("Headline ratios" #21) |
| vl=16 controller, clock | 51.04 MHz, timing met ("vl=16 controller", synthesis) | as in the clock-frequency row above | OURS-MEASURED/THEIRS-QUOTED | | no frequency claim against IISc | ours met; theirs not replicated |
| Table VII: CONV2D 3x3, 8 / 16 / 32 / 64 | 3,403 / 18,123 / 82,891 / 353,739 | 250 / 991 / 4,238 / 17,750 per filter (paper Table VII = spreadsheet F3–F6); measured here: 3,181 / 15,033 / 67,009 / 284,140 | MEASURED-BOTH (the measured columns); the table values are THEIRS-QUOTED | per-filter reading verified within 0.34% ("CONV2D 3x3 at image sizes") | | done |
| Table VIII: single-filter 3x3, 8 / 16 / 32, vs IISc, Klessydra-T, RI5Cy | per-filter equivalents 4.25375 / 22.65375 / 103.61375 µs ("CONV2D 3x3 at image sizes", Table VIII part) | IISc 4.99 / 19.81 / 84.75 µs; Klessydra-T 9.91 / 21.18 / 59.54 µs (120 MHz); RI5Cy 46.46 / 165.08 / 623.85 µs (91.4 MHz), all quoted from IISc Table VIII (Klessydra-T and RI5Cy from their ref. [3]) | OURS-MEASURED/THEIRS-QUOTED | 16-filter run / 16 = per-filter equivalent | no single-filter program run on either design; different clocks for the quoted cores | done as equivalents (#13, #14) |
| Table VIII: CONV2D 5x5, 32x32 | — | IISc 185.8; Klessydra-T 112.38 (120 MHz); RI5Cy 1,969.37 (91.4 MHz); paper Table VIII, column header `Execution Time (MS)` | NOT-DONE | | 25 taps exceed the vl=8 controller's 16-tap limit (and the vl=16 limit of 9) | not done |
| Table VIII: MATMUL 64x64 | — | IISc 2,275.71; Klessydra-T 2,741.35; RI5Cy 1,971; same table and header | NOT-DONE | | matrix multiplication is not supported by our controller | not done |
| Table IX: MNIST MLP (32-16-10, ReLU, Q8.24) | — | vector 345, scalar 14,045, speed-up 40.71x, energy improvement 33x; paper Table IX, column header printed as `Texe (Ms)` | NOT-DONE | | MLP / fully-connected layers are not supported by our controller | not done |
| Table IX: MNIST 6-layer CNN (Q8.24) | — | vector 4,813, scalar 93,999.557, speed-up 19.53x, energy improvement 16x; same table and header | NOT-DONE | | our controller runs single conv layers only (no pooling, no FC, no bias); only conv1 without bias has been run (§1b) | not done |
| Other Table VII kernels (AXPY, Perceptron, MATMUL at vl 8–64) | — | paper Table VII (printed values match the spreadsheet SAXPY/Perceptron/MATMUL sheets) | NOT-DONE | | our controller implements only convolution layers | not planned |
| Clock / timing at 50 MHz on Virtex-7 XC7VX485T, Vivado 2026.1 (added 2026-11-13; supersedes the "deferred to the Virtex-7 run" status of the clock-frequency row above) | vl=16 +1.810 ns MET (54.98 MHz); vl=8 +2.723 ns MET (57.88 MHz); full chip, clock-only ("Virtex-7 XC7VX485T, Vivado 2026.1") | their FPGA_WRAPPER with their constraints.xdc as written, 34/34 exceptions matching: core clock −6.193 ns NOT MET, 3,748 failing endpoints (38.18 MHz derived); clk_x2 +5.185 ns met (same section). Their paper claims about +0.4 ns at 50 MHz (user's reading of the paper) | MEASURED-BOTH | same part, tool and stages; theirs with their own constraints and pins, ours clock-only | their stand-ins xbip_dsp48_macro_1/_2; 2026.1 IP upgrade (EN_SAFETY_CKT on 6 memories); the cause of the gap to their claim is not determined | done; frequency claim against IISc still needs care: their timing is not met as built here |
| Area on Virtex-7, Table III split (added 2026-11-13) | vl=16 25,407 LUT / 15,166 FF / 128 BRAM / 61 DSP; vl=8 24,940 / 15,145 / 128 / 61 (same section) | measured here: vector 46,479 / 22,098 / 116 / 44; scalar 39,425 / 21,700 / 27 / 32; memory + peripherals + I/O 1,355 / 475 / 256 / 0; total 87,259 / 44,273 / 399 / 76. Their Table III: 35,737 / 19,896 / 32 / 43; 41,996 / 22,032 / 27 / 24; 1,201 / 470 / 256 / 0 | MEASURED-BOTH (the measured columns); Table III THEIRS-QUOTED | split by hierarchy subtraction as described in the section | vector and scalar rows differ from their Table III; the cause is not determined | done; ratios "Headline ratios" #24, #25 |
| Control logic on Virtex-7 (added 2026-11-13) | 1,102 (vl=16), 1,162 (vl=8), total − `u_vec_unit` | 39,425 = `cpu1` − `VECTOR_UNIT` | MEASURED-BOTH | same subtraction method as "Provenance audit" | ours clock-only, theirs with their constraints | done; 35.776 / 33.929 ("Headline ratios" #22, #23) |
| Power on Virtex-7, conv8_3 (added 2026-11-14) | vl=16 0.504 W total / 0.252 W dynamic; vl=8 0.491 / 0.240 W; 100% nets matched ("Virtex-7 power (2026-11-14)") | not obtained: their routed netlist cannot be simulated (2026.1 IP encryption unreadable by 2019.1; 2026.1 BASIC limit 50,000 instances); paper Table IV 597 / 333 / 264 mW is on their CNN | OURS-MEASURED/THEIRS-QUOTED | hybrid flow (2019.1 xsim, 2026.1 netlist and report_power), validated on Artix-7 within 3.1% | their published figure is a different workload | ours done; theirs BLOCKED; no ratio |
| Energy per layer on Virtex-7, conv8_3 (added 2026-11-14) | vl=16 13.09896 µJ dynamic / 26.19792 µJ total; vl=8 16.33440 / 33.41746 µJ (same section) | none measured (blocked as above) | NOT-DONE (theirs) | layer-busy window | static power is the XC7VX485T's (0.251 W) | ours done; no ratio |
| EXPERIMENT: IISc at the paper's 128 KB scratchpad, Virtex-7 (added 2026-11-14) | — | vector 45,351 LUT / 32 BRAM tiles; core-clock WNS −6.393 ns, 7,001 failing ("Paper-configuration experiment"); paper: 35,737 LUT / 32 BRAM, about +0.4 ns | MEASURED (theirs, modified copy) vs THEIRS-QUOTED | DMEM 4096 deep, VMEM_ADDR_WIDTH 12; their constraints as written | experiment on a modified copy; does not replace Run 3 | BRAM now matches their Table III; LUT and slack gaps remain, cause not determined |
| EXPERIMENT: ATEE vl=16 at 128 KB scratchpad, Virtex-7 | not run (stopped at START: laptop on battery) | — | NOT-DONE | | | pending, relaunch on mains power. *Update 2026-11-14 20:47: run done, see the next row.* |
| EXPERIMENT: ATEE vl=16 at 128 KB scratchpad, Virtex-7 (result) | 24,617 LUT / 15,068 FF / 32 BRAM / 58 DSP; WNS +3.091 ns, 59.14 MHz ("Paper-configuration experiment", ATEE RESULT) | IISc at 128 KB: WNS −6.393 ns (same section) | MEASURED-BOTH (both modified copies) | same flow as Runs 1 / 3 | experiment; does not replace Runs 1–3 | done |
| Power, RTL-SAIF method, Virtex-7, conv8_3 (added 2026-11-14) | vl=16 0.559 W total / 0.307 W dynamic; vl=8 0.543 / 0.291 W ("Virtex-7 power: RTL-SAIF method") | conv2d() window 0.975 / 0.706 W; whole run 0.968 / 0.698 W (same section) | MEASURED-BOTH (RTL-SAIF) | 2026.1 RTL simulation, read_saif onto the routed V7 checkpoints, nominal 50 MHz | nets matched 3% (ours) / 8% (theirs); ATEE calibration +21.8% / +21.3% vs netlist-SAIF; IISc bias uncalibrated; IISc fails 50 MHz | done |
| Energy per layer, RTL-SAIF, conv8_3 | vl=16 15.95786 µJ dynamic / 29.05682 total; vl=8 19.80546 / 36.95658 | 44.91572 µJ dynamic / 62.02950 total (conv2d window) | MEASURED-BOTH (RTL-SAIF) | different windows (layer busy vs conv2d call) | as the row above | done; 0.355285 / 0.440947 ("Headline ratios" #26, #27) |
| Table VII AXPY 8/16/32/64 (added 2026-11-15) | not built (our controller runs convolution layers only) | measured on their design: saxpy entry→return 119 / 127 / 143 / 176 cycles; published 48 / 56 / 72 / 104 = vl + 40 ("Paper benchmark rows, measured on their design") | THEIRS-MEASURED-HERE vs THEIRS-QUOTED; ours NOT-DONE | same windows as conv8_3 | published values match no measured window | IISc side done; no ratio |
| Table VII Perceptron 8/16/32/64 (added 2026-11-15) | not built | measured: 438 / 593 / 903 / 1,523 (entry→return), exact only with data RELOCATED; published 3,142 / 3,662 / 5,087 / 6,782 (same section) | as above | programs linked for the pre-2021 0x40000 map | not explained | IISc side done; no ratio |
| Table VII MATMUL 8/16/32/64; Table VIII MATMUL 64 (added 2026-11-15) | PROJECTED 406 / 3,007 / 22,047 / 173,635 (vl=8) and 639 / 2,379 / 16,907 / 139,251 (vl=16), as 1x1 convolution with chunked taps (`docs/chunked_taps_design.md`) | measured: 1,393 / 4,737 / 20,993 / 113,921 (entry→return); matmul32 output WRONG on their design (16/1,024) | PROJECTED (ours) vs THEIRS-MEASURED-HERE | | projection only; no ratio may be quoted | IISc side done; ours not built |
| Table VIII CONV2D 5x5 32x32 (added 2026-11-15; supersedes the NOT-DONE row above for the IISc side) | PROJECTED 420,667 (vl=8) / 329,659 (vl=16), 32 filters, chunked taps | measured: conv2d_5 entry→return 297,549 cycles, 25,088/25,088 exact; /32 = 9,298.41 vs published 9,290 (+0.09%) | PROJECTED vs THEIRS-MEASURED-HERE | | projection only | IISc side done |
| Table IX CNN (added 2026-11-15; supersedes the NOT-DONE row above for the IISc side) | layers 1 / FC fit the model; layer 2 (144 taps) needs chunking; full network not built (`docs/chunked_taps_design.md` §6) | measured: inference 241,689 cycles = 4,833.78 µs (+0.43% vs 4,813 µs); 87/100 of their shipped images classified correctly (all 13 misses labelled 8/9; FC outputs 8–9 hold only the bias) ("Paper benchmark rows, measured on their design", cnn_demo) | PROJECTED (ours, per layer) vs THEIRS-MEASURED-HERE | Q8.24 as their program | | IISc side done; ours not built |
| Table IX MLP (added 2026-11-15) | not built | NOT RUNNABLE: no program in their repo | NOT-DONE | | | cannot be replicated from their repo |
| cnn_demo final-layer defect on their design (added 2026-11-16) | — | layer3 at vl = 10: slots 3–7 lose elements 8–9 (`vrf_bank` write gate uses slot i's counter); minimal test on their design exact against the prediction at vl 8/10/11/12/16; vl ≤ 8 and 16 correct ("cnn_demo verification …", A.2) | THEIRS-MEASURED-HERE | their compiled layer3, patched main only | vl = 9 shows an extra, unexplained corruption; "as released" label pending A.1 / A.3 | A.2 done |
| cnn_demo 87/100 "as released" (added 2026-11-17) | — | 87/100 shipped images correct on their design; all 13 misses labels 8/9 (vl = 10 hazard, A.2); identical on all 100 under a second stand-in function (A.1); UART path gives identical outputs for image 7 (A.3) ("cnn_demo verification …", A.1 conclusion) | THEIRS-MEASURED-HERE | images preloaded (UART path checked on one image); stand-ins for 2 missing DSP macros, shown not to matter | cycles differ by input path (−1,524 on image 7); vl = 9 anomaly open | done; supersedes the "pending A.1 / A.3" note in the row above |
| IISc V7 timing WITHOUT their exceptions (added 2026-11-17) | — | core clock WNS -73.335 ns (10.71 MHz derived), 32,138 failing endpoints, 87,814 LUT; worst path DMEM6 -> scalar FPU ("E: LUT decomposition …", optional run) | THEIRS-MEASURED-HERE | their constraints.xdc with the 34 exceptions commented out | reference only; their timing is quoted WITH exceptions (Run 3, -6.193 ns) | done |
| cnn_demo on ATEE-Lite, whole network (added 2026-11-17) | 303,601 cycles per image (59,401 / 232,495 / 11,705), one start, no host action between layers; layers 1–2 bit-exact vs THEIR outputs and FC bit-exact vs reference on 100/100; 99/100 correct ("cnn_demo on ATEE-Lite …", G) | 241,689 (56,052 / 175,674 / 9,883 + 80), 87/100 correct (B, A.1) | MEASURED-BOTH | windows differ: our controller's layer-busy vs their software function windows; both exclude the image load | ATEE is 1.256× their cycles on schedule B (slower on every layer); F projects 0.630× (PROJECTION, not built) | done |
| Scalar-operand variant (SC), cnn_demo (added 2026-11-18) | 152,318 cycles per image (24,926 / 121,502 / 5,890), one start; layers 1–2 bit-exact vs THEIR outputs, FC bit-exact vs reference, 100/100; 99/100 correct ("Scalar-operand variant (SC)", gate 2) | 241,689 (56,052 / 175,674 / 9,883 + 80), 87/100 | MEASURED-BOTH | as the G row: our layer-busy vs their software windows | SC / IISc 0.4447 / 0.6916 / 0.5960, total 0.6302; SC / G 0.5017 | done |
| Scalar-operand variant (SC), CONV2D 3x3 8 / 16 / 32 / 64 (added 2026-11-18) | 1,398 / 7,238 / 32,934 / 140,390, all outputs bit-exact (their expected_output and the distinct set) ("Scalar-operand variant (SC)", gate 1) | 3,181 / 15,033 / 67,009 / 284,140 | MEASURED-BOTH | same windows as the vl=16 rows | 0.4395 / 0.4815 / 0.4915 / 0.4941 | done |
| Scalar-operand variant (SC) on V7, full chip (added 2026-11-18) | atee_top_sc 25,419 LUT / 15,838 FF / 132 BRAM / 65 DSP, WNS +2.492 ns (57.12 MHz) ("SC: Virtex-7 full-chip build") | Run 3: 87,259 LUT, WNS -6.193 ns with their exceptions | MEASURED-BOTH | ours clock-only, theirs with their constraints.xdc | | done |
| MAIN DESIGN SC: control logic on V7 (added 2026-11-19) | 2,163 = total − `u_vec_unit` (25,419 − 23,256) ("Main design: scalar-operand variant (SC) …", item 1) | 39,425 = `cpu1` − `VECTOR_UNIT` (Run 3) | MEASURED-BOTH | same subtraction method | ours clock-only, theirs with their constraints | done; 18.227 ("Headline ratios" #28) |
| MAIN DESIGN SC: LUT decomposition vs Run 3 (added 2026-11-19) | 61,840 = 1,355 (2.19%) + 37,262 (60.26%) + 23,244 (37.59%) − 21 (−0.03%) (same section, item 1) | Run 3 rows | MEASURED-BOTH | as E | | done |
| MAIN DESIGN SC: power, netlist-SAIF, Virtex-7 (added 2026-11-19) | conv8_3 0.486 W total / 0.235 dynamic, 13.58856 / 6.57060 µJ; cnn_demo image 0 layers 0.346 / 0.368 / 0.337 W dynamic, 1,874.12396 / 1,106.44124 µJ per image; 100% nets matched ("Main design … item 2") | not obtainable (IISc netlist cannot be simulated; see "Virtex-7 power (2026-11-14)") | OURS-MEASURED | gates: cycles and outputs reproduce | static is the XC7VX485T's | done; vs vl=16 0.5016 (#34) |
| MAIN DESIGN SC vs IISc: power, RTL-SAIF, cnn_demo image 0 and conv8_3 (added 2026-11-19) | cnn_demo image 0.605 / 0.353 W, 1,843.04780 / 1,075.36508 µJ; conv8_3 0.595 / 0.342 W, 16.63620 / 9.56232 µJ (item 2) | cnn_demo inference 1.015 / 0.744 W, 4,906.28670 / 3,596.33232 µJ (2026.1, gate: windows, DMEM, VRF identical to 2019.1); conv8_3 44.91572 µJ dynamic (recorded) | MEASURED-BOTH (RTL-SAIF) | condition-triggered windows (validated identical on conv8_3) | matched 3% / 8%; RTL-SAIF bias on SC +45.5% (conv8_3) / −2.8% (cnn_demo) vs netlist-SAIF, uncalibrated for IISc; IISc fails 50 MHz | done; 0.2990 / 0.2129 (#35, #36) |
| MAIN DESIGN SC: CONV2D 5x5 32x32, 32 filters (added 2026-11-19; supersedes the PROJECTED 5x5 row for our side) | 162,276 cycles, 25,088/25,088 exact on their data and on a distinct data set (same section, item 3) | 297,549 (conv2d_5 entry → return) | MEASURED-BOTH | layer-busy vs their function call | | done; 0.5454 (#30) |
| MAIN DESIGN SC: MATMUL 16 / 32 / 64 as 1x1 conv (added 2026-11-19; supersedes the PROJECTED MATMUL row for our side) | 1,210 / 9,006 / 70,128, all exact on their data and on distinct data (item 3) | 4,737 / 20,993 / 113,921; their matmul32 output is wrong | MEASURED-BOTH | as above | MATMUL 8 does not fit (OC 8 not a multiple of 16) | done; 0.2554 / 0.4290 / 0.6156 (#31) |
| MAIN DESIGN SC: Table VIII placement (added 2026-11-19) | per filter 1.7475 / 9.0475 / 41.1675 µs (3x3 8/16/32), 101.4225 µs (5x5 32), MATMUL 64 1,402.56 µs (item 4) | IISc 4.99 / 19.81 / 84.75 / 185.8 / 2,275.71; Klessydra-T 9.91 / 21.18 / 59.54 / 112.38 / 2,741.35; RI5Cy 46.46 / 165.08 / 623.85 / 1,969.37 / 1,971 (all quoted from IISc Table VIII) | OURS-MEASURED/THEIRS-QUOTED | n-filter run / n | no single-filter program; quoted cores at other clocks | done (#32, #33) |
| cnn_demo design on V7, full chip (added 2026-11-17) | atee_top_cnn 25,028 LUT / 15,621 FF / 128 BRAM / 54 DSP, WNS +2.313 ns (56.54 MHz) ("G: Virtex-7 full-chip build") | Run 3: 87,259 LUT, WNS -6.193 ns with their exceptions | MEASURED-BOTH | ours clock-only, theirs with their constraints.xdc | vector-unit row differs from Run 1 by -1,046 LUT with identical RTL (not investigated) | done |
| cnn_demo per-layer cycles (added 2026-11-16) | not built | 56,052 / 175,674 / 9,883 + 80 overhead = 241,689 per image, identical on all 100 (same section, B) | THEIRS-MEASURED-HERE | | | done |
| cnn_demo layer 2 vs IISc (added 2026-11-16) | PROJECTED (P = 100, no pooling): B 299,523 (vl=8) / 229,739 (vl=16); D 231,601 (vl=16, Q=6); F 124,177 (vl=16, new datapath) (`docs/chunked_taps_design.md` §8) | 175,674 measured, including the max-pool (B row above) | PROJECTED vs THEIRS-MEASURED-HERE | slot rule (measured on the chunk test) | projection; ours excludes pooling; F assumes a cost-free scalar operand | no ratio may be quoted |
| Chunk boundary, ATEE core (added 2026-11-16) | 192/192 exact, both hex sets, vl = 8 and 16, 0 stalls; cycles = slot rule (same section, D) | — | OURS-MEASURED | isolated convoy test, not a controller | stage 1 only | done |

Ledger notes (2026-11-11, later):
- Tables VII, VIII and IX were read from the paper itself: "A Soft RISC-V Vector Processor for Edge-AI", VLSID 2022, DOI 10.1109/VLSID2022.2022.00058, local copy `<AUTHOR_LOCAL>\A_Soft_RISC-V_Vector_Processor_for_Edge-AI.pdf` (there is no `docs/` copy in the project). The table bodies are vector drawings, so they were read from a rendered page (page 6, printed page 268), not from extracted text.
- An earlier row "Table VII: CONV2D 5x5, 32x32" (9,290 cycles, matched from the spreadsheet) was REMOVED: Table VII has no 5x5 row. The 5x5 result is in Table VIII and is listed above.
- Time-unit ambiguity: Table VIII prints its header as `Execution Time (MS)` and Table IX as `Texe (Ms)`. Both are recorded as printed. In the spreadsheet the same numbers are under "TIME us" (CONV2D G column; MLP sheet C3 = 345; CNN sheet C12 = 4,813), and the Table VIII CONV2D values equal cycles × 20 ns in µs (e.g. 250 × 0.02 = 5.0 for 4.99). So the values are consistent with microseconds; the paper itself does not say so unambiguously.
- Table VII confirms that 1,946 is the SCALAR RISC-V cycle count for CONV2D-3x3 at 8 (vector 250), as already corrected in "Comparison baseline".

## vl=16 controller (2026-11-11)

A new controller computes all 16 output channels of a pixel in one pass, using the schedule measured in isolation by `testbench/convoy_vl16_tb.v`.

- **New files:**
  - RTL: `rtl/vector_unit/hbm_lite_controller_vl16.v` and `rtl/vector_unit/atee_top_vl16.v` (a copy of `atee_top.v` with the new controller and a `cfg_error` output).
  - Testbench `testbench/atee_conv_vl16_tb.v`; scripts `scripts/run_conv_vl16.ps1` and `scripts/synth_atee_vl16_ooc.tcl`.
- **Unchanged:** the live vl=8 controller, `atee_top.v` and the vector-unit RTL. The live vl=8 conv8_3 regression was re-run afterwards: 3,403 cycles, 576/576 bit-exact.
- **Run conditions:** BRAM-only, no DMA, EARLY_CLEAR default (clear 16 cycles after the last real slot), design default ENABLE_DIV in simulation, ENABLE_DIV=0 in synthesis (as for every recorded synthesis).

### Schedule and scheduling rules

- **Vector layout:** a vl=16 vector occupies two registers, elements 0–7 in vd and 8–15 in vd+1.
- **Register maps:**
  - ReLU on: inputs v1–v8, accumulator v9/10, zero pair v11/12, tap t in v(13+2t). At most 9 taps.
  - ReLU off: inputs v1–v6, accumulator v7/8, tap t in v(9+2t). At most 11 taps.
- **Convoys:** the same chunking as the vl=8 controller (3+3+3 without ReLU; 4+4+1 with a fused ReLU + store), with all 8 slots issued in every convoy.

| Rule (inherited-core hazard) | How the vl=16 schedule meets it |
|---|---|
| 1. No load directly before its reader | Every MAC reads a load 3 slots ahead (4 in a 4-tap convoy). The slot directly before a MAC holds a MAC or a running no-op, never a load. |
| 2. No store from slot 7 | The store sits in slot 3+n ≤ 6 without ReLU and in slot 4+n ≤ 6 with ReLU (n ≤ 2 in the last convoy). Slot 7 holds a MAC (4-tap convoy) or a running no-op; both have write enable 0, so the crossbar's unconditional slot-7 branch never writes. |
| 3. Unit-stride loads only | Every load uses mode_lsu = 00. Each input pixel is stored 16 times (one 16-word vector, two DMEM rows), so no broadcast load is needed. |
| 4. Every slot occupied at vl > 8 | All 8 slots are issued in every convoy; slots with no work hold a running no-op (start = 1, no register or memory write). While waiting, the controller re-drives slot 7's own instruction instead of an idle write. Rule 2 is met at the same time because slot 7's occupant is never a store. |

- **Limits, enforced in hardware:** taps (IC×KH×KW) ≤ 9 with ReLU or ≤ 11 without; OUTPUT_C a non-zero multiple of 16. Outside these limits the layer is not run: `cfg_error` is set and the layer ends after 19 cycles.
- **Limit test** (`run_conv_vl16.ps1 -LimitTest`): 10 taps with ReLU, 12 taps without ReLU, OUTPUT_C = 8 and OUTPUT_C = 24 were all REFUSED (`cfg_error` = 1).
- **Not exercised:** acceptance of 10 or 11 taps without ReLU, and OUTPUT_C = 32 or more. Every layer run below has 9 taps and 16 output channels.

### Results (simulation, all bit-exact)

| Workload | vl=16 cycles | Projection | Measured − projection | vl=8 cycles (recorded) | vl=16 / vl=8 | IISc conv2d (measured) | vl=16 / IISc | Bit-exact | DMEM used of 512 KB |
|---|---|---|---|---|---|---|---|---|---|
| CONV2D 3x3 8x8 (their data) | **2,599** | 2,599 | 0 | 3,403 | 0.763738 | 3,181 | 0.817039 | 576/576 vs ref and vs theirs | 6,976 B = 6.8125 KB (1.33%) |
| CONV2D 3x3 16x16 | **13,799** | 13,799 | 0 | 18,123 | 0.761408 | 15,033 | 0.917914 | 3,136/3,136, both | 29,504 B = 28.8125 KB (5.63%) |
| CONV2D 3x3 32x32 | **63,079** | 63,079 | 0 | 82,891 | 0.760987 | 67,009 | 0.941351 | 14,400/14,400, both | 123,712 B = 120.8125 KB (23.60%) |
| CONV2D 3x3 64x64 | **269,159** | 269,159 | 0 | 353,739 | 0.760897 | 284,140 * | 0.947276 | 61,504/61,504, both | 508,736 B = 496.8125 KB (97.03%) |
| 16x16, distinct mixed-sign filters | 13,799 | — | — | 18,123 | — | — | — | 3,136/3,136 | 29,504 B |
| 16x16 distinct, ReLU | 14,387 | 196×73 + 79 = 14,387 | 0 | — | — | — | — | 3,136/3,136 (980 outputs clamped) | 29,504 B |
| MNIST conv1, bias omitted | 47,399 | 676×70 + 79 = 47,399 | 0 | 62,283 | 0.761026 | — | — | 10,816/10,816 | 94,016 B = 91.8125 KB |
| MNIST conv1, bias omitted, ReLU | 49,427 | 676×73 + 79 = 49,427 | 0 | 66,339 | 0.745067 | — | — | 10,816/10,816 (2,161 clamped) | 94,016 B |

\* IISc 64x64: 284,140 in both the original-stand-in run (completed, err_count 0, 61,504/61,504 exact) and the stand-ins-tied-to-0 run.

- **Negative controls:** ReLU off, compared against the ReLU'd reference. MNIST fails on exactly its 2,161 negative outputs and the 16x16 distinct set on exactly its 980, with 0 mismatches on non-negative outputs.
- **Projection check:** every measured count equals its projection. The projection is (pixels × 70) + 79 without ReLU and (pixels × 73) + 79 with ReLU. 70 and 73 are the per-pixel counts measured in `convoy_vl16_tb.v`; 79 = 3 weight convoys × 20 + 3 init + 16 output-size divider. No difference to explain.
- **Versus IISc:** vl=16 takes FEWER cycles than IISc's measured conv2d call at every size (582 / 1,234 / 3,930 / 14,981 fewer). The margin shrinks with size, from 18.3% at 8x8 to 5.3% at 64x64.
- **Memory:** 64x64 fits with 15,552 B (3%) to spare. A larger image would not fit with 16x input replication.

### Synthesis, out of context (method as "Out-of-context synthesis (method consistency)")

Vivado 2019.1, xc7a200tfbg676-2 (Artix-7 stand-in), `-mode out_of_context`, ENABLE_DIV=0, clock only (20.000 ns), no exceptions, no tuning. Reports in `synth_build/atee_ooc_atee_top_vl16/` and `synth_build/atee_ooc_hbm_lite_controller_vl16/`.

| Top | Stage | LUTs | FFs (latches) | BRAM tiles | DSP | WNS | Derived max frequency |
|---|---|---|---|---|---|---|---|
| `atee_top_vl16` | post-synthesis | 25,138 | 15,212 (0) | 128 | 63 | +1.801 ns | — |
| `atee_top_vl16` | **post-route** (39,307 nets routed, 0 errors) | **25,129** | **15,212 (0)** | **128** | **63** | **+0.407 ns, met**, 0 of 29,878 failing; hold met (+0.098 ns) | 1000/19.593 = 51.04 MHz |
| `hbm_lite_controller_vl16` | post-route | 694 | 347 (0) | 0 | 18 | +2.665 ns | — |

- Hierarchy of `atee_top_vl16`, post-route: `u_config` 414 LUT / 577 FF; `u_hbm_lite` 822 / 347 / 18 DSP; `u_vec_unit` 23,910 / 14,288 / 128 BRAM / 45 DSP; top level 17 LUT.
- **Control logic, same subtraction method:** 25,129 − 23,910 = **1,219 LUT** (vl=8: 1,215).
- Worst post-route path: inside the inherited vector unit, `Instructions_reg[7][vs2][3]` to `X_REGS/Xoutreg_reg[3][25]`, 19.482 ns, 28 levels. The worst path of the controller alone is its input-address arithmetic (`comb_input_addr4` to `vec_RS1_reg[29]`, 17.336 ns).
- 50 MHz is still met on the stand-in part.

## vl=16 power, full chip, SAIF (2026-11-12)

Measured on Artix-7 xc7a200tfbg676-2, NOT the literal Genesys 2 target (Kintex-7 XC7K325T). The method is the same as the vl=8 SAIF figure (§4: 0.379 W total / 0.242 W dynamic). The only difference is the design: `atee_top_vl16`, with `hbm_lite_controller_vl16`.

- **Build:** full chip (not out of context), Vivado 2019.1, ENABLE_DIV=0, clock constraint only (20.000 ns), no exceptions, no tuning. Script `scripts/synth_atee_vl16_fullchip.tcl` (new). Reports are in `synth_build/artix7_xc7a200tfbg676-2_vl16/` (synthesis) and `.../clk_only/` (post-route). 20 source files, none from archive, DMA, CPU or IISc.
- **Power method:**
  - Post-implementation FUNCTIONAL simulation of the routed netlist (`write_verilog -mode funcsim`, unisim models, no timing annotation).
  - Workload: CONV2D 3x3 8x8 (conv8_3 data, `gen_conv_sizes.py 8`), no ReLU, BRAM-only, no DMA.
  - SAIF recorded over the layer-busy window only, then `read_saif` + `report_power`.
  - Scripts (new): `scripts/run_power_saif_vl16.ps1`, `testbench/power_saif_vl16.tcl`, `scripts/power_report_saif_vl16.tcl`. Reports are in `synth_build/power_saif_vl16/`.

### Implementation (full chip, post-route)

| | vl=16 (`atee_top_vl16`) | vl=8 (§2/§3, same flow) |
|---|---|---|
| Slice LUTs | 25,131 (18.78%) | 25,096 |
| Slice registers | 15,212 (5.68%) | 15,193 |
| Slices | 10,209 (30.52%) | 10,123 |
| Block RAM tiles / DSP48E1 | 128 / 63 | 128 / 63 |
| Bonded IOB | 258 (64.50%), one more than vl=8 for the `cfg_error` port | 257 |
| Hierarchy: `u_config` / `u_hbm_lite` (of which `u_outsize`) / `u_vec_unit` LUTs | 414 / 825 (110) / 23,909 | 413 / 825 (110) / 23,881 |
| Routing | 39,566 of 39,566 nets, 0 errors | — |
| **Timing at 50 MHz** | **MET: WNS +0.312 ns**, TNS 0.000, 0 of 29,879 endpoints failing; hold met (WHS +0.070 ns) | met, WNS +0.251 ns |
| Worst path | 19.681 ns, 27 levels, inside the inherited vector unit: `EXE_MEM_v0_DATA_reg[0][23]` to `EXE_MEM_ALU_y_reg[6][29]` | inside the vector unit |
| Vectorless power (LOW confidence, for reference only) | 0.619 W (0.481 dyn + 0.138 static) | 0.614 W |

### Power (SAIF, conv8_3 data, layer-busy window)

xsim console of the netlist run:

```
  DMEM used: input 4096 B (16x replication) + weights 576 B + output 2304 B = 6976 B of 524288 B
SAIF window opens at 47840 ns (after 2392 cycles of reset, DMEM load and configuration)
SAIF logging 26373 nets/ports from 19 of 59 listed scopes (3080 objects outside their scope dropped)
SAIF window closes at 99820 ns: 2599 clock cycles with layer_busy = 1
  cfg_error                       : 0
  layer-busy cycles               : 2599
  bit-exact vs reference           : 576 / 576 (max |diff| 0)
  bit-exact vs THEIR expected     : 576 / 576 (max |diff| 0)
  STATUS                          : ** PASS **
```

| | vl=16 | vl=8 (§4/§5) |
|---|---|---|
| Total on-chip | **0.394 W** | 0.379 W |
| Dynamic | **0.257 W** | 0.242 W |
| Device static | 0.137 W | 0.137 W |
| Tool confidence | High | High |
| Design nets matched | 49% (25,500 of 52,516) | 49% (25,597 of 52,376) |
| By type: clocks / slice logic / signals / block RAM / DSP / I/O | 0.033 / 0.034 / 0.061 / 0.128 / <0.001 / <0.001 W | 0.033 / 0.029 / 0.052 / 0.128 / <0.001 / <0.001 W |
| Dynamic by hierarchy: `u_vec_unit` / `u_hbm_lite` / `u_config` | 0.253 / 0.002 / 0.001 W | 0.237 / 0.003 / 0.001 W |
| Layer-busy window | 2,599 cycles × 20 ns = 51.98 µs | 3,403 cycles = 68.06 µs |

### Energy per layer, conv8_3 data, no ReLU, at 50 MHz

| Quantity | vl=16, total (0.394 W) | vl=16, dynamic (0.257 W) | vl=8 total / dynamic (§5) |
|---|---|---|---|
| Whole layer | **20.48012 µJ** | **13.35886 µJ** | 25.795 / 16.471 µJ |
| Per output value (576) | 35.5558 nJ | 23.1925 nJ | 44.78 / 28.59 nJ |
| Per output spatial position (36) | 568.892 nJ | 371.079 nJ | 716.5 / 457.5 nJ |
| Per MAC (5,184) | 3.95064 nJ | 2.57694 nJ | 4.976 / 3.177 nJ |

- vl=16 / vl=8 energy per layer: 0.811053 dynamic (13.35886 / 16.471), 0.793957 total (20.48012 / 25.795). vl=16 draws more power, 0.257 W against 0.242 W dynamic, but for 76% of the cycles.
- The energies come from power figures the tool reports to 3 decimals. They exclude loading DMEM and reading the results back. They are for the stand-in part.

### SAIF scope coverage — correction note on the vl=8 run (2026-11-12)

The SAIF script logs the nets of a list of 59 module scopes. In xsim, 40 of these (the escaped `\GEN_ALUs[n].alu_gen ` etc.) do NOT resolve in `get_objects`; the pattern falls back to the testbench's own top-level signals. This was measured on both snapshots:
- the vl=8 `power_snap` returns 56 objects of `/atee_conv8_3_tb/...` for `GEN_ALUs[1]`;
- the vl=16 snapshot returns 77 of `/atee_conv_vl16_tb/...`.

So the §4 vl=8 run's "nets and ports of the 59 design module scopes" in fact logged the design nets of 19 scopes, plus testbench signals that `read_saif -strip_path .../dut` cannot match. **The recorded vl=8 numbers (0.379 / 0.242 W, 49% matched) are unchanged**: they are what that run measured. Only the description of the coverage is corrected here.

The vl=16 script drops objects outside their own scope, which logs the same 19 scopes. It is therefore the same coverage as the vl=8 run, and the matched-net share (49%) agrees. (Without the drop, the 61,504-word testbench arrays made each fallback `log_saif` take minutes: the first vl=16 attempt was stopped after 74 minutes in that loop and produced no result.) Logging the 40 `GEN_*` scopes correctly could raise the matched share for both designs. It has not been done.

## Paper tables, transcribed (2026-11-15)

**Source:** "A Soft RISC-V Vector Processor for Edge-AI", V. Naveen Chander and K. Varghese, VLSID 2022, pp. 263–268, DOI 10.1109/VLSID2022.2022.00058. Local copy: `<AUTHOR_LOCAL>\A_Soft_RISC-V_Vector_Processor_for_Edge-AI.pdf`.

**Method.** The PDF's text layer uses a shifted font encoding and drops every digit, so it cannot be read as text. All values were read from the pages rendered at 220–330 dpi (PyMuPDF). Values are copied as printed, with their units. Nothing in this section is a measurement of ours.

**Row status:**
- MEASUREMENT: a number the paper presents as measured.
- DESCRIPTIVE: a design parameter or a definition.

### Table I — Distribution of major operations on CNN and RNN (MEASUREMENT, their profiling on an Intel Xeon E5-1607-v3)

| CNN: CONV2D | ReLU | Maxpool | VMATMUL | RNN: VMATMUL | Activations |
|---|---|---|---|---|---|
| 98.78% | 0.26% | 0.21% | 0.13% | 98.08% | 1.43% |

### Table II — VRF bank access pattern by lanes as scheduled by the SAS (DESCRIPTIVE)

| Lane \ Cycle | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 0 | 1 |
| 2 | - | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 0 |
| 3 | - | - | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| 8 | (blank) | | | | | | | 0 | 1 | 2 |

### Table III — Hardware resource utilization of major constituents of RISC-V vector processor (MEASUREMENT, Virtex-7 XC7VX485T)

| Module | Slice LUTs | Slice Registers | BRAMs | DSP Tiles |
|---|---|---|---|---|
| Vector Pipeline | 35737 (46%) | 19896 (47%) | 32 (10 %) | 43 (64%) |
| Scalar Pipeline | 41996 (53%) | 22032 (52%) | 27 (9%) | 24 (36%) |
| Main Memory, Peripherals, Bus Interconnect and I/O | 1201 (1.5%) | 470 (1.1%) | 256 (82%) | 0 |

### Table IV — Power consumption by RISC-V CPU (MEASUREMENT, vector-based estimation, Xilinx Power Analyzer, their 6-layer CNN)

| | Total On-chip Power | Dynamic Power | Device Static Power |
|---|---|---|---|
| RISC-V Vector | 597 mW | 333 mW | 264 mW |
| RISC-V Scalar | 496 mW | 235 mW | 261 mW |

### Table V — Power consumption by constituents of RISC-V Vector CPU (MEASUREMENT)

| Module | Hierarchical Power | Total Power |
|---|---|---|
| Vector Pipeline | 120 mW | 20% |
| Scalar Pipeline | 95 mW | 16% |
| Memory and Peripherals | 115 mW | 20% |
| FPGA Device Static | 264 mW | 44.3% |

### Table VI — Programs in the benchmark and their uses in ML inference (DESCRIPTIVE)

| Benchmark Class | Description | Use in ML |
|---|---|---|
| AXPY | Y = aX + Y, a ∈ I | Input Scaling, Batch-normalization |
| Perceptron | Y = ReLU (WX + b), W ∈ I^mxn | MLP, RNNs, FC layers, RBMs, Autoencoders etc., |
| MATMUL | Square Matrix Multiplication | Regression, SVM |
| CONV | 2D convolution | CNN, Capsule Networks |

### Table VII — Benchmarking Results (MEASUREMENT)

| Vector Length | AXPY #cycles Vector RISC-V | AXPY Scalar RISC-V | AXPY Speedup | Perceptron Vector | Perceptron Scalar | Perceptron Speedup | MATMUL Vector | MATMUL Scalar | MATMUL Speedup | CONV2D-3x3 Vector | CONV2D-3x3 Scalar | CONV2D-3x3 Speedup |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 8 | 48 | 210 | 4.38 | 3142 | 39772 | 12.66 | 1755 | 4040 | 2.30 | 250 | 1946 | 7.78 |
| 16 | 56 | 340 | 6.07 | 3662 | 115915 | 31.65 | 4610 | 52565 | 11.40 | 991 | 10314 | 10.41 |
| 32 | 72 | 516 | 7.17 | 5087 | 226760 | 44.58 | 20858 | 405855 | 19.46 | 4238 | 69214 | 16.33 |
| 64 | 104 | 988 | 9.50 | 6782 | 449770 | 66.32 | 113786 | 7181791 | 63.12 | 17750 | 296398 | 16.70 |
| Energy per algorithmic Operation | 18.38 nJ/op | 146.81 nJ/op | 7.98 | 1.26 uJ/neuron | 69.71 uJ/neuron | 55.10 | 71.24 uJ/op | 1.35 mJ/op | 52.43 | 55.13 nJ/pixel | 764.9 nJ/pixel | 13.87 |

**Transcription notes (Table VII):**
- "Vector Length" is the row label for all four kernels. For MATMUL and CONV2D the paper's text and the repo use it as the matrix / image size (8x8 … 64x64).
- **MATMUL energy cells.** In their spreadsheet the vector energy is `B12 = 597 × 2275.71 / 10^6 = 1.35859887`, labelled "Energy(mJ/op)", and the scalar energy is `G12 = 496 × 143635.81 / 10^6 = 71.24`, labelled "Enery(uJ/op)". The paper prints 71.24 uJ/op under Vector and 1.35 mJ/op under Scalar. By the formulas, the vector figure is 1.36 mJ and the scalar figure 71.24 mJ (597 mW × 2,275.71 µs; 496 mW × 143,635.81 µs). The ratio 52.43 is the same either way. Recorded as printed, with this note.
- **Perceptron row 32** (5087 / 226760 / 101.73 µs / 4535.2 µs) is identical, cell for cell, to row 256 of their spreadsheet's VMATMUL sheet.
- **Source of the scalar column.** It equals their spreadsheet's "Scalar O3 No SPRAM" column. The AXPY scalar cells are formulas such as `CEILING((7.617-3.43)*50,1)`, i.e. a measured time minus 3.43 µs.

### Table VIII — Comparison of kernel performance with other similar processors having data-level parallelism (MEASUREMENT for Vector RISC-V; Klessydra-T and RI5Cy quoted by them from their ref. [3])

Column header printed as `Execution Time (MS)` (small capitals).

| CPU Name | Freq. (MHz) | CONV2D 3x3 8x8 | CONV2D 3x3 16x16 | CONV2D 3x3 32x32 | CONV2D 5x5 32x32 | MATMUL 64x64 |
|---|---|---|---|---|---|---|
| Klessydra-T [3] | 120 | 9.91 | 21.18 | 59.54 | 112.38 | 2741.35 |
| RI5Cy [3] | 91.4 | 46.46 | 165.08 | 623.85 | 1969.37 | 1971 |
| Vector RISC-V | 50 | 4.99 | 19.81 | 84.75 | 185.8 | 2275.71 |

(RI5Cy 8x8 and 16x16 are printed across two lines as "46.4 / 6" and "165.0 / 8".)

### Table IX — Performance and Energy Results for Neural Networks (MEASUREMENT)

Column header printed as `T exe (Ms)` (subscript "exe", capital M, lower-case s).

| | Vector RISC-V | Scalar RISC-V | speedup | Energy Improvement |
|---|---|---|---|---|
| MLP | 345 | 14045 | 40.71x | 33x |
| CNN | 4813 | 93999.557 | 19.53x | 16x |

**The unit.** Their spreadsheet holds the same numbers under "TIME us": sheet MLP C3 = 345 with A3 = 17,250 = 345 × 50 cycles; sheet CNN C12 = 4,813 with A12 = `CEILING(C12*50,1)` = 240,650 cycles. So the spreadsheet treats them as microseconds at 50 MHz. Whether the measured CNN matches 240,650 cycles, i.e. "µs", is tested in "Paper benchmark rows, measured on their design".

### Numeric claims in the text

| Claim (as printed) | Where | Status |
|---|---|---|
| CNN of fig. 1 takes "about 94 ms" per image on the 32-bit RISC-V microcontroller of [1]; real-time tolerates "up to 7 ms" [13] | §I.A | MEASUREMENT (theirs) / cited |
| CPU busy with matrix/vector operations "> 99%"; 6-layer CNN with 5x5 kernels "about 99%" in 2D convolutions; RNN "about 98%" in matrix-vector; exponent "1.43%" | §I.A | MEASUREMENT (profiling) |
| VEGAS "10x and 208x" over NIOS-II; [11] "up to 5.8x" at 50 MHz on Spartan, "about 160% more hardware"; Klessydra-T "about 36x" over RI5Cy on matrix multiplication | §I.B | cited |
| Abstract: speedup "up to 40.7x" on image recognition, at "1.2x power consumption and 1.8x hardware resources"; scalar core "runs at 50 MHz" | Abstract | MEASUREMENT |
| Contributions: "up to 40x with a cost of 25% more power and about 85% more resources" | §I | MEASUREMENT (differs from the abstract's 1.2x power) |
| About 50 RVV instructions; 32-bit integers only; four custom arg-max/min instructions | §II.A | DESCRIPTIVE |
| RV32G, 5-stage, 50 MHz; 1 MB block RAM with SECDED as main memory; 8 kB I-cache, TLB, two-bit G-share; 8 kB D-cache | §II.B | DESCRIPTIVE |
| VIU bundles up to eight vector instructions; "a delay of 26 clock cycles before the vector convoy can commence" | §II.C | MEASUREMENT / descriptive |
| 32 vector registers × 256 bits; up to 8 grouped; MVL = 64; five read ports, one write port per VRF bank | §II.D | DESCRIPTIVE |
| Fixed point Q32.0, Q24.8, Q16.16, Q8.24 | §II.E | DESCRIPTIVE |
| One 16 KB SPRAM bank per lane; up to 64 elements per instruction; 128 KB total, read latency one clock cycle | §II.F | DESCRIPTIVE |
| Virtex 7 XC7VX485T, target 50 MHz; vector unit "about 46%" of the CPU's resources, adds "about 85%" | §II.H | MEASUREMENT |
| Vector unit "about one-fifth" of total power; adds "21%" power | §II.H | MEASUREMENT |
| Vector unit alone "could run at 100 MHz"; critical path in the bus interface; "positive slack of about 0.4 ns at 50 MHz" | §II.H | MEASUREMENT |
| Benchmark of "30 programs" in four kernels, plus a three-layer perceptron and a six-layer CNN | §III | DESCRIPTIVE |
| Speedup "between 2.5x and 68x"; start-up overhead "fixed at 26 cycles"; overhead "as high ar 83%" at vl = 8 | §III.A | MEASUREMENT |
| AXPY steady-state "about 10x"; Perceptron "67x for vl = 64", drops to "about 5x for vl = 128"; weight fetch from main memory "about 3.4 ms", vector operations "about 268^s" (printed so; µs by context) | §III.A | MEASUREMENT |
| MLP of "32, 16 and 10 neurons with ReLU"; all weights and activations Q8.24 | §III.D | DESCRIPTIVE |
| "about 40x on MLP and 20x on CNN with 33x and 16x savings in energy" | §III.D | MEASUREMENT |
| Fig. 1 network: 28x28 input, 24x24x32, 12x12x32, 8x8x64, 4x4x64, 10 (5x5 kernels) | Fig. 1 | DESCRIPTIVE. Not the network of their repo's cnn_demo (3x3 kernels, 16 / 32 filters, see the mapping below) |
| Fig. 4: speedup vs vl = 2^3 … 2^10 for AXPY, Perceptron, MATMUL, CONV2D 3x3 | Fig. 4 | MEASUREMENT; plotted only, values not printed (not transcribed) |

### Mapping of every measurement row to a program in their repo (`benchmarks/benchmarks/`)

**Checks applied to every program:**
- Images: the program's memory images were rebuilt from its own `riscv-spike.elf` (`scripts/iisc_bench_prep.py`) and compared word by word with the shipped `.coe` files.
- Fixed point: Q32.0 where the assembly writes `csrc vxrm, 3`. Otherwise the CSR reset value `vxrm_default = 2'h3` applies, which is Q8.24 (`defines.v:342`; ALU `prod(55 downto 24)`).
- Their own check: main() counts `|Y − expected_output| > 10` into `err_count`, where present.
- Python reference: written from the assembly; inputs are the ELF's data symbols.

| Paper row | Program (path) | Kernel call | Sizes / shapes | Fixed point | Their check | Expected outputs | Python ref vs their expected_output | Shipped images vs ELF |
|---|---|---|---|---|---|---|---|---|
| Table VII AXPY, vl 8/16/32/64 | `saxpy/saxpy{8,16,32,64}` | `saxpy(y, a=64, x, n)` | vectors of n, `y = 64x + y` | Q32.0 | err_count, tolerance ±10 | yes | 8/8, 16/16, **5/32 (max \|diff\| 7,776)**, 64/64 | xmem.coe and dmem_bank*.coe: 0 words differ |
| Table VII Perceptron, vl 8/16/32/64 | `perceptron/mlp{8,16,32,64}_32` (byte-identical to `mlp/mlp*_32`) | `mlp32(...)` | n inputs × 32 neurons, `v20 = Σ inp[k]·W[k][:]`, no bias, no ReLU, **result never stored** (stays in v20–v23) | Q32.0 | none (main only calls mlp32) | yes | 32/32 at every n | no xmem.coe shipped. code.coe = ELF (0 differ). **`.vmem_data` linked at 0x40000** (pre-2021-05-28 map); shipped dmem_bank*.coe differ from the 0x100000 layout. See the measured section |
| Fig. 4 Perceptron vl = 128/256 (plot only) | `perceptron/mlp256_8` (256 in, 16 neurons), `perceptron/mlp256_16` (256 in, 8 neurons); the names are swapped against N_NEURONS | `perceptron(Y, inp, W, 256, N, bias)` | + bias, `vand.vx` "ReLU", stored to Y | Q32.0 | none | yes | 16/16, 8/8 | 0 differ |
| Table VII MATMUL 8/16/32/64; Table VIII MATMUL 64x64 | `matmul/matmul{8,16,32,64}` | `matmul` / `matmul32` / `matmul64` | D×D, row of A as scalars × rows of B | Q32.0 | err_count ±10 | yes | 64/64, 256/256, 1,024/1,024, 4,096/4,096 | 0 differ |
| Table VII CONV2D-3x3 8/16/32/64; Table VIII 3x3 | `conv/conv{8,16,32,64}_3` | `conv2d` | n×n, 3×3, 16 filters | Q32.0 | err_count ±10 | yes | exact at all sizes ("CONV2D 3x3 at image sizes") | conv8_3: 0 differ |
| Table VIII CONV2D 5x5 32x32 | `conv/conv32_5` (no Outputfiles; only `Scripts/xmem.coe`) | `conv2d_5(Y, img, ker, 32)` | 32×32, 5×5, **32 filters**, 28×28×32 = 25,088 outputs | Q32.0 | err_count ±10 | yes | 25,088/25,088 | xmem.coe 0 differ; no dmem_bank*.coe shipped (DMEM built from the ELF) |
| Table IX CNN | `cnn_demo` | `conv2d` (3×3, 16 filters, bias, ReLU, 2×2 max-pool) -> `layer2` (3×3×16, 32 filters, bias, ReLU, 2×2 max-pool) -> `layer3` (FC 800 -> 10, bias, ReLU, vmax arg-max to a0) | 28×28 -> 13×13×16 -> 5×5×32 -> 10 | **Q8.24** (no csrc vxrm) | none; prints the digit over UART | no expected output in the program. 100 test images with labels are in `Demo/Application/img.c` / `expected_output.c` (the host demo's self-test) | n/a | xmem.coe and dmem_bank*.coe: 0 differ |
| Table IX MLP (32-16-10, Q8.24) | **no matching program.** `mlp/` holds only the single-layer `mlp*_32` (= `perceptron/mlp*_32`). Their spreadsheet's MLP sheet holds only the summary (345 / 14,045) | — | — | — | — | — | — | NOT RUNNABLE |
| Table VII / IX scalar columns | **no scalar program** for any kernel or network (all kernels are vector assembly). No RISC-V compiler is installed here | — | — | — | — | — | — | NOT RUNNABLE |
| Tables III, IV, V, VIII (other cores) | not programs | — | — | — | — | — | — | III and the 50 MHz / slack claims are in "Virtex-7 XC7VX485T, Vivado 2026.1"; IV/V are not reproducible (their CNN power) |

- Every shipped `code.coe` that differs from the ELF (conv8_3, saxpy, matmul, mlp256, cnn_demo: 5,126 – 14,313 words) belongs to a different program build. Its first difference is in the stack-pointer setup (e.g. `00021197` vs `00020197`). The `xmem.coe` files used here equal the ELF in every word. This is the same "code.coe is a different build" finding as the 2026.1 gate test.
- The Python reference reproduces every shipped `expected_output[]` exactly, except saxpy32 (5 of 32). The measured result for saxpy32 settles which one their hardware matches.

## Paper benchmark rows, measured on their design (2026-11-15)

### Method

- **Design.** Their FPGA_WRAPPER, repo build (Run-3 configuration, 512 KB scratchpad). Behavioural RTL in Vivado **2019.1** xsim, with the same IP models, stand-ins (assumed-function `xbip_dsp48_macro_1/_2`) and defines as the 3,181-cycle conv8_3 baseline. Nothing from this project's `rtl/` is compiled.
- **New files** (the existing scripts and testbenches are unchanged):
  - `scripts/iisc_bench_prep.py`: images from the program's ELF, checked against the shipped `.coe`; windows from `riscv-spike.dump`; Python reference.
  - `external/iisc_sim/iisc_tb_bench.v`: a copy of `iisc_tb_conv.v`, generalised.
  - `external/iisc_sim/iisc_bench_dump.tcl`: reads the final DMEM and VRF contents with `get_value`, because a Verilog reference cannot enter their VHDL vector unit; needs `xelab -debug typical`.
  - `scripts/iisc_bench_check.py`, `scripts/run_iisc_bench.ps1`, `scripts/run_iisc_bench_batch.ps1`, `scripts/run_iisc_cnn_images.ps1`, `scripts/iisc_bench_summary.py` (prints every table below), `scripts/iisc_matmul32_analyze.py`.
  - Logs in `sim_build/iisc_bench/logs/`.
- **Windows, cycles of the 50 MHz core clock:**
  - entry = first fetch of the function's entry address;
  - return = first fetch of (call site + 4) after entry;
  - reset → main returns = fetch of the final self-loop (0xec).
- **Outputs.** Read directly from the scratchpad bank models after the run (bank addr[4:2], row addr[18:5]). The perceptron result never leaves the VRF (v20–v23), so it is read from the VRF banks. Order check: the dumped DMEM equals the initial image in every row the program does not write, e.g. 131,065 of 131,072 rows in saxpy8.
- **Scalar versions:** none exist in their repo (every kernel is vector assembly), and no RISC-V compiler is installed here. No scalar column was measured.

### Gate (required first): conv8_3 reproduces 3,181 — PASS

```
[IISC] cycle 816: conv2d entered (PC = 0x9d0)            (original scripts/run_iisc_conv_sizes.ps1 -Size 8, unchanged)
[IISC] cycle 3997: conv2d returned (PC = 0xe98)
  conv2d entry  -> conv2d return     : 3181 cycles
  err_count == 0                     : YES
    L=1: ... Y covered 576/576, exact vs THEIR expected 576 (max |diff| 0), exact vs Python ref 576 (max |diff| 0)
[BENCH] cycle 816: window 0 entered (pc 000009d0)         (new flow, scripts/run_iisc_bench.ps1 -Program conv8_3)
[BENCH] cycle 3997: window 0 returned (pc 00000e98), x10 = 1051520
[BENCH] cycle 28888: main returned (pc 000000ec, final loop)
  Y                              vs Python reference      : 576 / 576 exact, max |diff| 0
  Y                              vs THEIR expected_output : 576 / 576 exact, max |diff| 0
```

### Kernels (output of `scripts/iisc_bench_summary.py`)

| Run | Function | reset -> entry | entry -> return | reset -> return | reset -> main returns | Published (Table VII, cycles) | entry->return / published | Their err_count (writes, non-zero, last value) | Output vs Python ref | Output vs THEIR expected_output |
|---|---|---|---|---|---|---|---|---|---|---|
| saxpy8 | saxpy | 414 | 119 | 533 | 1,017 | 48 | 2.4792 | 1, 0, **0** | 8/8 exact | 8/8 exact |
| saxpy16 | saxpy | 414 | 127 | 541 | 1,369 | 56 | 2.2679 | 1, 0, **0** | 16/16 | 16/16 |
| saxpy32 | saxpy | 414 | 143 | 557 | 2,114 | 72 | 1.9861 | 28, 27, **27** | **32/32 exact** | 5/32 (max \|diff\| 7,776) |
| saxpy64 | saxpy | 413 | 176 | 589 | 3,481 | 104 | 1.6923 | 1, 0, **0** | 64/64 | 64/64 |
| perc8 (as shipped) | mlp32 | 421 | 438 | 859 | 902 | 3,142 | 0.1394 | — (no check) | 0/32 (max \|diff\| 2,084) | 0/32 |
| perc16 (as shipped) | mlp32 | 420 | 593 | 1,013 | 1,056 | 3,662 | 0.1619 | — | 0/32 | 0/32 |
| perc32 (as shipped) | mlp32 | 420 | 903 | 1,323 | 1,366 | 5,087 | 0.1775 | — | 0/32 | 0/32 |
| perc64 (as shipped) | mlp32 | 420 | 1,523 | 1,943 | 1,986 | 6,782 | 0.2246 | — | 0/32 | 0/32 |
| perc8 RELOCATED | mlp32 | 421 | 438 | 859 | 902 | 3,142 | 0.1394 | — | **32/32 exact** (v20–v23) | 32/32 |
| perc16 RELOCATED | mlp32 | 420 | 593 | 1,013 | 1,056 | 3,662 | 0.1619 | — | 32/32 | 32/32 |
| perc32 RELOCATED | mlp32 | 420 | 903 | 1,323 | 1,366 | 5,087 | 0.1775 | — | 32/32 | 32/32 |
| perc64 RELOCATED | mlp32 | 420 | 1,523 | 1,943 | 1,986 | 6,782 | 0.2246 | — | 32/32 | 32/32 |
| mlp256_8 (Fig. 4 only; 256 in, 16 neurons) | perceptron | 400 | 3,831 | 4,231 | 4,240 | — | — | — | 16/16 | 16/16 |
| mlp256_16 (Fig. 4 only; 256 in, 8 neurons) | perceptron | 400 | 3,311 | 3,711 | 3,720 | — | — | — | 8/8 | 8/8 |
| matmul8 | matmul | 412 | 1,393 | 1,805 | 4,686 | 1,755 | 0.7937 | 2, 1, **1** | 64/64 exact | 64/64 |
| matmul16 | matmul | 412 | 4,737 | 5,149 | 16,286 | 4,610 | 1.0275 | 2, 1, **1** | 256/256 exact | 256/256 |
| matmul32 | matmul32 | 412 | 20,993 | 21,405 | 61,145 | 20,858 | 1.0065 | 1,009, 1,008, **1,008** | **16/1,024** (max \|diff\| 2,550,804) | 16/1,024 |
| matmul64 | matmul64 | 412 | 113,921 | 114,333 | 290,601 | 113,786 | 1.0012 | 1, 0, **0** | 4,096/4,096 | 4,096/4,096 |
| conv8_3 (gate) | conv2d | 816 | 3,181 | 3,997 | 28,888 | 250 per filter | see "CONV2D 3x3 at image sizes" | 1, 0, 0 | 576/576 | 576/576 |
| conv32_5 | conv2d_5 | 813 | **297,549** | 298,362 | 1,402,375 | 9,290 per filter (Table VIII 185.8 µs) | see below | 1, 0, **0** | 25,088/25,088 exact | 25,088/25,088 |

CONV2D 3x3 at 16 / 32 / 64 was measured on 2026-11-11 with the same design and method: section "CONV2D 3x3 at image sizes 8 / 16 / 32 / 64". It was not re-run.

### Published vs measured, and explanations of every mismatch > 1%

| Row | Published | Measured (entry -> return / reset -> return) | Published-style figure that fits | % error of that figure | Explanation |
|---|---|---|---|---|---|
| AXPY 8 / 16 / 32 / 64 | 48 / 56 / 72 / 104 | 119 / 127 / 143 / 176; 533 / 541 / 557 / 589 | **published = vl + 40 exactly**. Their spreadsheet SAXPY sheet: "Overheads" T3–T6 = 40, "VECTOR: 8+14n/64" | no measured window fits: entry→return − published = 71 / 71 / 71 / 72 | The published value is vl + a fixed 40-cycle overhead, not a measured window of this build. The function's own scalar set-up, loop control and return (about 71 cycles) are not in it. Not explained further. |
| Perceptron 8 / 16 / 32 / 64 | 3,142 / 3,662 / 5,087 / 6,782 | 438 / 593 / 903 / 1,523; 859 / 1,013 / 1,323 / 1,943 (identical shipped and relocated) | none found: published / entry→return = 7.17 / 6.18 / 5.63 / 4.45; no common divisor or offset | — | **Not explained.** The programs are linked for the pre-2021-05-28 memory map (`.vmem_data` at 0x40000). On the repo build their vector loads read DMEM rows 8192+ while the shipped bank images fill rows 0–31, so as shipped they compute 0/32 correctly. With the data relocated to the rows the loads read (RELOCATED variant: data placement only, no RTL or program change) they compute 32/32 exactly in the same cycles. The published figures may come from that older build. Row 32 equals their VMATMUL sheet row 256 cell for cell. |
| MATMUL 8 | 1,755 | 1,393; 1,805 | reset → return is 1,805 (+2.85%) | −20.63% (entry→return) | **Not explained.** 8x8 is the only size where the published value exceeds the function window. |
| MATMUL 16 / 32 / 64 | 4,610 / 20,858 / 113,786 | 4,737 / 20,993 / 113,921 | **entry → return − 135** (16: −127) | +2.75% / +0.65% / +0.12% | Their figure is the function call minus a constant 127–135 cycles, consistent with the call's scalar prologue/epilogue (save/restore of 11 registers). Only the 16x16 error exceeds 1% (+2.75%), entirely that constant. |
| MATMUL 64x64 (Table VIII, 2,275.71 µs) | 113,786 cycles at 50 MHz | 113,921 = 2,278.42 µs | as above | +0.12% | — |
| CONV2D 3x3 8 / 16 / 32 / 64 | 250 / 991 / 4,238 / 17,750 | (2026-11-11) | (reset → return) / 16 filters | within 0.34% | recorded in "CONV2D 3x3 at image sizes" |
| CONV2D 5x5 32x32 (Table VIII 185.8 µs = 9,290 cycles at 50 MHz; spreadsheet CONV2D F7 = 9,290) | 9,290 per filter | 297,549; 298,362 | **entry → return / 32 filters = 9,298.41** (185.968 µs); (reset → return) / 32 = 9,323.81 (186.476 µs) | +0.09% / +0.36% | The 5x5 figure is the 32-filter conv call divided by its 32 filters, like the 3x3 rows (which divide by 16). |
| CNN (Table IX, 4,813) | 4,813 | per image: see "cnn_demo" below | **conv2d entry → layer3 return = 241,689 cycles = 4,833.78 µs at 50 MHz** | **+0.43%** against 4,813 µs | Resolves the `T exe (Ms)` header: the value is **microseconds**. 4,813 ms would be 240,650,000 cycles, 996x the measured inference. |
| MLP (Table IX, 345) | 345 | NOT RUN: no program | — | — | Their repo has no 32-16-10 MLP program; see the mapping. |
| Scalar columns (Tables VII, IX) | various | NOT RUN: no scalar program | — | — | — |

### Output findings on their design

- **saxpy32:** their hardware computes `y = 64x + y` exactly (32/32 against the Python reference). Their shipped `expected_output[]` is wrong in 27 of 32 entries, so their own check ends with err_count = 27. The program fails its own check because of the expected-output file, not the hardware.
- **matmul8, matmul16:** the output matrix in memory is exact (64/64, 256/256), yet their check loop increments err_count once (final value 1) in both. The cause is NOT determined: their check reads both arrays through the scalar–vector interface, and that path was not probed.
- **matmul32: their program computes a WRONG result on their design.** 16/1,024 exact, err_count = 1,008. Read-only analysis of the dumped matrix (`scripts/iisc_matmul32_analyze.py`):
  - **Columns 0–15 = running sums over the rows** (512/512). `matmul32.S` never clears the accumulator v20 after storing a row. Its "Reset Accumulator" lines clear v22–v28; the 8x8/16x16 version clears v20.
  - **Columns 16–31 are stored as 0** (512/512). This is consistent with the `vmul.vx v22, v22, zero` issued right after `vse32.v v20` overwriting v22/v23 (elements 16–31 of the v20 group) before the store has read them. That is an interpretation, not separately proven.
  - The combined model reproduces all 1,024 values exactly.
  - Their Table VII MATMUL-32 cycle figure therefore belongs to a program that does not compute the matrix product.
- **matmul64, saxpy 8/16/64, mlp256_8/16, conv8_3, conv32_5:** exact, and their own checks pass where the program has one.

### cnn_demo (Table IX CNN) — 100 shipped MNIST images

**Testbench change (made in the COPY `iisc_tb_bench.v` only; their RTL, program and images are unchanged).** cnn_demo's main() waits in `while(1)` for `pflag`, which the UART interrupt sets after receiving the header 0xAA 0x55 0xBB 0x66 and 784 bytes. Each byte is stored as `img_buf[i] = ((int)read_val) << 16`, with `char` unsigned on RISC-V. Receiving one image at 57,600 baud would take about 788 × 10 × 868 ≈ 6.8 M cycles. Instead, before reset release the testbench writes into the main-memory model:
- the 784 words of `img_buf` (byte << 16);
- `pflag = 1`.

Their `boot.S` does not clear `.bss` (`init_bss` is commented out), so main() sees the image on its first test of `pflag`.

**Images and labels:** `Demo/Application/img.c` (100 images, the host demo's self-test set) and `Demo/Application/expected_output.c` (their labels; the first 100 MNIST test digits).

**Results.** Per-image cycles are identical for every image run (data-independent):

| Window | Cycles |
|---|---|
| reset release -> conv2d entry (boot, UART_init, 'C','N','N' sent) | 16,385 |
| conv2d (layer 1: conv 3x3, 16 filters, bias, ReLU, 2x2 max-pool) entry -> return | 56,052 |
| layer2 (conv 3x3x16, 32 filters, bias, ReLU, 2x2 max-pool) entry -> return | 175,674 |
| layer3 (FC 800 -> 10, bias, ReLU, vmax arg-max to a0) entry -> return | 9,883 |
| conv2d entry -> layer3 return (inference) | **241,689** |
| reset release -> layer3 return | 258,074 |

**Finding in layer3 (image 73 onwards).** Layers 1 and 2 are bit-exact against the Q8.24 Python reference on every image (Y 2,704/2,704, Y2 800/800). Layer 3 is not.
- In the VRF after the run, FC elements 0–7 (v20) equal the reference.
- FC elements **8 and 9** (v21 banks 0–1) equal **`bias3[8]` = −421,569 and `bias3[9]` = −49,168** exactly, in every image. Neither the 800 MACs nor the ReLU reached them.
- So the arg-max can never return 8 or 9 (their values stay negative).

Their layer3 runs at vl = 10. This is consistent with the vl > 8 hazard documented for ATEE ("REQUIREMENT … with vl > 8 NO slot may be left empty", `vrf_bank` takes the register offset of elements 8+ from slot i's counter). That is an interpretation, not separately proven.
*Correction (2026-11-16): the empty-slot rule does NOT apply here; no slot of layer3's convoys is empty. The cause is the `vrf_bank` write gate with a vl that is not a multiple of 8, shown directly by a minimal test: see "cnn_demo verification (2026-11-16)", check A.2.*

Model check (`scripts/iisc_bench_summary.py cnn`): on every simulated image, the hardware's FC vector equals "reference elements 0–7, `bias3[8..9]` for elements 8–9", and the hardware digit equals that model's arg-max.

**MODEL prediction for all 100 images** (`scripts/iisc_cnn_model_all.py`; `docs/iisc_cnn_model_all.txt`). These are model outputs, not measurements:
- **Exact Q8.24 reference of their network:** 99/100 correct. Its only miss is image 18 (label 5, reference 8).
- **"Elements 8, 9 = bias" model of their design:** 87/100. It misses all 13 images labelled 8 or 9: (7, 9→4), (9, 9→7), (12, 9→7), (16, 9→7), (20, 9→7), (58, 9→7), (61, 8→0), (62, 9→5), (73, 9→7), (78, 9→0), (84, 8→0), (92, 9→4), (99, 9→7). It gets image 18 right (5), because 8 cannot win.

**MEASURED classification, all 100 images** (simulation of their design, one run per image, completed 2026-11-15 about 20:00; `scripts/iisc_bench_summary.py cnn`, full output in `docs/iisc_cnn_measured_100.txt`):

```
CNN images run: 100; hardware digit == label: 87; hardware digit == Python argmax: 86; Y and Y2 bit-exact: 100
  Python (reference model, exact Q8.24 arithmetic) argmax == label: 99
  FC elements 0..7 in v20 == reference: 100; whole FC vector == "elements 8,9 = bias3 only" model: 100; hardware digit == arg-max of that model: 100
  labels 8 or 9 among the images run: 13
misclassified (image, label, hardware digit): [(7, 9, 4), (9, 9, 7), (12, 9, 7), (16, 9, 7), (20, 9, 7), (58, 9, 7), (61, 8, 0), (62, 9, 5), (73, 9, 7), (78, 9, 0), (84, 8, 0), (92, 9, 4), (99, 9, 7)]
  conv2d entry -> return: [56052]
  layer2 entry -> return: [175674]
  layer3 entry -> return: [9883]
  conv2d entry -> layer3 return: [241689]
```

- **Their design classifies 87 of the 100 shipped images correctly.** The 13 misses are exactly the 13 images labelled 8 or 9, and each wrong digit equals the model's prediction (100/100 match).
- The network itself (exact Q8.24 reference of their program and weights) classifies 99/100. Its only miss, image 18 (label 5 → 8), is classified correctly by the hardware, because 8 cannot win there.
- Layers 1 and 2 are bit-exact on all 100 images.
- The cycle counts are identical for every image.

| Images | image: label → hardware digit (✗ = wrong) |
|---|---|
| 0–9 | 0: 7→7, 1: 2→2, 2: 1→1, 3: 0→0, 4: 4→4, 5: 1→1, 6: 4→4, 7: 9→4 ✗, 8: 5→5, 9: 9→7 ✗ |
| 10–19 | 10: 0→0, 11: 6→6, 12: 9→7 ✗, 13: 0→0, 14: 1→1, 15: 5→5, 16: 9→7 ✗, 17: 7→7, 18: 5→5, 19: 4→4 |
| 20–29 | 20: 9→7 ✗, 21: 6→6, 22: 6→6, 23: 5→5, 24: 4→4, 25: 0→0, 26: 7→7, 27: 4→4, 28: 0→0, 29: 1→1 |
| 30–39 | 30: 3→3, 31: 1→1, 32: 3→3, 33: 4→4, 34: 7→7, 35: 2→2, 36: 7→7, 37: 1→1, 38: 2→2, 39: 1→1 |
| 40–49 | 40: 1→1, 41: 7→7, 42: 4→4, 43: 2→2, 44: 3→3, 45: 5→5, 46: 1→1, 47: 2→2, 48: 4→4, 49: 4→4 |
| 50–59 | 50: 6→6, 51: 3→3, 52: 5→5, 53: 5→5, 54: 6→6, 55: 0→0, 56: 4→4, 57: 1→1, 58: 9→7 ✗, 59: 5→5 |
| 60–69 | 60: 7→7, 61: 8→0 ✗, 62: 9→5 ✗, 63: 3→3, 64: 7→7, 65: 4→4, 66: 6→6, 67: 4→4, 68: 3→3, 69: 0→0 |
| 70–79 | 70: 7→7, 71: 0→0, 72: 2→2, 73: 9→7 ✗, 74: 1→1, 75: 7→7, 76: 3→3, 77: 2→2, 78: 9→0 ✗, 79: 7→7 |
| 80–89 | 80: 7→7, 81: 6→6, 82: 2→2, 83: 7→7, 84: 8→0 ✗, 85: 4→4, 86: 7→7, 87: 3→3, 88: 6→6, 89: 1→1 |
| 90–99 | 90: 3→3, 91: 6→6, 92: 9→4 ✗, 93: 3→3, 94: 1→1, 95: 4→4, 96: 1→1, 97: 7→7, 98: 6→6, 99: 9→7 ✗ |

- **Operational notes:**
  - Images 1–99 reused the image-0 snapshot (`scripts/run_iisc_cnn_images.ps1`); only the data files differ.
  - The runners were split and restarted twice to balance the load. Interrupted images were re-run from scratch.
  - Two compiles that started at the same moment hung in WebTalk (`wbtcv`). They were stopped and relaunched staggered; their results come from the clean relaunches.

## cnn_demo verification, layer-2 alternatives, chunk-boundary test (2026-11-16)

Order approved by the user: A (verify the digit-8/9 result) → B (per-layer cycles) → C (design note) → D (RTL stage 1, new files only). Their RTL, programs and images are unchanged in every run below. Simulator: Vivado 2019.1 xsim, same substitutions and defines as the 3,181 baseline.

### A.2 — the final-layer loop and the hazard (DONE)

**Their compiled loop** (`benchmarks/benchmarks/cnn_demo/riscv-spike.dump`, `layer3` at 0xdec; main calls it with `li a5,10` at 0x11e4 and `li a3,800` at 0x11f0):

```
 e24: 01237e57  vsetvli t3,t1,e32,m4      t1 = 32 -> clear convoy at vl = 32
 e30..e4c:      vmul.vx v0,v4,v8,...,v28 <- 0   (8 instructions, slots 0..7)
 e50: 0127fe57  vsetvli t3,a5,e32,m4      a5 = 10 -> vl = 10 for the rest
 OUTER_LOOP (e60..ea8, a6 = 800 >> 2 = 200 passes), one convoy per pass:
   slot 0 vle32.v v2,(a2)   slot 1 vle32.v v4,(s5)   slot 2 vle32.v v6,(s6)   slot 3 vle32.v v8,(s7)
   slot 4 vmacc.vx v20,s1,v2  slot 5 vmacc.vx v20,s2,v4  slot 6 vmacc.vx v20,s3,v6  slot 7 vmacc.vx v20,s4,v8
 bias convoy (eac..ec8):
   slot 0 vle32.v v4,(a4)   slot 1 vadd.vx v28 (dummy)   slot 2 vadd.vv v20,v4,v20 (bias)
   slot 3 vand.vx v20,v20,zero (ReLU)   slot 4 vmax.vv v10,v20,v20 (arg-max -> a0)   slots 5-7 vmul.vx
```

Slot k = k-th vector instruction of the convoy: `vector_top.v` lines 459–485 dispatch `I_id <= dispatch_counter`.

- **It runs at vl = 10: above 8 and not a multiple of 8.**
- **Mechanism (RTL).** `vrf_bank.vhd` line 86 writes a register only if `('0'&wr_count) <= vl`, where bank i's `wr_count` is `MEM_WB_counts(i)` (`exe_unit.vhd` line 344). That is the counter of SLOT i, whatever slot is writing.
  - When slot j writes element e (bank i = e mod 8), slot i's counter is 8·(e div 8) + j.
  - So a write to elements 8 and up lands only if 8 + j ≤ vl. At vl = 10 that is slots 0–2 only.
  - Applied to layer3: the 4 MACs (slots 4–7) and the ReLU (slot 3) never reach elements 8–9; the bias add (slot 2) does. That is exactly the recorded "elements 8, 9 = `bias3[8..9]`".
- **Match with a documented hazard.**
  - Same mechanism: `vrf_bank` takes bank i's counter from slot i (CLAUDE.md: EXP C, the slot-reuse rule T4, the vl > 8 empty-slot requirement).
  - New trigger. The empty-slot rule does not apply: every slot of these convoys is occupied.
  - Recorded as **rule 5**: vl must be a multiple of 8, or every instruction that writes elements ≥ 8g must sit in a slot j ≤ vl − 8g. Both ATEE controllers run at vl = 8 / 16 and meet it.

**Minimal test on their design** (`scripts/iisc_vlhazard.py`, `scripts/run_iisc_vlhazard.ps1`; runs in `sim_build/iisc_vlhazard/`).

- **Program:** their compiled cnn_demo image, with only the first 11 words of `main` (0x113c) replaced by a hand-assembled call of their unmodified `layer3`.
  - Patch: `001105b7 00058593 00110637 10060613 00400693 00110737 20070713 00a00793 00000513 c8dff0ef 0000006f`, shown for vl = 10; the 8th word is `li a5,vl`.
  - The encoder reproduces their own `jal ra,dec` = `be5ff0ef`, `jal ra,9d0` = `825ff0ef` and `lui a2,0x100` = `00100637`.
  - a3 = 4 gives one OUTER_LOOP pass, i.e. exactly one 8-slot loop convoy plus the bias convoy.
- **Data (Q8.24):** inputs 1.0, so each MAC adds W[r][n] = (n+1)·64^r exactly.
  - Set A: bias 0.
  - Set B: bias −(Σ_r W[r][n]) − 7, so the correct output is ReLU(−7) = 0.
- **Testbench:** the cnn_img0 snapshot (iisc_tb_bench.v, assumed stand-ins), reused unchanged.
- **The prediction was written into the script before the runs.**

| vl | Set | layer3 entry→return | hardware == correct | hardware == prediction | wrong elements |
|---|---|---|---|---|---|
| 8 | A / B | 359 / 359 | 8/8 / 8/8 | 8/8 / 8/8 | — |
| 9 | A | 361 | **0/9** | 1/9 | 0–8 (see below) |
| 9 | B | 361 | 9/9 | 9/9 | — |
| 10 | A | 363 | 8/10 | **10/10** | 8, 9 |
| 10 | B | 363 | 8/10 | **10/10** | 8, 9 |
| 11 | A / B | 365 / 365 | 8/11 / 11/11 | 11/11 / 11/11 | 8–10 (A) |
| 12 | A / B | 367 / 367 | 8/12 / 12/12 | 12/12 / 12/12 | 8–11 (A) |
| 16 | A / B | 375 / 375 | 16/16 / 16/16 | 16/16 / 16/16 | — |

Console (logs in `sim_build/iisc_vlhazard/logs/`):

```
CHECK vl 10 data set A: layer3 entry -> return 363 cycles, x10 at return 7
  hardware  v20[0..9]: [266305, 532610, 798915, 1065220, 1331525, 1597830, 1864135, 2130440, 0, 0]
  correct   v20[0..9]: [266305, 532610, 798915, 1065220, 1331525, 1597830, 1864135, 2130440, 2396745, 2663050]
  hardware == correct: 8 / 10 (wrong elements: [8, 9]); hardware == prediction: 10 / 10
CHECK vl 10 data set B: layer3 entry -> return 363 cycles, x10 at return 0
  hardware  v20[0..9]: [0, 0, 0, 0, 0, 0, 0, 0, -2396752, -2663057]
  hardware == correct: 8 / 10 (wrong elements: [8, 9]); hardware == prediction: 10 / 10
CHECK vl 12 data set A: layer3 entry -> return 367 cycles, x10 at return 7
  hardware  v20[0..11]: [266305, 532610, 798915, 1065220, 1331525, 1597830, 1864135, 2130440, 9, 10, 11, 12]
  hardware == correct: 8 / 12 (wrong elements: [8, 9, 10, 11]); hardware == prediction: 12 / 12
CHECK vl 8 data set A: ... hardware == correct: 8 / 8
CHECK vl 16 data set A: layer3 entry -> return 375 cycles, x10 at return 15
  hardware == correct: 16 / 16 (wrong elements: []); hardware == prediction: 16 / 16
```

- **vl = 10, the cnn_demo case:** outputs 8–9 are lost. Set B shows them holding exactly bias, with no MAC and no ReLU (−2,396,752 = −2,396,745 − 7). The vl = 8 and vl = 16 variants are fully correct.
- **vl = 12 confirms the slot dependence:** elements 8–11 hold the slot-4 MAC (row 0 = n+1) and nothing from slots 5–7.
- The prediction matches the hardware element for element at vl = 8, 10, 11, 12 and 16 (both sets).
- **OPEN, not explained: vl = 9, set A.** Elements 0–7 are also wrong (`[10, 14, 18, 22, 26, 30, 88, 209, 0]`); only element 8 matches the prediction (0). The write-gate rule does not account for elements 0–7. Set B (all zero after ReLU) cannot show it. cnn_demo does not use vl = 9.

**Conclusion of A.2:** the cnn_demo digit-8/9 result is caused by this hazard in their core at vl = 10. Shown directly on their design with their own layer3 code; vl ≤ 8 (and vl = 16) are correct. Checks A.1 and A.3 below must pass before the result is labelled "as released".

### A.1 — DSP-macro stand-ins during inference (DONE 2026-11-17, PASS)

Method:
- **Testbench:** `external/iisc_sim/iisc_tb_cnn_probe.v`, a copy of iisc_tb_bench.v, module name kept.
- **Probes:** every input (in18–in21, pac, in24–in29), output (op12, op13, op15, op16) and enable of the 4 stand-in instances, in both the ITLB and the DTLB replacement logic (re, we, hit, miss, EVA_en, update_EVA, EVA_addr, sorted_index).
- **Counting:** counted per phase (before conv2d | conv2d | between | layer2 | between | layer3 | after); every change goes to `probe_events.txt`.
- **Runs:** image 7 with the assumed stand-ins, and all 100 images with the second stand-in (`xbip_dsp48_macro_zero.v`, outputs tied to 0, the 2026-10-19 sensitivity function). Script `scripts/run_iisc_cnn_probe.ps1`, launched detached (`scripts/launch_iisc_cnn_probe_detached.ps1`).

**Probe, image 7, assumed stand-ins** (`sim_build/iisc_cnn_probe/assumed/img7/probe.txt`). Cycles with the signal high, or with a change, per phase 0..6:

```
ITLB  miss                    : 2 0 0 0 0 0 0
ITLB  we (replacement write)  : 2 0 0 0 0 0 0
ITLB  update_EVA              : 2 4 0 17 0 1 0
ITLB  stand-in inputs change  : 15 13 0 61 0 5 0
ITLB  stand-in outputs change : 8 13 0 61 0 5 0
ITLB  sorted_index change     : 2 0 0 0 0 0 0
DTLB  miss                    : 2 1 0 0 0 0 0
DTLB  we (replacement write)  : 2 1 0 0 0 0 0
DTLB  update_EVA              : 0 0 0 7 0 0 0
DTLB  stand-in inputs change  : 1 0 0 4 0 0 0
DTLB  stand-in outputs change : 1 0 0 3 0 0 0
DTLB  sorted_index change     : 1 0 0 1 0 0 0
```

- **The stand-ins ARE active during inference.** Their inputs and outputs change in all three layers: ITLB 13 / 61 / 5 cycles, DTLB 3 cycles in layer 2.
- Their outputs reach only the replacement ranking (`sorted_index`). The ranking selects WHICH entry a miss evicts.
- **Inside the inference there is exactly one replacement:** a DTLB miss in layer 1 at cycle 25,646. Events, identical under both stand-in functions (image 7 assumed, image 50 zero): miss at 25,646 with EVA_addr 1; EVA_en at 25,647; EVA_addr 2 at 25,648; write at 25,650. `sorted_index = fedcba9876543210` at that moment in both.
- The assumed function first changes the DTLB ranking at cycle 169,668 (layer 2, → `fedcb76543a98210`). No miss and no replacement follow it, in any layer.
- So the stand-ins' outputs cannot change what the inference computes or how long it takes on this program.
- The image-7 run itself: cycles 56,052 / 175,674 / 9,883, Y and Y2 bit-exact, digit 4 (label 9). Identical to the preload run of 2026-11-15.

100 images with the zero stand-ins: running (two detached runners). First result, image 50: same cycles, Y / Y2 exact, digit 6 = label.

**Result, 100 images with the zero stand-ins (DONE 2026-11-17 18:18; `python scripts/iisc_cnn_probe_summary.py zero`).** Compared with the 2026-11-15 runs (assumed stand-ins, `sim_build/iisc_bench/cnn_img<k>`):

```
ZERO stand-ins: images run 100; digit == 2026-11-15 (assumed stand-ins) run: 100; digit == label: 87
  windows (reset->entry and all three entry->return) identical: 100; whole DMEM (131,072 words) AND VRF (256 words) identical: 100
  differences: none
  probe counts summed over the 100 images, phases 0..6 (before | conv2d | between | layer2 | between | layer3 | after):
    ITLB miss                    : 200 0 0 0 0 0 0
    ITLB we                      : 200 0 0 0 0 0 0
    ITLB EVA_en                  : 200 0 0 0 0 0 0
    ITLB update_EVA              : 200 400 0 1700 0 100 0
    ITLB stand-in inputs change  : 900 400 0 3800 0 400 0
    ITLB stand-in outputs change : 100 0 0 0 0 0 0
    ITLB sorted_index change     : 100 0 0 0 0 0 0
    ITLB EVA_addr change         : 200 0 0 0 0 0 0
    DTLB miss                    : 200 100 0 0 0 0 0
    DTLB we                      : 200 100 0 0 0 0 0
    DTLB EVA_en                  : 200 100 0 0 0 0 0
    DTLB update_EVA              : 0 0 0 700 0 0 0
    DTLB stand-in inputs change  : 100 0 0 100 0 0 0
    DTLB stand-in outputs change : 100 0 0 0 0 0 0
    DTLB sorted_index change     : 100 0 0 0 0 0 0
    DTLB EVA_addr change         : 200 100 0 0 0 0 0
```

- **All 100 images are identical under the two stand-in functions:** digit, every cycle window, the whole scratchpad and the whole vector register file. 87/100 correct, the same as the 2026-11-15 result.
- Every image has the same probe pattern: 2 ITLB and 2 DTLB misses before conv2d, and exactly one DTLB miss + replacement inside layer 1. With the zero function the outputs and the ranking change once (at start-up) and never again.
- Runs: 4 detached runners (images 0–4 / 38–68 / 88–99 from 2026-11-16, then 5–20, 21–37, 69–87 relaunched 2026-11-17). Three runners hung after xsim exited, on WebTalk (`wbtcv.exe`), with all dumps already written. For images 4 and 68 the check was run by hand and appended to the log. From 2026-11-17 15:01 `scripts/iisc_wbtcv_watchdog.ps1` stopped such processes (3 times, `logs/watchdog.txt`). No simulation was re-run or altered.

**Conclusion of A.1:** the stand-ins are active, but on this program they cannot and do not change the result. PASS.

**Conclusion of A.1–A.3 (2026-11-17): the cnn_demo digit-8/9 result holds "as released".** Their released design and their released cnn_demo program (images preloaded in place of the UART; A.3 shows the two equivalent in outputs) classify 87/100 of the shipped images correctly. All 13 misses have labels 8 or 9: FC outputs 8–9 are lost to the vl = 10 write-gate hazard (A.2). The result does not depend on the two missing DSP-macro stand-ins (A.1). Limits: the cycle counts depend on the input path (A.3 table); the vl = 9 anomaly (A.2) stays open.

### A.3 — preload vs the real UART path (DONE 2026-11-16, PASS for outputs)

Method:
- **Testbench:** the same probe testbench compiled with `-d UART_FEED`. Nothing is preloaded, `pflag` included; the image is sent on `srx_pad_i` as 8N1 frames with 2 idle bit times between bytes: header 0xAA 0x55 0xBB 0x66, then the 784 pixel bytes.
- **Bit time:** measured on their own first transmitted start bit ('C').
- **Start:** sending starts at the first fetch of the `pflag` poll loop (0x117c).
- **Image:** 7 (label 9, preload result 4). Compared with the preload run: Y, Y2, a0 and cycles.

**Result (DONE 2026-11-16 about 03:10; `scripts/iisc_cnn_probe_summary.py uart`):**

```
[UART] cycle 1881: their first TX start bit lasted 864 core cycles (= bit time used for RX)
[UART] cycle 8171865: all 788 bytes sent
  window 0 (entry 000009d0, return 000011b0): reset -> entry 8170058 | entry -> return 54560 | ...
  window 1 (entry 00000c10, return 000011e0): reset -> entry 8224667 | entry -> return 175659 | ...
  window 2 (entry 00000dec, return 0000120c): reset -> entry 8400357 | entry -> return 9866 | ... | x10 at return 4
CHECK cnn (cnn_demo)
  Y (layer 1+2 output)           vs Python reference      : 2704 / 2704 exact, max |diff| 0
  Y2 (layer 3+4 output)          vs Python reference      : 800 / 800 exact, max |diff| 0
  x10 at return 4 (...); Python argmax 9 (max value 40812178); label 9 -> WRONG
UART image 7 vs preload, 2026-11-15 run:
  a0 (digit) at layer3 return: UART 4, preload 4
  dmem words equal: 131072 / 131072;  vrf words equal: 256 / 256
```

- **Outputs: identical to the preload run.** Whole scratchpad (all 131,072 DMEM words, so Y and Y2 included), whole vector register file (256 words, FC vector included), digit 4. The image arrived over the UART exactly as preloaded.
- Note on the start: sending began at cycle 1,881, triggered by a wrong-path fetch of 0x117c (the instruction after `jal UARTCharPut`), while main was still sending 'C','N','N'. The receive path is interrupt-driven and took all 788 bytes.
- **Cycles: not identical.**

  | Window | UART | Preload | Difference |
  |---|---|---|---|
  | conv2d | 54,560 | 56,052 | −1,492 |
  | layer2 | 175,659 | 175,674 | −15 |
  | layer3 | 9,866 | 9,883 | −17 |
  | inference, conv2d entry → layer3 return | 240,165 = 4,803.30 µs | 241,689 = 4,833.78 µs | −1,524 |

  - Against Table IX's 4,813: −0.20% (UART) vs +0.43% (preload).
  - Interpretation, NOT proven: with the UART path, `img_buf` was written by the interrupt handler through the D-cache and is cache-resident when conv2d reads it. With the preload it sits only in main memory.
  - Consistent with that: at the end only 655 of the 785 preloaded words are equal in the main-memory model of the UART run. The rest are still in the cache, or `pflag` was cleared.
- **The 2026-11-15 per-layer cycles (B) are therefore for the preload path.** The released, UART-fed program runs layer 1 about 2.7% faster.

### B — cnn_demo per-layer cycles on their design (from the Step-2 runs, `sim_build/iisc_bench/cnn_img*/dump.txt`)

| Part | Window | Image 0 | Mean over 100 images (min = max) |
|---|---|---|---|
| Layer 1: conv 3x3, 16 filters, bias, ReLU, 2x2 max-pool | conv2d entry → return | 56,052 | 56,052 |
| Overhead: argument set-up between calls | conv2d return → layer2 entry | 49 | 49 |
| Layer 2: conv 3x3x16, 32 filters, bias, ReLU, 2x2 max-pool | layer2 entry → return | 175,674 | 175,674 |
| Overhead | layer2 return → layer3 entry | 31 | 31 |
| Layer 3: FC 800 → 10 + bias + ReLU + arg-max (vmax) | layer3 entry → return | 9,883 | 9,883 |
| Inference | conv2d entry → layer3 return | 241,689 | 241,689 |
| Before inference: boot, UART_init, 'C','N','N', pflag test | reset release → conv2d entry | 16,385 | 16,385 |

- Shares of the inference: layer 1 23.19%, layer 2 72.69%, layer 3 4.09%, overhead 0.03%.
- The arg-max is one instruction inside layer3's bias convoy and is not timed separately.
- Every image gives exactly these counts (the program has no data-dependent branch in the timed windows).
- These are the PRELOAD path. Image 7 over the real UART path (A.3): 54,560 / 49 / 175,659 / 31 / 9,866, inference 240,165.

### C — layer-2 alternatives (design note §8, PROJECTIONS)

`docs/chunked_taps_design.md` §8, model `scripts/chunked_taps_alt_model.py`, output `docs/chunked_taps_alt_model_output.txt`.

**Cost rule ("slot rule"):** a convoy costs its last occupied slot + 10 cycles at vl = 8, or + 18 at vl = 16. It reproduces all six recorded controller counts and the four chunk-test counts below exactly.

Layer 2 = 13x13x16 → 32 filters, 144 taps, bias + ReLU; **ours without pooling**. IISc layer2 measured: 175,674 cycles, **including** the 2x2 max-pool.

| Option | vl | P = 100 (the 10x10 conv outputs the pooling reads) | / IISc 175,674 |
|---|---|---|---|
| B, partial sums spilled (chosen in §3) | 8 / 16 | 299,523 / 229,739 | 1.705 / 1.308 |
| D, Q-pixel tile, accumulators resident for all taps, weights streamed (no spill, no preload) | 8 (Q=11) / 16 (Q=6) | 269,923 / 231,601 | 1.536 / 1.318 |
| D, vl=16, Q=7, two untested assumptions | 16 | 206,495 | 1.175 |
| C, accumulators resident across chunks, weights re-preloaded per tile | 8 (Q=12) | 310,755 | 1.769 |
| F = D + scalar pixel operand (NEW input-buffer datapath, assumed cost-free) | 8 (Q=6) / 16 (Q=6) | 168,367 / 124,177 | 0.958 / 0.707 |

- These are PROJECTIONS; no ratio from this table may be quoted as a result.
- Avoiding the spill does not close the gap. The spill costs 2 slots per pixel per chunk. The input replication costs one load slot per pixel per tap, and only F removes that.

### D — chunk-boundary convoy test, RTL stage 1 (DONE)

**Files:** new `testbench/convoy_chunk_tb.v` and `scripts/run_convoy_chunk.ps1`. No RTL change; `v_wrapper` alone; no DMA, no atee_top. Logs: `sim_build/convoy_chunk_conv8_3.log`, `sim_build/convoy_chunk_distinct.log`.

**Test:**
- conv8_3's 9 taps are split into chunk 0 (taps 0–3) and chunk 1 (taps 4–8), for 3 pixels, run chunk-outer / pixel-inner.
- Run A: preload chunk 0 → per pixel [X X X | MUL MAC MAC], [X | – | MAC | STORE] → partial sums in the output rows.
- All registers poisoned.
- Run B: preload chunk 1 into the same tap registers → per pixel [PSUM | X X X | MAC MAC MAC], [X X | MAC MAC | STORE]. The first MAC reads the partial sum 4 slots after its load.
- Output rows poisoned before run A.
- Controller FSM identical to `convoy_vl16_tb.v`, early clear.

| Run | vl | Run A cycles (slot rule / old model) | Run B cycles (slot rule / old model) | Stall cycles | Partial sums after A | Final after B |
|---|---|---|---|---|---|---|
| 1 | 8, OC group 0 | 106 (106 / 103) | 113 (113 / 113) | 0 | 24/24 | 24/24 |
| 2 | 8, OC group 1 | 106 | 113 | 0 | 24/24 | 24/24 |
| 3 | 16, all 16 OC | 170 (170 / 181) | 177 (177 / 181) | 0 | 48/48 | 48/48 |
| 4 NEG (PSUM slot = running no-op) | 8 | 106 | 113 | 0 | 24/24 | **0/24 (must fail)** |
| 5 NEG | 16 | 170 | 177 | 0 | 48/48 | **0/48 (must fail)** |

Both hex sets give identical results: conv8_3 (`testbench/test1_*.hex`) and the distinct-per-filter set (`sim_build/conv8_3_distinct_data`, mixed-sign outputs). Console (distinct set):

```
    run B (preload taps 4..8 + 3 pixels x chunk 1): FSM cycles 177 (slot-layout rule 177), stall cycles 0
          final output, 9 taps (mem): 16/16 -> PASS
SUMMARY: 192 of 192 compared elements correct -> ALL PASS
NEG SUMMARY (PSUM load removed): 0 of 72 final elements correct (expected: far fewer than 72)
```

- **Exactness:** 192/192 on each set. The partial-sum load in slot 0 and the first MAC reading it 4 slots later through the register file work at vl = 8 and vl = 16, as does weight-register reuse across a chunk boundary. The negative control shows that the result depends on that load.
- **Cycles vs the §4 model (old constants): 2 of 4 equal.**
  - vl = 8 run A: +3. A 1-tap convoy needs a gap slot before its MAC (rule 1); the model's 2n+9 assumed none.
  - vl = 16: −11 / −4. The model charges 23 per convoy regardless of layout; measured, a convoy costs last slot + 18, so short convoys are cheaper and a PSUM convoy, whose MACs move to slots 4–6, is 24.
  - The slot rule equals all four counts.
- §5 projections recomputed with the slot rule change by −3.5% to +1.4% (vl = 16) and 0% to +1.1% (vl = 8). Example: cnn_demo layer 2 vl = 16, 273,705 → 277,577 (P = 121). Both columns are in `docs/chunked_taps_alt_model_output.txt`.
- Not covered by stage 1 (design note §7 items 2–6): remainder chunk of 1–3 taps at vl = 16 as its own chunk, bias as the chunk-0 partial sum, the pooled tile, a full >16-tap layer, Q8.24.
## cnn_demo on ATEE-Lite: scalar-operand study (F), Virtex-7 LUT decomposition (E), CNN build (G) (2026-11-17)

Approved by the user 2026-11-17: F (design note only) first, then E, then G (G1 to G4, each gated) and one Virtex-7 full-chip build of the final design. New files only; existing RTL, scripts and recorded results unchanged.

### F: scalar-operand study (PROJECTION, design note section 10)

`docs/chunked_taps_design.md` section 10; model `scripts/cnn_schedule_model.py`, output `docs/cnn_schedule_model_output.txt`. No RTL, nothing simulated.

- **Mechanism:** the inherited core already has the scalar-operand MAC. With `ALUSrc = "01"`, operand 1 is the slot's own `RS1` (`exe_unit.vhd` op1 case, lines 1488 / 1506 / 1541 / 1579). ATEE has never used it.
- **Missing piece:** the pixel value must be known when the MAC is issued. The host port only reaches DMEM while the vector unit is idle (`exe_unit.vhd:652`). The proposal is therefore a controller-side input buffer (IBUF, 2,704 words, 3 RAMB36), filled through the host port between layers.
- **Schedule F (vl = 16):** 4 window accumulators resident across a 9-tap chunk; weights preloaded; pooling as 3 maxes + ReLU in registers; FC with streamed weights.
- **Untested assumptions:** F-A1 to F-A4 (design note 10.4).

PROJECTED convoy cycles (slot rule), against IISc MEASURED (part B above):

| Layer | IISc measured | B (the schedule G builds), model | F, model | F / IISc |
|---|---|---|---|---|
| 1 | 56,052 | 59,379 | 24,903 | 0.444 |
| 2 | 175,674 | 232,470 | 118,770 | 0.676 |
| 3 (FC + argmax) | 9,883 | 11,658 | 5,040 | 0.510 |
| copies DMEM -> IBUF | | | 3,504 (estimate) | |
| total | 241,689 | 303,507 | 152,217 | 0.630 |

**Recommendation (F):** F is the next build, after G. It is the only schedule that projects below IISc on every layer. Isolated tests come first (F-A1, F-A2). As instructed, G was finished on schedule B without switching.

### E: LUT decomposition on Virtex-7 (same method as "LUT decomposition", Virtex-7 runs)

Inputs: site LUTs, Vivado 2026.1, xc7vx485tffg1761-2, full chip, post-route.
- **ATEE:** Run 1 (vl = 16), `atee_top_vl16` 25,407, `u_vec_unit` 24,305; Run 2 (vl = 8) 24,940 / 23,778.
- **IISc:** Run 3, `FPGA_WRAPPER` 87,259, `cpu1` 85,904, `VECTOR_UNIT` 46,479, and its 8 `GEN_DIVIDERs` rows 23,244 ("Run 3: repo build vs their paper", item 2).

Run 3 is the whole system, so a term (0) for main memory + peripherals + I/O is added. ATEE has none: its host interface is ports.

    vl=16:  total difference                 87,259 - 25,407                 = 61,852
            (0) main memory + periph. + I/O  87,259 - 85,904                 =  1,355   ( 2.19%)
            (1) scalar core -> controller    (85,904 - 46,479) - (25,407 - 24,305)
                                           =  39,425 - 1,102                 = 38,323   (61.96%)
            (2) dividers removed             23,244 - 0                      = 23,244   (37.58%)
            (3) remainder                    (46,479 - 23,244) - 24,305      = -1,070   (-1.73%)
            check                            1,355 + 38,323 + 23,244 - 1,070 = 61,852
    vl=8:   total 62,319 = 1,355 (2.17%) + 38,263 (61.40%) + 23,244 (37.30%) + (-543) (-0.87%)

- **Same picture as on the Artix-7 stand-in** (out of context: 62.6% / 31.2% / 6.2%). The control-logic replacement is the dominant term and the dividers the second. The remainder is small and, on Virtex-7, negative: IISc's vector unit without dividers is 23,235 LUT, while ATEE's `u_vec_unit` is 24,305 (vl = 16) / 23,778 (vl = 8).
- **Basis caveat (as in "Control logic"):** Run 3 carries their 34 exceptions and pin constraints, while ours are clock-only.

**Optional run: IISc FPGA_WRAPPER WITHOUT their timing exceptions (DONE 2026-11-17).**
- **Setup:** `scripts/v7_impl_iisc_noexc.tcl` (copy of the Run 3 script) with `external_2026/iisc_copy/constraints_noexc.xdc` (their `constraints.xdc` with the 34 exceptions and 3 variable lines commented out; clocks and pins as written). Same 2026.1 copy, xmem.coe, xc7vx485tffg1761-2, default directives. All stages done 19:58 -> 22:48. Routing: 134,216 routable nets, 0 with routing errors; log: `V7I EXCEPTIONS post_route: 0 of 0 match`.
- **Utilization, post-route:** 87,814 LUT, 44,331 FF, 399 block RAM tiles, 76 DSP. Run 3 with exceptions: 87,259 LUT.
- **Timing, post-route** (`post_route_timing_summary.rpt`):

```
Clock                     WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)
  clk_out1_clk_wiz_0      -73.335  -260290.047                  32138               102374        0.054
  clk_out2_clk_wiz_0        5.509        0.000                      0                 5104        0.092
From clk_out2 to clk_out1   7.694 ; from clk_out1 to clk_out2   4.705
```

- **Core clock (20 ns):** WNS -73.335 ns, 32,138 of 102,374 endpoints failing. Derived maximum frequency 1000 / 93.335 = 10.71 MHz. Hold met.
- **Worst path:** DMEM6 block RAM (vector scratchpad) -> `cpu1/fdem/Pipeline/FP__RD_Data_Int__EX_MEM_reg[18]`. Datapath 93.275 ns (logic 37.079, route 56.196), 494 levels (386 CARRY4). This is the scalar FPU path that their exceptions declare multicycle. The next two paths end in `FP_EX/OUTPUT__reg_reg[30]` and `FP__RD_Data__EX_MEM_reg[45]`.
- **Reading:**
  - Their exceptions take the core-clock WNS from -73.335 ns (without) to -6.193 ns (with, Run 3). That is why every IISc timing figure must be quoted WITH their exceptions (Run 3).
  - This run is a reference only; it is not their frequency.
  - The decomposition above uses Run 3. With this run's 87,814 LUT, term (0) would change by +555; the run is not used for the decomposition.

### G: cnn_demo on ATEE-Lite, replicated-input + chunked-tap schedule (B)

New files:
- **RTL:** `rtl/vector_unit/hbm_lite_controller_cnn.v`, `rtl/vector_unit/atee_top_cnn.v`.
- **Testbench and scripts:** `testbench/atee_cnn_tb.v`, `scripts/atee_cnn_prep.py`, `scripts/run_atee_cnn.ps1`, `scripts/atee_cnn_check.py`, `scripts/wbtcv_watchdog.ps1`.
- **Build and conditions:** Vivado 2019.1 xsim; BRAM-only, no DMA; ENABLE_DIV = 0; vl = 16; Q8.24.

**Design:**
- **Descriptors:** one 13-word descriptor per layer in DMEM, read by the controller through the host port. The config registers are unchanged: INPUT_BASE = descriptor base, INPUT_C = number of layers, LAYER_START = one start.
- **Chunks:** 9 taps; the bias is the chunk-0 partial sum.
- **Pooling:** 2×2 max-pool in a register (`max(acc, zero)` for the window's first pixel = ReLU).
- **Layer output:** written replicated 16x by strided stores (7 + 7 + 2 per vector, one DMEM bank per slot). This is the next layer's input layout, so no host relayout is needed.
- **FC:** 1x1 convolution with 800 taps, 16 outputs (10 real + 6 with zero weights and bias).
- **Argmax:** the controller reads the 10 scores back through the host port, keeps the first maximum, and writes the class to DMEM and to a port.
- **Scheduling rules:** how each is met is listed in the file header.
- **Inputs:** their compiled ELF's `ker`, `bias`, `ker2`, `bias2`, `w3`, `bias3` (`w3` re-laid out with OC padded 10 -> 16) and the 100 shipped images (byte << 16, as their ISR stores them).
- **DMEM used:** 368,704 of 524,288 bytes.

**G1 — layer 1 (conv 3×3, 16 filters, bias, Q8.24, ReLU, 2×2 max-pool), 100 images: PASS.** Reference: THEIR layer-1 output `Y`, read from their design's DMEM after each image (`sim_build/iisc_bench/cnn_img<k>`; A.1 showed these DMEM images are identical under both stand-in functions).

```
run sim_build\atee_cnn\L1: 100 images checked
  cycles (layer-busy): [59402]
  cfg_error = 0: 100 / 100 ; host writes while busy = 0: 100 / 100
  layer 1 (conv+pool, 13x13x16 = 2704):
    images bit-exact vs THEIR output (all values): 100 / 100 ; values exact 270400 / 270400 ; max |diff| 0
    images bit-exact vs Python reference: 100 / 100 ; values with a bad replica: 0
  images with ANY mismatch: none
```

Console of one run (image 0):

```
  ATEE-Lite CNN controller (vl=16), cnn_demo, 1 layer(s), 14701 DMEM words loaded
  layer-busy cycles (CYCLE_COUNT)   : 59402
  cfg_error                         : 0
  host writes while busy            : 0
CNN_DONE cycles 59402 class 0 err 0 hostwe 0
```

All 16 replicas of every output value were checked (43,264 words per image). "Their arithmetic" holds exactly: Q8.24 product `(a*b) >> 24` (floor, `alu.vhd` `prod(55 downto 24)`), 32-bit wrap-around accumulation, bias added, ReLU, max. No saturation in either design.

**G2, G3, G4: all three layers from ONE start, 100 images: PASS.** These gates were evaluated in order (G2, then G3, then G4) from the same 3-layer runs (`run_atee_cnn.ps1 -Layers 3`, Tag L3, `sim_build/atee_cnn/L3/img<k>`). The testbench writes INPUT_BASE, INPUT_C (= 3) and LAYER_START once. It then makes no host access until layer-busy falls, and counts any host write seen while busy. The per-image DMEM load writes only non-zero words (DMEM starts all-zero in simulation).

`python scripts/atee_cnn_check.py sim_build\atee_cnn\L3`:

```
run sim_build\atee_cnn\L3: 100 images checked
  cycles (layer-busy): [303601]
  per-layer cycles: [(59401, 232495, 11705)]
  per-layer cycles in convoy states (ISSUE/WAIT/NEXT): [(59379, 232470, 11658)]
  cfg_error = 0: 100 / 100 ; host writes while busy = 0: 100 / 100
  layer 1 (conv+pool, 13x13x16 = 2704):
    images bit-exact vs THEIR output (all values): 100 / 100 ; values exact 270400 / 270400 ; max |diff| 0
    images bit-exact vs Python reference: 100 / 100 ; values with a bad replica: 0
  layer 2 (conv+pool, 5x5x32 = 800):
    images bit-exact vs THEIR output (all values): 100 / 100 ; values exact 80000 / 80000 ; max |diff| 0
    images bit-exact vs Python reference: 100 / 100 ; values with a bad replica: 0
  FC scores: images with all 10 bit-exact vs reference: 100 / 100 ; padded outputs 10..15 = 0: 100 / 100
  class: port == memory: 100 / 100 ; == reference argmax: 100 / 100
  CORRECT vs label: ATEE 99 / 100 ; reference 99 / 100 ; THEIR design 87 / 100
  ATEE misses (image, label, class): [(18, 5, 8)]
  THEIR misses (image, label, digit): [(7, 9, 4), (9, 9, 7), (12, 9, 7), (16, 9, 7), (20, 9, 7), (58, 9, 7), (61, 8, 0), (62, 9, 5), (73, 9, 7), (78, 9, 0), (84, 8, 0), (92, 9, 4), (99, 9, 7)]
  images with ANY mismatch: none
```

Console of one run (image 7; their design classifies it as 4, ATEE as 9 = label):

```
  ATEE-Lite CNN controller (vl=16), cnn_demo, 3 layer(s), 14909 DMEM words loaded
  layer-busy cycles (CYCLE_COUNT)   : 303601
  layer 1: start at +0, cycles 59401 (convoy states 59379, other 22)
  layer 2: start at +59401, cycles 232495 (convoy states 232470, other 25)
  layer 3: start at +291896, cycles 11705 (convoy states 11658, other 47)
  cfg_error                         : 0
  cnn_class                         : 9
  host writes while busy            : 0
CNN_DONE cycles 303601 class 9 err 0 hostwe 0
```

- **G2:** layer-2 output (16 input channels × 9 taps = 144 taps in 16 chunks, bias, Q8.24, ReLU, max-pool) is bit-exact against THEIR `Y2` on 100 / 100 images (80,000 / 80,000 values, all 16 replicas consistent).
- **G3:** the FC is a 1×1 convolution, 800 taps, padded to 16 outputs; vl is always 16, never 10. All 10 scores are bit-exact against the Python reference on 100 / 100 images, and the 6 padded outputs are 0 on 100 / 100. Class = reference argmax on 100 / 100. **ATEE 99 / 100 correct** (the one miss, image 18, label 5 -> 8, is also the reference's miss). **Their released design: 87 / 100** (13 misses, all labels 8 / 9, the vl = 10 write-gate hazard, part A.2).
- **G4:** one start; cfg_error 0 and host writes while busy 0 on 100 / 100. The controller chains the three layers from the descriptors alone. Layer-busy is 303,601 cycles on every image.

**Per-layer cycles (MEASURED, identical on all 100 images), against the corrected model and against IISc (part B, MEASURED, preload path):**

| Layer | ATEE measured, layer total | of which convoy states | slot-rule model (`cnn_schedule_model.py`, schedule B) | other (descriptor fetch, init, layer end; argmax in layer 3) | IISc measured | ATEE / IISc |
|---|---|---|---|---|---|---|
| 1 conv+pool | 59,401 | 59,379 | 59,379 | 22 | 56,052 | 1.060 |
| 2 conv+pool | 232,495 | 232,470 | 232,470 | 25 | 175,674 | 1.323 |
| 3 FC+argmax | 11,705 | 11,658 | 11,658 | 47 | 9,883 | 1.184 |
| total per image | 303,601 | 303,507 | 303,507 | 94 | 241,689 (incl. 80 overhead) | 1.256 |

- **Model:** the slot-rule model predicts the convoy-state cycles EXACTLY in all three layers (0 cycles difference). The fixed per-layer cost (22 / 25 / 47) is not in the model.
- **Windows differ, as before:**
  - Ours is the controller's layer-busy time, with no host action.
  - Theirs is software (per-layer function windows on a scalar core; the total includes their 80 cycles of call overhead).
  - Both exclude loading the image.
- **At 50 MHz:** ATEE 303,601 cycles = 6,072.02 µs per image, against their 241,689 = 4,833.78 µs (their design does not meet 50 MHz on Virtex-7; see "Virtex-7 XC7VX485T"). On this schedule ATEE is SLOWER than IISc on every layer, by 25.6% in total. This matches the projections of design note section 8 (schedule B): input replication, not the spill, is the cost.
- **Scalar-operand path (F):** it projects 152,217 cycles (0.630× IISc, PROJECTION, section F above). Not built; per the instruction, G was finished on schedule B first.

Resources: see "G: Virtex-7 full-chip build" below.

### G: Virtex-7 full-chip build of the CNN design (DONE 2026-11-17)

- **Setup:** `scripts/v7_impl_atee_cnn.tcl` (copy of the Run 1 / Run 2 script), Vivado 2026.1, xc7vx485tffg1761-2, top `atee_top_cnn`, ENABLE_DIV = 0, 20 ns clock on `clk` only, no exceptions, default directives. Launched detached on mains power after the IISc no-exceptions run; one implementation at a time. Stages 22:49 -> 23:16. Routing: 38,679 routable nets, 0 with routing errors.
- **Timing:** WNS **+2.313 ns** (met), TNS 0, 0 of 30,723 endpoints failing; WHS +0.085 ns. Derived maximum frequency 1000 / (20 - 2.313) = **56.54 MHz**. Worst path inside the inherited vector unit: `EXE_MEM_v0_DATA_reg[1][22]` -> `EXE_MEM_ALU_y_reg[3][31]`, datapath 17.745 ns, 26 levels. It is not in the controller.

| post-route, V7 | atee_top_vl16 (Run 1) | atee_top_cnn | delta |
|---|---|---|---|
| Slice LUTs | 25,407 | 25,028 | -379 |
| Slice Registers | 15,166 | 15,621 | +455 |
| Block RAM tiles | 128 | 128 | 0 |
| DSP48E1 | 61 | 54 | -7 |
| u_config LUT / FF | 412 / 577 | 263 / 577 | -149 / 0 |
| controller (u_hbm_lite) LUT / FF / DSP | 731 / 346 / 18 | 1,555 / 807 / 11 | +824 / +461 / -7 |
| u_vec_unit LUT / FF / BRAM / DSP | 24,305 / 14,243 / 128 / 43 | 23,259 / 14,237 / 128 / 43 | -1,046 / -6 / 0 / 0 |
| WNS (derived max frequency) | +1.810 ns (55.28 MHz) | +2.313 ns (56.54 MHz) | |

- **Controller:** the CNN controller is +824 LUT / +461 FF over the vl = 16 controller. That buys descriptor fetch, three-layer sequencing, chunking, pooling, replication stores and argmax.
- **Vector unit:** its RTL is identical in both builds (same `v_wrapper` sources), yet its row is 1,046 LUT smaller here. The cause is NOT investigated: implementation variation with a different surrounding design, or optimisation of inputs the CNN controller drives as constants, are both possible. The total LUT figure therefore must not be read as "the CNN design is smaller".
- **Per-layer resources:** none. One controller serves all three layers, so the delta above is the only resource delta.

## Scalar-operand variant (SC): CONV2D 3x3 and cnn_demo without input replication (2026-11-17/18)

Approved by the user 2026-11-17: "If YES (no vector-unit change): build it as a NEW variant (new files; keep the replicated-input design and all its results). Same gates as G, in order." Everything below uses new files only. The replicated-input design (G) and all its results are unchanged.

### Item 1: can the controller supply the scalar operand with the vector unit UNMODIFIED? YES

- **The scalar operand already exists in the vector unit:** with `ALUSrc = "01"`, operand 1 of slot i is that slot's own `RS1` (`exe_unit.vhd`, op1 case at lines 1488 / 1506 / 1541 / 1579, all slots).
- **The controller can already drive it:** `ALUSrc` and `RS1` reach that point from the controller through `atee_top` -> `v_wrapper.v:92` -> `wrapper.vhd:115`.
- **The one missing piece is controller-side:** the pixel value must come from a controller-side input buffer (IBUF, new `ibuf_ram.v` in the new top). No file of the vector unit is changed; the build reads the same `rtl/vector_unit/*.vhd` and `v_wrapper.v`.

### Step 1: isolated tests on v_wrapper alone (F-A1, F-A2, part of F-A3): PASS

`testbench/convoy_scalar_tb.v`, `scripts/run_convoy_scalar.ps1`, Vivado 2019.1 xsim.
- **Setup:** vl = 16, the same mini controller as `convoy_chunk_tb.v` (all 8 slots issued, slot 7 re-driven unchanged including its RS1, early clear 16 cycles after the last real slot). Random mixed-sign data; registers poisoned before every test, then the zero pair v9/v10 restored to 0 by one load convoy (the controllers never write it); output rows poisoned. Every test ran at Q32.0 and at Q8.24.
- **First run:** T2a / T2c / T3 failed because the poisoning also overwrote the zero register used by ReLU. The stored values were the poison pattern, and at Q8.24 only results above the poison came out right. This was a testbench setup error; the restore convoy was added and the run below is the re-run.

```
=== T1 (F-A2): [L acc | - - - | MACX s0 | MACX s1 | S acc | -], vl=16, quant 0 ===
                       T1 psum + s0*W + s1*W: 16/16 -> PASS ; FSM cycles 42 (slot rule 42), stall cycles 0
                           T2a pooled + ReLU: 16/16 -> PASS ; FSM cycles 207 (slot rule 207), stall cycles 0
                          T2b 4 partial sums: 64/64 -> PASS ; FSM cycles 206 (slot rule 206), stall cycles 0
                          T2c 4 outputs ReLU: 64/64 -> PASS ; FSM cycles 227 (slot rule 227), stall cycles 0
                         T3 FC stream + ReLU: 16/16 -> PASS ; FSM cycles 116 (slot rule 116), stall cycles 0
=== T1 (F-A2): [L acc | - - - | MACX s0 | MACX s1 | S acc | -], vl=16, quant 3 ===
                       T1 psum + s0*W + s1*W: 16/16 -> PASS ; FSM cycles 42 (slot rule 42), stall cycles 0
                           T2a pooled + ReLU: 16/16 -> PASS ; FSM cycles 207 (slot rule 207), stall cycles 0
                          T2b 4 partial sums: 64/64 -> PASS ; FSM cycles 206 (slot rule 206), stall cycles 0
                          T2c 4 outputs ReLU: 64/64 -> PASS ; FSM cycles 227 (slot rule 227), stall cycles 0
                         T3 FC stream + ReLU: 16/16 -> PASS ; FSM cycles 116 (slot rule 116), stall cycles 0
SUMMARY: 352 of 352 compared elements correct -> ALL PASS
                          NEG T2a, must FAIL: 1/16 -> FAIL ; FSM cycles 207 (slot rule 207), stall cycles 0
NEG SUMMARY (MACX with ALUSrc = 00): 1 of 16 elements correct (expected: far fewer than 16)
```

- **T2:** the exact window op stream of schedule F (4 accumulator loads, 36 scalar MACs in accumulator order 0,1,2,3, so each MAC reads its accumulator 4 slots back, then the pooling / ReLU / store tails). 0 stall cycles everywhere, and the cycles equal the slot rule.

### The build

New files:
- **RTL:** `rtl/vector_unit/hbm_lite_controller_sc.v`, `rtl/vector_unit/atee_top_sc.v` (copy of `atee_top_cnn.v` plus the IBUF and a host write window at 0x0030_0000), `rtl/vector_unit/ibuf_ram.v` (4,096 × 32).
- **Testbench:** `testbench/atee_sc_tb.v` (copy of `atee_cnn_tb.v`; only the top differs).
- **Scripts:** `scripts/atee_sc_prep.py`, `scripts/run_atee_sc.ps1`, `scripts/atee_sc_check.py`.
- **Model:** `scripts/sc_schedule_model.py` (imports `cnn_schedule_model.py` unchanged).
- **Conditions:** BRAM-only, no DMA, ENABLE_DIV = 0, vl = 16, Vivado 2019.1 xsim.

Schedule, as in design note section 10.3:
- **Window mode:** per OC group and per 9-tap chunk, the weights are preloaded; then per window of 4 output pixels the op stream runs [4 × acc load | 4·taps scalar MACs | tail]. The window is the 2×2 pool window, or 4 consecutive pixels without pooling. The stream is packed 8 slots per convoy, window-aligned, with a store never in slot 7.
- **Stream mode** (one output pixel: the FC): [bias | W W W | MAC × 3], then [W × 4 | MAC × 4], then [ReLU | store].
- **Inputs:** the input value is the MAC's RS1, read from the IBUF one cycle ahead. The first layer's input is written into the IBUF by the host. Later layers' inputs are copied DMEM -> IBUF by the controller (descriptor flag COPY, 1 word per cycle, n + 2 cycles). Outputs are stored once, unit-stride. No strided or broadcast access remains.
- **Limits (cfg_error):** OC a multiple of 16; H·W·IC ≤ 4,096; without pooling, the output pixels must be a multiple of 4 or exactly 1.

Development bug, found and fixed before any recorded run: the first conv8_3 run gave 16 / 576 with the cycles already equal to the model. The window-0 pixel bases came from a continuous assignment calling a function that read module registers; Verilog does not re-evaluate such an assignment when those registers change. The fix passes them as function arguments. All results below are from the fixed RTL.

### Gate 1: CONV2D 3x3, their conv8_3 .. conv64_3: PASS

`run_atee_sc.ps1 -Mode conv -Size S [-Distinct]`; check `python scripts/atee_sc_check.py conv ...`:

```
conv8: cycles 1398 (convoy states [1374]), cfg_error 0, hostwe 0 ; outputs exact vs reference 576 / 576 ; vs THEIR expected_output 576 / 576
conv16: cycles 7238 (convoy states [7214]), cfg_error 0, hostwe 0 ; outputs exact vs reference 3136 / 3136 ; vs THEIR expected_output 3136 / 3136
conv32: cycles 32934 (convoy states [32910]), cfg_error 0, hostwe 0 ; outputs exact vs reference 14400 / 14400 ; vs THEIR expected_output 14400 / 14400
conv64: cycles 140390 (convoy states [140366]), cfg_error 0, hostwe 0 ; outputs exact vs reference 61504 / 61504 ; vs THEIR expected_output 61504 / 61504
conv8_distinct: cycles 1398 (convoy states [1374]), cfg_error 0, hostwe 0 ; outputs exact vs reference 576 / 576
conv16_distinct: cycles 7238 (convoy states [7214]), cfg_error 0, hostwe 0 ; outputs exact vs reference 3136 / 3136
conv32_distinct: cycles 32934 (convoy states [32910]), cfg_error 0, hostwe 0 ; outputs exact vs reference 14400 / 14400
conv64_distinct: cycles 140390 (convoy states [140366]), cfg_error 0, hostwe 0 ; outputs exact vs reference 61504 / 61504
```

| Size | SC measured (layer busy) | of which convoy states | model (`sc_schedule_model.py`) | IISc measured | vl = 16 controller measured | SC / IISc | SC / vl=16 |
|---|---|---|---|---|---|---|---|
| 8 | 1,398 | 1,374 | 1,374 | 3,181 | 2,599 | 0.4395 | 0.5379 |
| 16 | 7,238 | 7,214 | 7,214 | 15,033 | 13,799 | 0.4815 | 0.5245 |
| 32 | 32,934 | 32,910 | 32,910 | 67,009 | 63,079 | 0.4915 | 0.5221 |
| 64 | 140,390 | 140,366 | 140,366 | 284,140 | 269,159 | 0.4941 | 0.5216 |

- **Model:** it predicts the convoy cycles exactly at every size; the fixed cost is 24 cycles per layer.
- **IISc and vl = 16 figures:** from "CONV2D 3x3 at image sizes 8 / 16 / 32 / 64" and "vl=16 controller (2026-11-11)"; the windows are as there.
- **Input memory:** the vl = 16 controller needs the input replicated 16× in DMEM (S²·16 words, 65,536 words = 256 KB at 64×64). SC keeps S² words in the IBUF (4,096 words = 16 KB at 64×64) and none in DMEM.

### Gate 2: cnn_demo, all three layers from ONE start, 100 images: PASS

`run_atee_sc.ps1 -Mode cnn -Layers 3 -From a -To b -Tag L3` (three detached runners); check `python scripts/atee_sc_check.py cnn sim_build\atee_sc\L3`:

```
run sim_build\atee_sc\L3: 100 images checked
  cycles (layer-busy): [152318]
  per-layer cycles: [(24926, 121502, 5890)]
  per-layer cycles in convoy states (ISSUE/WAIT/NEXT): [(24903, 118770, 5040)]
  cfg_error = 0: 100 / 100 ; host writes while busy = 0: 100 / 100
  layer 1 (13x13x16 = 2704): images bit-exact vs THEIR output 100 / 100 (values 270400 / 270400) ; vs reference 100 / 100
  layer 2 (5x5x32 = 800): images bit-exact vs THEIR output 100 / 100 (values 80000 / 80000) ; vs reference 100 / 100
  FC scores: all 10 bit-exact vs reference 100 / 100 ; padded outputs 10..15 = 0: 100 / 100
  class: port == memory 100 / 100 ; == reference argmax 100 / 100
  CORRECT vs label: ATEE-SC 99 / 100 ; reference 99 / 100 ; THEIR design 87 / 100
  ATEE-SC misses (image, label, class): [(18, 5, 8)]
  images with ANY mismatch: none
```

Console of one run (image 7; their design gives 4, label 9):

```
  ATEE-Lite scalar-operand controller (vl=16), 3 layer(s), 13628 DMEM words loaded
  layer-busy cycles (CYCLE_COUNT)   : 152318
  layer 1: start at +0, cycles 24926 (convoy states 24903, other 23)
  layer 2: start at +24926, cycles 121502 (convoy states 118770, other 2732)
  layer 3: start at +146428, cycles 5890 (convoy states 5040, other 850)
  cfg_error                         : 0
  cnn_class                         : 9
  host writes while busy            : 0
CNN_DONE cycles 152318 class 9 err 0 hostwe 0
```

(The "DMEM words loaded" line counts every host write, including the 784 IBUF words.)

**Per-layer cycles (MEASURED, identical on all 100 images):**

| Layer | SC measured | of which convoy states | design-note projection (section 10.5) | other: copy (n + 2) + fixed | IISc measured | replicated-input build (G) | SC / IISc | SC / G |
|---|---|---|---|---|---|---|---|---|
| 1 conv+pool | 24,926 | 24,903 | 24,903 | 23 (no copy) | 56,052 | 59,401 | 0.4447 | 0.4196 |
| 2 conv+pool | 121,502 | 118,770 | 118,770 | 2,732 = 2,706 + 26 | 175,674 | 232,495 | 0.6916 | 0.5226 |
| 3 FC+argmax | 5,890 | 5,040 | 5,040 | 850 = 802 + 48 | 9,883 | 11,705 | 0.5960 | 0.5032 |
| total per image | 152,318 | 148,713 | 148,713 + 3,504 copy (estimate) | 3,605 | 241,689 | 303,601 | 0.6302 | 0.5017 |

- **Projection held:** the design-note projection of section 10.5, made before any RTL, is met EXACTLY in the convoy states. The two copies take 3,508 cycles against the 3,504 estimate (+2 cycles of pipeline each).
- **At 50 MHz:** 152,318 cycles = 3,046.36 µs per image, against IISc 4,833.78 µs (their design does not meet 50 MHz on Virtex-7, see "Virtex-7 XC7VX485T"). Windows as in G: our layer-busy time vs their software function windows; both exclude the image load.
- **SC is faster than IISc on every layer** (0.44 / 0.69 / 0.60, 0.630 overall) and about half of G's cycles.

**Memory saved by removing input replication (cnn_demo):**

| | G (replicated input) | SC |
|---|---|---|
| layer inputs | replicated 16× in DMEM: 12,544 + 43,264 + 12,800 = 68,608 words (274,432 B) | IBUF (on-chip, controller): 784 / 2,704 / 800 words, max 2,704 (IBUF size 4,096 words = 16 KB) |
| layer outputs | written replicated (= next input) | 2,704 + 800 + 16 words, plain, in DMEM |
| DMEM used (layout extent) | 368,704 B | 97,536 B (0x17D00) |
| host writes per image | 14,909 (non-zero DMEM words) | 13,628 (non-zero DMEM words + 784 IBUF words) |

Most of the remaining DMEM is weights (W2 18 KB, W3 padded 50 KB).

### SC: Virtex-7 full-chip build

`scripts/v7_impl_atee_sc.tcl` (copy of `v7_impl_atee_cnn.tcl`, plus `ibuf_ram`), launched detached on mains power. One implementation at a time; simulation batches were running alongside, so synthesis took 39 min instead of about 15.
- **Setup:** Vivado 2026.1, xc7vx485tffg1761-2, top `atee_top_sc`, ENABLE_DIV = 0, 20 ns clock on `clk` only, no exceptions, default directives. Stages 2026-11-17 23:45 -> 2026-11-18 00:34. Routing: 39,609 routable nets, 0 with routing errors.
- **Timing:** WNS **+2.492 ns** (met), TNS 0, 0 of 31,884 endpoints failing; WHS +0.041 ns. Derived maximum frequency 1000 / (20 - 2.492) = **57.12 MHz**. Worst path inside the inherited vector unit: `EXE_MEM_counts_reg[0][0]` -> `EXE_MEM_ALU_y_reg[1][15]`, datapath 17.469 ns, 23 levels. It is not in the controller or the IBUF.

| post-route, V7 | atee_top_vl16 (Run 1) | atee_top_cnn (G) | atee_top_sc | SC - G |
|---|---|---|---|---|
| Slice LUTs | 25,407 | 25,028 | 25,419 | +391 |
| Slice Registers | 15,166 | 15,621 | 15,838 | +217 |
| Block RAM tiles | 128 | 128 | 132 | +4 (the IBUF, 4,096 × 32; by subtraction: `u_vec_unit` holds 128) |
| DSP48E1 | 61 | 54 | 65 | +11 |
| controller (u_hbm_lite) LUT / FF / DSP | 731 / 346 / 18 | 1,555 / 807 / 11 | 1,954 / 1,025 / 22 | +399 / +218 / +11 |
| u_vec_unit LUT / FF / BRAM / DSP | 24,305 / 14,243 / 128 / 43 | 23,259 / 14,237 / 128 / 43 | 23,256 / 14,236 / 128 / 43 | -3 / -1 / 0 / 0 |
| WNS (derived max frequency) | +1.810 ns (55.28 MHz) | +2.313 ns (56.54 MHz) | +2.492 ns (57.12 MHz) | |

- **Controller cost:** the SC controller is +399 LUT / +218 FF / +11 DSP over G's. That covers IBUF addressing, the window / stream sequencing and the copy engine; the +11 DSP are the address multiplies. Against the 731-LUT vl = 16 controller it is +1,223 LUT. The estimate in design note 10.6 (+150 to +300 LUT over B) was LOW.
- **IBUF:** 4 block RAM tiles.
- **Vector unit:** its row equals G's (23,256 vs 23,259 LUT); the Run 1 difference noted under G remains uninvestigated.
- **Per-layer resources:** none; one controller runs all layers.

## Main design: scalar-operand variant (SC). Area, power, paper rows (2026-11-19)

User decision 2026-11-19: SC is the paper's main design; vl=16 (replicated input) and G become development rows, with all their results kept. Everything below measures SC on the same basis as the earlier designs. New files only; no RTL changed.

### 1. Control logic and LUT decomposition on Virtex-7 (same method as "Control logic, same subtraction method" and E)

Inputs: SC full-chip build ("SC: Virtex-7 full-chip build", `post_route_utilization_hier.rpt`): total 25,419, `u_vec_unit` 23,256, `u_config` 258, `u_hbm_lite` 1,954, IBUF 4 RAMB36 at the top level (0 LUT at the top level). IISc Run 3: `FPGA_WRAPPER` 87,259, `cpu1` 85,904, `VECTOR_UNIT` 46,479, its dividers 23,244.

| Design | Method | Value |
|---|---|---|
| IISc, Virtex-7 full system | `cpu1` − `VECTOR_UNIT` (Run 3) | 39,425 LUT |
| ATEE SC, Virtex-7 full chip | total − `u_vec_unit` (same run) | **2,163 LUT** (row sum `u_config` + `u_hbm_lite` = 258 + 1,954 = 2,212; the 49 LUT difference is cross-hierarchy LUT combining) |
| ATEE vl=16 / vl=8, for reference | same | 1,102 / 1,162 |

- **The controller includes the IBUF logic.** The IBUF's read and write addressing and the copy engine are in `u_hbm_lite`. The IBUF itself is 4 block RAM tiles with no LUTs.
- **IISc / SC control logic:** 39,425 / 2,163 = **18.227**. vl=16 gave 35.78 (#22). The SC controller is about twice the vl=16 controller's size.

LUT decomposition, SC against Run 3:

    total difference                 87,259 - 25,419                    = 61,840
    (0) main memory + periph. + I/O  87,259 - 85,904                    =  1,355   ( 2.19%)
    (1) scalar core -> controller    39,425 - 2,163                     = 37,262   (60.26%)
        (controller incl. the IBUF addressing and copy logic)
    (2) dividers removed             23,244 - 0                         = 23,244   (37.59%)
    (3) remainder                    (46,479 - 23,244) - 23,256         =    -21   (-0.03%)
    check                            1,355 + 37,262 + 23,244 - 21       = 61,840

- **Same picture as vl=16** (E: 2.19 / 61.96 / 37.58 / −1.73%). The SC vector unit row (23,256) is within 21 LUT of IISc's vector unit without dividers (23,235).
- **LUTs, IISc `cpu1` / SC full chip:** 85,904 / 25,419 = 3.3795 (vl=16: 3.3811, #24).
- Basis caveat as before: ours clock-only, theirs with their 34 exceptions and pin constraints.

### 2. Power on Virtex-7, both methods (conv8_3 and cnn_demo image 0)

Checkpoint: the routed SC full-chip build (`synth_build_2026/v7_xc7vx485t/atee_sc/post_route.dcp`). IISc: Run 3. 50 MHz nominal; IISc fails 50 MHz (WNS −6.193 ns). cnn_demo image 0 (label 7) on both designs; it is classified 7 by both.

**Flows, as before** ("Virtex-7 power (2026-11-14)" and "RTL-SAIF method"):
- **netlist-SAIF:** 2026.1 `write_verilog -mode funcsim` (`scripts/v7_power_export_dcp.tcl`) → 2019.1 xsim (unmodified install) with `testbench/v7_sc_netlist_tb.v` (copy of `atee_sc_tb.v`: no parameter override, no state probe). Every hierarchical cell is logged with `current_scope` (dut + 58 of 58; 49,448 nets/ports) → 2026.1 `report_power`. Driver `scripts/v7_power_atee_sc.ps1`. The netlist has 50,362 primitive cells.
- **RTL-SAIF:** 2026.1 xsim of the RTL with `atee_sc_tb.v`, `get_objects -r` below dut (1,587 objects; excluded: the 8 DMEM arrays as before, plus the IBUF array `u_ibuf/mem`, which has no netlist nets either) → `read_saif` on the routed checkpoint. Driver `scripts/v7_rtlsaif_atee_sc.ps1`.
- **IISc cnn_demo (RTL-SAIF):** the same 2026.1 build as their conv8_3 RTL-SAIF run (`scripts/v7_rtlsaif_iisc.ps1`'s compile lists and IP simulation files, reused). Differences: testbench `external/iisc_sim/iisc_tb_bench26.v` (copy of `iisc_tb_bench.v`: the image preload goes into `mainMem.mif`, `scripts/iisc_cnn26_helper.py`), and the cnn_demo memory images from its ELF (= the shipped .coe). Driver `scripts/v7_rtlsaif_iisc_cnn.ps1`. Window: conv2d entry → layer3 return (the inference). 37,261 objects logged, none excluded.

**Window trigger (new, validated).** The cnn_demo windows are 152k and 242k cycles. With the earlier scripts' 20 ns Tcl steps the IISc run would have taken about 7 h, so the cnn_demo runs use `testbench/v7_saif_cond.tcl` / `v7_saif_cond_seg.tcl` (new). These open and close the window with xsim conditions (`add_condition … stop`) on the same signals, log the same objects, and let the simulator run at kernel speed in between. The edges fall at the delta where the signal changes (10 ns earlier than the step method). `_seg` writes one SAIF per layer in one run, split where `cur_layer` changes (the testbench's own layer boundaries). Validation on conv8_3, same checkpoint:

| conv8_3 | stepped (driver scripts above) | condition-triggered | |
|---|---|---|---|
| netlist-SAIF total / dynamic | 0.486 / 0.235 W, 100% matched | 0.486 / 0.235 W, 100% matched | identical |
| RTL-SAIF total / dynamic | 0.595 / 0.342 W, 3% matched | 0.595 / 0.342 W, 3% matched | identical |
| window | 5,000 → 32,960 ns = 1,398 cycles | 4,990 → 32,950 ns = 1,398 cycles | same length |

The multi-SAIF report script (`scripts/v7_power_report_multi.tcl`: checkpoint opened once, `reset_switching_activity -all` before each `read_saif`) reproduces the conv8_3 RTL-SAIF figure (0.595 / 0.342 W) when given that SAIF first. The stepped cnn_demo runs were stopped and replaced by the condition-triggered ones; none of their output is used.

**Gates: PASS for all runs.**

```
netlist-SAIF conv8_3:   conv8: cycles 1398 (convoy states [0]), cfg_error 0, hostwe 0 ; outputs exact vs reference 576 / 576 ; vs THEIR expected_output 576 / 576
RTL-SAIF conv8_3:       conv8: cycles 1398 (convoy states [1374]), cfg_error 0, hostwe 0 ; outputs exact vs reference 576 / 576 ; vs THEIR expected_output 576 / 576
netlist-SAIF cnn img 0: CS segment 1 -> layer_seg1.saif : 273210100 ps .. 771730100 ps
                        CS segment 2 -> layer_seg2.saif : 771730100 ps .. 3201770100 ps
                        CS segment 3 -> layer_seg3.saif : 3201770100 ps .. 3319570100 ps
                        CNN_DONE cycles 152318 class 7 err 0 hostwe 0
  layer 1 (13x13x16 = 2704): images bit-exact vs THEIR output 1 / 1 (values 2704 / 2704) ; vs reference 1 / 1
  layer 2 (5x5x32 = 800): images bit-exact vs THEIR output 1 / 1 (values 800 / 800) ; vs reference 1 / 1
  FC scores: all 10 bit-exact vs reference 1 / 1 ; padded outputs 10..15 = 0: 1 / 1
  CORRECT vs label: ATEE-SC 1 / 1 ; reference 1 / 1 ; THEIR design 1 / 1
RTL-SAIF cnn img 0:     same check, per-layer cycles (24926, 121502, 5890), all exact, class 7; segments 24,926 / 121,502 / 5,890 cycles
IISc RTL-SAIF cnn img 0 (2026.1) against their 2019.1 run of the same image:
  dump.txt 2026.1: W 0 16385 72437 1099840 | W 1 72486 248160 1110656 | W 2 248191 258074 7 | ...
  dump.txt 2019.1: W 0 16385 72437 1099840 | W 1 72486 248160 1110656 | W 2 248191 258074 7 | ...
  windows identical: True
  dmem: 131072 of 131072 words identical to the 2019.1 run
  vrf: 256 of 256 words identical to the 2019.1 run
  CS window closes at 5162077500 ps (opened at 328297500 ps)   -> 241,689 cycles; digit (x10) 7
```

(The netlist testbench prints "convoy states 0": it has no state probe.)

**netlist-SAIF results, SC (100% of design nets matched, confidence High):**

| Window | Cycles (µs) | Total W | Dynamic W | Static W | Clocks / slice / signals / BRAM / DSP (W) | Dynamic by hierarchy: `u_vec_unit` / `u_hbm_lite` / `u_ibuf` / `u_config` | Energy total / dynamic (µJ) |
|---|---|---|---|---|---|---|---|
| conv8_3 (layer busy) | 1,398 (27.96) | 0.486 | 0.235 | 0.252 | 0.033 / 0.027 / 0.042 / 0.132 / <0.001 | 0.225 / 0.004 / 0.004 / 0.001 | **13.58856 / 6.57060** |
| cnn_demo layer 1 | 24,926 (498.52) | 0.598 | 0.346 | 0.252 | 0.033 / 0.067 / 0.108 / 0.133 / 0.005 | 0.336 / 0.004 / 0.004 / 0.001 | 298.11496 / 172.48792 |
| cnn_demo layer 2 | 121,502 (2,430.04) | 0.620 | 0.368 | 0.253 | 0.033 / 0.071 / 0.119 / 0.135 / 0.009 | 0.358 / 0.005 / 0.004 / 0.001 | 1,506.62480 / 894.25472 |
| cnn_demo layer 3 | 5,890 (117.80) | 0.589 | 0.337 | 0.252 | 0.033 / 0.059 / 0.103 / 0.135 / 0.007 | 0.327 / 0.004 / 0.004 / 0.001 | 69.38420 / 39.69860 |
| **cnn_demo per image** (sum of layers) | 152,318 (3,046.36) | (0.615 average) | (0.363 average) | | | | **1,874.12396 / 1,106.44124** |

- **Against the vl=16 design, conv8_3, same method** ("Virtex-7 power (2026-11-14)"): SC dynamic energy 6.57060 µJ vs 13.09896 µJ = 0.501612; total 13.58856 vs 26.19792 = 0.518689. Dynamic power is about the same (0.235 vs 0.252 W); the energy halves with the cycles.
- **cnn_demo draws more power than conv8_3** (0.35–0.37 W vs 0.235 W dynamic): signals and slice logic are 2.5× higher. The cnn_demo data is Q8.24 with real image values, and its layer 2 runs denser convoys; conv8_3 uses small integers.
- Energies come from power figures reported to 3 decimals. They exclude loading the IBUF / DMEM and reading results back. Static power is the XC7VX485T's.

**RTL-SAIF results, SC and IISc (confidence Medium):**

| Window | Cycles (µs) | Total W | Dynamic W | Static W | Nets matched | Registers / BRAM en / BRAM wr-en / DSP from SAIF | Energy total / dynamic (µJ) |
|---|---|---|---|---|---|---|---|
| SC conv8_3 | 1,398 (27.96) | 0.595 | 0.342 | 0.252 | 3% (1,692 of 55,017) | 1.9% / 1.5% / 4.0% / 0.6% | 16.63620 / 9.56232 |
| SC cnn_demo image, whole-image SAIF | 152,318 (3,046.36) | 0.605 | 0.353 | 0.252 | 3% (1,692 of 55,017) | 1.9% / 1.5% / 4.0% / 0.6% | **1,843.04780 / 1,075.36508** |
| SC cnn_demo layers 1 / 2 / 3 (segment SAIFs) | 24,926 / 121,502 / 5,890 | 0.602 / 0.605 / 0.610 | 0.350 / 0.353 / 0.358 | 0.252 | 3% | as above | 300.10904 / 1,470.17420 / 71.85800 total; 174.48200 / 857.80412 / 42.17240 dynamic (sum 1,074.45852 dynamic) |
| IISc conv8_3, conv2d() (recorded, "RTL-SAIF method") | 3,181 (63.62) | 0.975 | 0.706 | 0.269 | 8% | 10.5% / 0% / 26.9% / 5.8% | 62.02950 / 44.91572 |
| **IISc cnn_demo image, inference** (conv2d entry → layer3 return) | 241,689 (4,833.78) | 1.015 | 0.744 | 0.272 | 8% (14,594 of 191,553) | 10.5% / 0% / 26.9% / 5.8% | **4,906.28670 / 3,596.33232** |

IISc cnn_demo by type: clocks 0.094, slice logic 0.158, signals 0.273, block RAM 0.094, MMCM 0.107, DSP 0.014, I/O 0.004 W.

**Same-method ratios (RTL-SAIF both sides):**
- **cnn_demo, per image, dynamic:** SC 1,075.36508 / IISc 3,596.33232 µJ = **0.299017** (0.298765 with the sum of SC's per-layer SAIFs). Total: 1,843.04780 / 4,906.28670 = 0.375650.
- **conv8_3, per layer, dynamic:** SC 9.56232 / IISc 44.91572 µJ = **0.212895**. Total: 16.63620 / 62.02950 = 0.268198.
- **Caveats:**
  - the windows differ (our layer-busy vs their function window);
  - the match shares are low and differ (3% vs 8%);
  - IISc is evaluated at a 50 MHz clock it does not meet;
  - the RTL-SAIF bias is NOT calibrated for IISc (next table).

**Calibration of RTL-SAIF against netlist-SAIF (SC):**

| Window | RTL-SAIF dynamic | netlist-SAIF dynamic | Difference |
|---|---|---|---|
| conv8_3 | 0.342 W | 0.235 W | **+45.53%** |
| cnn_demo layer 1 / 2 / 3 | 0.350 / 0.353 / 0.358 W | 0.346 / 0.368 / 0.337 W | +1.16% / −4.08% / +6.23% |
| cnn_demo per image, dynamic energy | 1,075.36508 µJ (whole-image SAIF) | 1,106.44124 µJ (sum of layers) | **−2.81%** |
| (vl=16 / vl=8, conv8_3, recorded) | 0.307 / 0.291 W | 0.252 / 0.240 W | +21.8% / +21.3% |

- **The RTL-SAIF bias depends on the workload, not only on the design:** +45.5% on conv8_3 against −2.8% on cnn_demo for the same SC checkpoint.
- **Why, from the reports:** RTL-SAIF matches only about 3% of nets and propagates the rest. With the same propagation, the RTL-SAIF figure barely moves between conv8_3 and cnn_demo (0.342 → 0.353 W). The netlist-SAIF figure rises from 0.235 to 0.35–0.37 W with the real Q8.24 data, so the propagated estimate is too high for conv8_3's low-activity data and about right for cnn_demo's.
- **Consequence for IISc:** its RTL-SAIF figures are not corrected by any factor. The SC/IISc cnn_demo ratio (0.299) compares two RTL-SAIF figures whose bias is known only on our side (−2.8% for this workload).

### 3. Paper rows on SC: CONV2D 5x5 and MATMUL 16 / 32 / 64 (as a 1x1 convolution)

New files: `scripts/atee_sc_paper.py` (prep, model, fit) and `scripts/run_atee_sc_paper.ps1 [-Distinct]`. The RTL (`atee_top_sc.v`, `hbm_lite_controller_sc.v`, `ibuf_ram.v`) and testbench (`atee_sc_tb.v`) are unchanged. Vivado 2019.1 xsim, BRAM-only, no DMA, ENABLE_DIV = 0, vl = 16, Q32.0 (as their programs), no bias, no ReLU, no pooling.

- **Inputs:** their program's ELF (`iisc_bench_prep.py`, unchanged). Reference: their Python reference (= their `expected_output[]`, exact at every size; see "Mapping").
- **CONV2D 5x5:** `conv32_5`, 32×32 input, 25 taps in chunks of 9 / 9 / 7, 32 filters (2 OC groups), 784 output pixels = 196 windows of 4.
- **MATMUL as a 1x1 convolution:** output pixel i = row i of A. The D input channels are A's row (IBUF index i·D + k = A row-major), weight[tap k][oc j] = B[k][j], and the output is C row-major. H = 1, W = D, IC = D, K = 1, OC = D; D taps, in chunks of 9.
- **Second data set (`-Distinct`):** their data cannot detect every placement error. All 32 conv32_5 filters are identical (as in conv8_3), and the matmul B matrices have only 10 distinct columns. Each row was therefore also run on seeded mixed-sign data (image/A/B in [−100, 100], kernel in [−50, 50]) with a nested-loop reference.

Which paper rows fit the SC limits (`atee_sc_paper.py fit`):

```
  CONV2D 3x3 8/16/32/64 (conv<S>_3)    fits | fits | fits | fits
  CONV2D 5x5 32x32 (conv32_5)          fits
  MATMUL 8 (matmul8) as 1x1 conv       NO: OC = 8 is not a multiple of 16
  MATMUL 16/32/64 as 1x1 conv          fits | fits | fits
```

- **4,096-word IBUF limit:** no paper row exceeds it. MATMUL 64 (64 × 64 = 4,096 words) and CONV2D 3x3 64x64 (4,096) fill it exactly; conv32_5 uses 1,024.
- **MATMUL 8:** not run; OC = 8 violates the multiple-of-16 rule.
- **AXPY and Perceptron:** not run (not requested; not convolutions as written in their programs).

Console (`run_atee_sc_paper.ps1`, check `atee_sc_check.py conv`):

```
matmul16: cycles 1210 (convoy states [1186]), cfg_error 0, hostwe 0 ; outputs exact vs reference 256 / 256 ; vs THEIR expected_output 256 / 256
matmul32: cycles 9006 (convoy states [8982]), cfg_error 0, hostwe 0 ; outputs exact vs reference 1024 / 1024 ; vs THEIR expected_output 1024 / 1024
matmul64: cycles 70128 (convoy states [70104]), cfg_error 0, hostwe 0 ; outputs exact vs reference 4096 / 4096 ; vs THEIR expected_output 4096 / 4096
conv32_5: cycles 162276 (convoy states [162252]), cfg_error 0, hostwe 0 ; outputs exact vs reference 25088 / 25088 ; vs THEIR expected_output 25088 / 25088
matmul16_distinct: cycles 1210 (convoy states [1186]), cfg_error 0, hostwe 0 ; outputs exact vs reference 256 / 256
matmul32_distinct: cycles 9006 (convoy states [8982]), cfg_error 0, hostwe 0 ; outputs exact vs reference 1024 / 1024
matmul64_distinct: cycles 70128 (convoy states [70104]), cfg_error 0, hostwe 0 ; outputs exact vs reference 4096 / 4096
conv32_5_distinct: cycles 162276 (convoy states [162252]), cfg_error 0, hostwe 0 ; outputs exact vs reference 25088 / 25088
```

| Row | SC measured (layer busy) | convoy states | model (`atee_sc_paper.py model`, slot rule) | IISc measured (entry → return, "Paper benchmark rows") | SC / IISc | Outputs |
|---|---|---|---|---|---|---|
| CONV2D 5x5, 32x32, 32 filters | 162,276 | 162,252 | 162,252 | 297,549 | **0.5454** | 25,088/25,088 exact (their data and distinct data) |
| MATMUL 16 | 1,210 | 1,186 | 1,186 | 4,737 | **0.2554** | 256/256 (both) |
| MATMUL 32 | 9,006 | 8,982 | 8,982 | 20,993 (their program computes a WRONG matrix, 16/1,024) | **0.4290** | 1,024/1,024 (both) |
| MATMUL 64 | 70,128 | 70,104 | 70,104 | 113,921 | **0.6156** | 4,096/4,096 (both) |

- **Model:** the slot-rule model predicts the convoy cycles exactly in every row; the fixed cost is 24 cycles, as in gate 1. cfg_error 0 in all eight runs.
- **Windows as before:** our layer-busy time against their function call. Both exclude loading memory.
- **MATMUL 32:** their figure belongs to a program that does not compute the product ("Output findings on their design"). The ratio compares cycles only.
- **MATMUL ratio grows with size** (0.26 → 0.43 → 0.62). Each output pixel has D taps and 4 pixels per window, so the work per window grows as D² while their loop amortises its setup better.
- **These supersede the PROJECTED ledger rows** for MATMUL and CONV2D 5x5 (vl=8 / vl=16, replicated input). Those projections are left as written.

### 4. Per-filter cycles and µs at 50 MHz, Table VIII placement

Per-filter equivalent = cycles / filters (16 for 3x3, 32 for 5x5), as "Their Table VIII, per-filter equivalents". MATMUL 64 is the whole product (Table VIII lists it so). Klessydra-T and RI5Cy are THEIRS-QUOTED from IISc Table VIII (originally from their ref. [3]), at their own clocks (120 / 91.4 MHz). IISc published values are from the same table.

| Kernel | SC cycles (per filter) | SC µs at 50 MHz | IISc published µs | IISc measured µs (conv: reset → return / filters; matmul: entry → return) | Klessydra-T µs | RI5Cy µs | SC / Klessydra-T | SC / RI5Cy | SC / IISc published |
|---|---|---|---|---|---|---|---|---|---|
| CONV2D 3x3 8x8 | 87.375 (1,398 / 16) | 1.74750 | 4.99 | 4.99625 | 9.91 | 46.46 | 0.176337 | 0.037613 | 0.350200 |
| CONV2D 3x3 16x16 | 452.375 (7,238 / 16) | 9.04750 | 19.81 | 19.81125 | 21.18 | 165.08 | 0.427172 | 0.054807 | 0.456714 |
| CONV2D 3x3 32x32 | 2,058.375 (32,934 / 16) | 41.16750 | 84.75 | 84.78125 | 59.54 | 623.85 | 0.691426 | 0.065989 | 0.485752 |
| CONV2D 5x5 32x32 | 5,071.125 (162,276 / 32) | 101.42250 | 185.8 | 185.96813 (conv2d call / 32; reset → return / 32 = 186.476) | 112.38 | 1,969.37 | 0.902496 | 0.051500 | 0.545869 |
| MATMUL 64x64 | 70,128 | 1,402.56000 | 2,275.71 | 2,278.42 | 2,741.35 | 1,971 | 0.511631 | 0.711598 | 0.616318 |

- **SC beats every quoted time in Table VIII** at every size, including Klessydra-T at 32x32 3x3 (vl=16 was 1.32× it, #20) and at 5x5.
- **These are 16- (or 32-) filter runs divided by the filter count,** as for the earlier rows. No single-filter program was run. The quoted cores run at other clocks, and their values are not measured here.
- **SC per-filter times exclude loading the IBUF and DMEM.** IISc's published values include their boot ("Their Table VII, per-filter reading").

## Release package and provenance of the inherited vector unit (2026-11-19)

No new measurement in this section. It records how the files compare with their repository, the result of the package's own check, and one smoke-test run.

**Their repository.** github.com/RClabiisc/I2SRV32-V-v1, licence Apache-2.0 (no NOTICE file). The commit of the zip used for every recorded result (`external/i2srv32.zip`, SHA-256 49bee54d…a01a99f4) is `a0b43781b03d8b9d5e4e217675e229a57da3bc62`, read from the zip comment.

**`rtl/vector_unit/`, compared byte for byte with their `Source code/rtl/vector_unit/`** (29 files):
- 13 are ours: the four controllers, the four top levels, `ibuf_ram.v`, `outsize_div.v`, `tensor_config_regs.v`, and the stand-ins `dmem_bram.vhd` and `div_gen_behav.vhd`.
- 9 are identical to theirs: alu, cpu_inf, dmem_addr_xbar, lsu, stall_gen, vec_decoder, vminmax, vrf_bank, xoutreg.
- 7 are modified: count_gen (the off-by-one fix), exe_unit, multicycle_ops, mypack, vector_top, v_wrapper, wrapper.
- `rtl/defines.v` is theirs plus 3 ATEE address lines; `timescale.v` and `verilogutils.vh` are identical.
- Diffs: `release/patches/01_inherited_vector_unit.patch`.

**Finding, not recorded before.** Besides the count_gen fix, ENABLE_DIV and the behavioural DMEM and divider replacements, `exe_unit.vhd` differs from theirs in its DONE and write-enable gating:
- Theirs: `DONE` = DONEs_internal and MEM_WB_DONEs. `DMEM_WE` uses (not DONEs_internal(i) or not MEM_WB_DONEs(i)). `VREG_WE` uses (not DONEs_internal or not WB_FIN_DONEs).
- Ours: `DONE` = the AND of all five stage DONE vectors (DONEs_internal, RD_EXE_, EXE_MEM_, MEM_WB_, WB_FIN_DONEs). `DMEM_WE` uses (not EXE_MEM_DONEs(i)). `VREG_WE` uses (not MEM_WB_DONEs).
- **Dating:** the change was already in the project's copy when this work began (2026-10-03). No copy older than 2026-10-11 survives, and its origin is NOT recorded. `vector_top.v` (not instantiated by any ATEE-Lite top) has `vcsr_quant` narrowed from 9 to 2 bits.
- **Consequence:** every ATEE-Lite measurement used this modified exe_unit. The hazards of section 6 were measured on it. The slot-7 store comes from `dmem_addr_xbar.vhd`, which is identical to theirs. Whether the load-use stall reproduces on their unmodified exe_unit has NOT been tested. The IISc-side measurements (their design, their files from `external/` and `external_2026/`) do not use our copy; the vl write-gate hazard (A.2) was measured on their design.

**Release package** (`release/`, 220 files, 2.18 MB; nothing pushed):
- Contents: our RTL, testbenches, scripts, docs, our IISc simulation glue, archived Step 5 / Step 6 / DMA-era controllers, and RESULTS.md.
- Patches 01–05: inherited vector unit; IISc and ATEE 128 KB experiments; DSP-macro stand-ins; their constraints without exceptions.
- `tools/setup_upstream.py` fetches their repository, applies the patches and checks SHA-256; `tools/make_patches.py` regenerates the patches.
- Also: README.md, NOTICE.md, a LICENSE placeholder, MANIFEST.txt.
- Their files are NOT included; they are referenced by URL and commit.

**Checks on the package, from a copy in the scratch folder:**
- `setup_upstream.py --zip external/i2srv32.zip --vivado2026` rebuilt 64 files:
  - the 19 inherited `rtl/` files;
  - 4 + 1 files of the IISc 2026.1 copies;
  - 2 x 10 conv8_3 init files;
  - 20 files of `atee_paper_cfg`.
  
  Console: `verify: 64 files, 0 mismatches -> PASS`. The rebuilt `rtl/vector_unit` matched the project's 29 files byte for byte.
- Smoke test from that copy, `run_atee_sc.ps1 -Mode conv -Size 8`, console: `conv8 : CNN_DONE cycles 1398 class 0 err 0 hostwe 0`. This is the recorded SC conv8_3 figure (Gate 1).

## Task H: provenance of the inherited vector unit (2026-11-19)

New runs only, all in `sim_build_h/`. No recorded result is changed. Their files come from `external/i2srv32.zip`, commit a0b43781b03d8b9d5e4e217675e229a57da3bc62, read from the zip comment.

New scripts:
- `scripts/h_trees.py`: builds source trees from their files plus selected hunks of ours.
- `scripts/h_compile.ps1`: uses THEIR DMEM and div_gen IP simulation models wherever a tree instantiates them.
- `h_run_sc.ps1`, `h_run_fault.ps1`, `h_compare.py`, `h_step4_summary.py`, `h_fault_summary.py`, `h_batch_step4.ps1`, `h_batch_needed.ps1`.
- `testbench/h_vwe_trace.tcl`, `testbench/h_dwe_trace.tcl`.

This section supersedes "origin not recorded" in "Release package and provenance of the inherited vector unit (2026-11-19)".

### H.1 Every hunk, classified

- **What a hunk is:** one non-equal block of `difflib` on their file -> ours (`python -I scripts/h_trees.py list`). Line numbers below are theirs -> ours.
- **Files that differ:** 7 of the 16 inherited vector-unit files (count_gen, exe_unit, multicycle_ops, mypack, vector_top, v_wrapper, wrapper). The other 9 are byte-identical.
- **Outside the vector unit:** `rtl/defines.v` has 3 added lines.
- **"Needed"** means required to reproduce the recorded SC results (H.4).

| Hunk | Lines (their -> our) | What it does | Class | Needed |
|---|---|---|---|---|
| count_gen:3, the `>` | 74 -> 72 | `count_internal >= terminal_count` -> `>`: the slot counter runs vl elements instead of vl-1 | off-by-one fix, but see H.5: their counter is consistent with their own write gates | YES |
| count_gen:0, 2 (sensitivity list), 3 (rest), 5, 6, 7 | 50; 63; 69-71; 102; 105; 108 | `started_r`: forces done = 0 in the first counting cycle | behaviour change (vl = 1 workaround); redundant with `>`, since count = 0 there | no |
| count_gen:1, 2 (rest), 4 | 56-57; 59-68; 80-94 | comments rewritten, commented-out processes deleted | comment-only | no |
| exe_unit:0, 3, 4; wrapper:0-2; v_wrapper:0-1 | 23, 319, 335; 22, 66, 92; 23, 63 | generic ENABLE_DIV; GEN_DIV_OFF ties DIV_BUSY / divbyzero / div_op to 0 | divider switch | YES (all Virtex-7 builds use ENABLE_DIV = 0) |
| exe_unit:1 | 232-235 -> 233-252 | DONE_int = AND of the DONEs of all five stages (theirs: DONEs_internal and WB_FIN_DONEs) | behaviour change (DONE_int also gates the host's DMEM access in cpu_inf) | YES, for cycle counts only (with :2) |
| exe_unit:2 | 238-241 -> 255 | DONE port = DONE_int (theirs: DONEs_internal and MEM_WB_DONEs) | behaviour change (DONE later) | YES, for cycle counts only |
| exe_unit:5-13, mypack:0-1 | 403-461; 227-305 | DMEM_0..7 IP -> behavioural `dmem_bram` (READ_FIRST; their IP: WRITE_FIRST, read latency 1, no output register) | IP substitution | no |
| multicycle_ops:0-3 | 42-115 | div_gen_0/1 IP -> behavioural `div_gen_behav` (LATENCY 36) | IP substitution | no (unused at ENABLE_DIV = 0) |
| exe_unit:14-16 | 659, 664, 668 | DMEM_WE(i) = dmw and not EXE_MEM_DONEs(i) (theirs: dmw and (not DONEs_internal(i) or not MEM_WB_DONEs(i))) | behaviour change (write window) | YES |
| exe_unit:17-19 | 731, 745, 748 | VREG_WE(bank) = REG_WE and not MEM_WB_DONEs(slot) (theirs: REG_WE and (not DONEs_internal(slot) or not WB_FIN_DONEs(slot))) | behaviour change (write window) | YES |
| vector_top:0 | 35 | vcsr_quant port 9 -> 2 bits | behaviour change, no effect (vector_top is not instantiated) | no |
| defines.v | 49 | ATEE_CONFIG_START/END_ADDR | other (constants, not read by any ATEE build) | no |

No hunk is debug-only.

### H.2 When each hunk first appears

**Sources searched:**
- all of the local drives (`<AUTHOR_LOCAL>`) and the user folders, for `exe_unit.vhd` copies and archives;
- the session transcript (one file, covering this project from 2026-10-03 19:43 local);
- the earlier project folders `<AUTHOR_LOCAL>\rp_it2` and `<AUTHOR_LOCAL>\RP` (same RTL), and `rp_it2/rtl.zip` (2026-07-23);
- the handover zip `<AUTHOR_LOCAL>\atee-lite-8lane.zip` (2026-10-03 19:37).

| Hunk | their zip | rp_it2 / RP (file date) | rtl.zip (07-23) | handover zip (10-03) | rtl/ now |
|---|---|---|---|---|---|
| started_r | no | yes, 2026-04-14 19:40 | yes | yes | yes |
| `>` | no | no | no | no | yes, edited 2026-10-03 (transcript) |
| ENABLE_DIV (3 files) | no | no | no | no | yes, edited 2026-10-11 (transcript) |
| DONE_int / DONE | no | yes, 2026-04-14 20:19 | yes | yes | yes |
| DMEM_WE / VREG_WE | no | yes, 2026-04-14 20:19 | yes | yes | yes |
| dmem_bram (exe_unit, mypack) | no | yes, 2026-04-14 17:18 / 20:19 | yes | yes | yes |
| div_gen_behav | no | yes, 2026-04-14 17:40 | yes | yes | yes |
| vcsr_quant 2 bits | no | yes, 2026-04-14 17:09 | yes | yes | yes |
| defines.v ATEE lines | no | yes, file dated 2026-04-02 01:32 | yes | yes | yes |

- **Recorded reason.** `rp_it2/RESULTS.md` (2026-04-15), section 9 "Files Modified", lists:
  - `exe_unit.vhd | DONE_int 40-term AND, VREG_WE/DMEM_WE gating`
  - `count_gen.vhd | started_r flag for vl=1 support`

  These were made for the original single-lane (vl = 1) DMA design. No other reason is recorded, and who made the edits is not recorded.
- **Import date.** The unmodified inherited files in rp_it2 are dated 2026-04-02 01:32. `defines.v` already has the ATEE lines at that date, so that edit's earliest date is unknown.
- **This project's edits.** The transcript shows only two edits to inherited files: `>` on 2026-10-03 and ENABLE_DIV on 2026-10-11. Every other hunk was already present at the first read, 2026-10-03 14:14 UTC.

### H.3 Which exe_unit.vhd every IISc result used

Source paths were taken from every compile and synthesis log under `sim_build`, `synth_build` and `synth_build_2026`. The files were then hashed and compared with the zip.

| IISc results | exe_unit.vhd compiled | vs their zip |
|---|---|---|
| conv8_3 baseline 3,181 (2019.1); DTLB stand-in probes; conv8..64_3 (assumed / zero); every paper benchmark row (saxpy8..64, perc8..64 incl. relocated, matmul8..64, mlp256_8/16, conv32_5, conv8_3); cnn_demo (cnn_img0 snapshot, reused for all 100 images by run_iisc_cnn_images.ps1 and for run_iisc_vlhazard.ps1); cnn probes (assumed / zero / UART); RTL-SAIF power (conv8_3 and cnn_demo); Artix-7 synthesis attempt and the OOC runs | `external/I2SRV32-V-v1-master/Source code/rtl/vector_unit/exe_unit.vhd` | identical (SHA-256 364b2298…23bb) |
| 2026.1 gate b2 and check 3; Virtex-7 Run 3; no-exceptions run (task E); power from the Run-3 checkpoint | `external_2026/iisc_copy/Source code/rtl/vector_unit/exe_unit.vhd` | identical |
| Paper-configuration experiment (128 KB) | `external_2026/iisc_paper_cfg/...` | differs only by the recorded 14 -> 12 edit (patch 02) |

All 16 vector-unit files in `external/` and `external_2026/iisc_copy/` are identical to the zip. **No IISc result used our exe_unit or any other file of ours. No IISc result is affected.**

### H.4 Minimal build, and which hunks are needed

All runs use the main design (SC), its testbench and data preparation unchanged, in Vivado 2019.1. Each run is compared with the recorded run: the full output dump and the cycle lines.

**Tree `min`** = their files + count_gen `>` + divider switch. Everything else is THEIR file, including their DMEM IP model (WRITE_FIRST) and their div_gen model. Console (`h_step4_summary.py min`; `atee_sc_check.py`):

```
  conv8     cycles    1398 (recorded    1398, +0)  output words differing    54 of   576  -> DIFFERENT
  conv16    cycles    7238 (recorded    7238, +0)  output words differing   294 of  3136  -> DIFFERENT
  conv32    cycles   32934 (recorded   32934, +0)  output words differing  1350 of 14400  -> DIFFERENT
  conv64    cycles  140390 (recorded  140390, +0)  output words differing  5766 of 61504  -> DIFFERENT
  conv32_5  cycles  162276 (recorded  162276, +0)  output words differing  2548 of 25088  -> DIFFERENT
  matmul16  cycles    1210 (recorded    1210, +0)  output words differing    21 of   256  -> DIFFERENT
  matmul32  cycles    9006 (recorded    9006, +0)  output words differing   144 of  1024  -> DIFFERENT
  matmul64  cycles   70128 (recorded   70128, +0)  output words differing   576 of  4096  -> DIFFERENT
  cnn_demo  100 images: identical to recorded (outputs AND cycles) 0 ; outputs identical 0 ; cycles identical 0
            cycle difference vs recorded (total): [-3] ; per layer: [(0, -1, -2)]
  layer 1 (13x13x16 = 2704): images bit-exact vs THEIR output 0 / 100 (values 261552 / 270400) ; vs reference 0 / 100
  layer 2 (5x5x32 = 800): images bit-exact vs THEIR output 0 / 100 (values 29375 / 80000) ; vs reference 0 / 100
  CORRECT vs label: ATEE-SC 98 / 100 ; reference 99 / 100 ; THEIR design 87 / 100
```

**`min` does not reproduce the recorded results.** Kernel-row cycles are identical, but cnn_demo runs 3 cycles short per image. Outputs are wrong on every workload.

**Isolation on conv8_3: each remaining group added alone to `min`.**

| Tree | Result on conv8_3 |
|---|---|
| `min_bram` (dmem_bram) | 54/576 wrong, as `min` |
| `min_done` (DONE) | 54/576 wrong |
| `min_dwe` (DMEM_WE) | 54/576 wrong |
| `min_sr` (started_r) | 54/576 wrong |
| `min_vwe` (VREG_WE, exe_unit:17-19) | **SAME** |
| `updiv` (their `>=`, divider switch only) | 45/576 wrong |
| `updiv_vwe` (their `>=` + our VREG_WE) | 36/576 wrong; element 15 lost, e.g. 0x0010203c = 0 |

**Tree `min_vwe`, every workload:**

```
  conv8 .. conv64, conv32_5, matmul16 : SAME (outputs and cycles)
  matmul32  cycles    9006 (recorded    9006, +0)  output words differing    24 of  1024  -> DIFFERENT
  matmul64  cycles   70128 (recorded   70128, +0)  output words differing    48 of  4096  -> DIFFERENT
  cnn_demo  100 images: outputs identical 100 ; cycles identical 0 ; cycle difference [-3], per layer (0, -1, -2)
```

**Isolation on MATMUL 32: each remaining group added to `min_vwe`.**

| Tree | Result on MATMUL 32 |
|---|---|
| `min_vwe_done` | 24/1024 wrong |
| `min_vwe_bram` | 24/1024 wrong |
| `min_vwe_sr` | 24/1024 wrong |
| `min_vwe_dwe` (DMEM_WE, exe_unit:14-16) | **SAME** |

On cnn_demo image 0, `min_vwe_done` gives SAME (outputs and 152,318 cycles). So DONE (exe_unit:1-2) accounts for the 3 cycles.

**Tree `needed`** = their files + count_gen `>` + divider switch + exe_unit DONE (1-2), DMEM_WE (14-16), VREG_WE (17-19). It keeps THEIR mypack, multicycle_ops, vector_top, DMEM IP model and div_gen, and has no started_r. Every recorded SC workload (`h_batch_needed.ps1`):

```
  conv8 .. conv64 (1398 / 7238 / 32934 / 140390), conv32_5 162276, matmul16/32/64 1210 / 9006 / 70128:
    output words differing 0, cycles +0 -> SAME (all eight)
  cnn_demo  100 images: identical to recorded (outputs AND cycles) 100 ; per layer (24926, 121502, 5890)
  layer 1: bit-exact vs THEIR output 100 / 100 ; layer 2: 100 / 100 ; FC 100 / 100 ; CORRECT vs label 99 / 100
```

**Why the write-gate hunks are needed.** Their gates enable writes when no valid element of the instruction is in the writing stage. Two cycle-by-cycle traces show this, each comparing their gate with ours.

VRF writes (`h_vwe_trace.tcl` on `min`, conv8_3):
```
VWE_SUMMARY layer-busy cycles 1398, VRF bank writes enabled 6273, extra (their gate only) 369
VWE_KIND WB_FIN busy (WB_FIN_DONEs=0) : 321
VWE_KIND slot counting (DONEs_internal=0) : 48
EXTRA cyc   103 bank 0 slot 0 vd  1 count(slot) 16 data 00000000 | ... -> WB_FIN busy (WB_FIN_DONEs=0)
EXTRA cyc   109 bank 6 slot 0 vd  1 count(slot) 22 data 00000000 | ... -> slot counting (DONEs_internal=0)
```

DMEM stores (`h_dwe_trace.tcl` on `min_vwe`, MATMUL 32):
```
DWE_SUMMARY layer-busy cycles 9006, slot store enables 4288, extra (their gate only) 192
DWE_KIND MEM_WB busy (MEM_WB_DONEs=0) : 192
EXTRA cyc   227 slot 0 count 16 addr 00108040 | DONEs_internal 11100000 EXE_MEM_DONEs 10000000 MEM_WB_DONEs 00000000 -> MEM_WB busy
```

- **VRF.** With `>` the vl = 16 slot's write-back stage reaches count 16 while WB_FIN still holds element 15. Their gate is open, so stale data goes to bank 0 of register vd + 2. That is element 0 of the next vector in our allocation (321 writes). The other 48 come from a slot re-started in place while MEM_WB still holds the old instruction past its end.
- **DMEM.** A vl = 16 store at count 16 writes base + 0x40, the first word of the next 16-word block. These are the partial-sum spills of MATMUL 32/64. The wrong outputs sit at a stride of 0x80, starting at 0x00118080: 24 words in MATMUL 32.
- **Their consistent pair.** With their `>=`, the same open cycle writes the LAST element (count 15). Their counter plus their gates write exactly vl elements for vl >= 2. Our counter plus our gates also write exactly vl. Mixing the two (`min`, `updiv_vwe`) loses or over-writes one element per vector.
- **CONV2D 5x5.** It also spills partial sums and was exact on `min_vwe`. Whether its extra stores land only on words that are rewritten before being read was not traced.

### H.5 Fault testbenches: their unmodified files vs ours

All five testbenches are unchanged; Vivado 2019.1. The trees:
- `upstream`: all 16 files theirs, with their DMEM and div_gen IP models;
- `min`, `min_vwe`, `needed`;
- `ours`: identical to rtl/. Its summary rows equal the recorded logs in every test.

Console: `python -I scripts/h_fault_summary.py upstream min min_vwe ours`, plus `needed`, abridged:

| Fault (testbench, test) | recorded = ours | upstream (theirs) | min | min_vwe | needed |
|---|---|---|---|---|---|
| Load-use stall, MAC after load in slot i-1 (convoy V1 / V1b) | mem 0/8, reg 7/8 / 7/8, 7/8 FAIL | same | same | same | same |
| Broadcast-load bank collision (convoy V3a-d) | 7/8, 7/8, 6/8, 6/8 FAIL | same | same (V3c/d reg 6/8) | same | same |
| Store in slot 7 spills (convoy_multi L3M3S) | mem 4/8 FAIL | same | same | same | same |
| Early clear 7 cycles after last slot (N_7) | OUT_A 7/8 FAIL | same | same | same | same |
| Slot reuse T1 / T3 / T4 | 0/8, 0/8, 7/8 WRONG | same | T1 1/8 | same | same |
| Slot reuse T5 (one idle cycle) | 8/8 | **v1 6/8 WRONG** | 6/8 WRONG | 8/8 | 8/8 |
| vl = 16 empty slot (convoy_vl16 PIX5) | 6/8, 6/8 FAIL | same | same | same | same |
| vl = 16 correct paths (CAL, SYN, WL, PIX1-4) | 328/328 PASS | 328/328 | 328/328 | 328/328 | 328/328 |
| vl = 8 load, serial (lane_load EXP D, convoy V0) | 8/8 PASS | **8/8 PASS** | V0 7/8 FAIL | 8/8 | 8/8 |
| vl = 1 loads (lane_load EXP A) | PASS | **FAIL (0x00000000)** | FAIL | FAIL (slot 0) | PASS |
| vl = 1, 8 slots (lane_load EXP C, the "dead end") | 2 of 8 land | **0 of 8** | 0 of 8 | 2 of 8 | 2 of 8 |
| vl = 16 wait-for-DONE, cycles per pixel (PIX1) | 93 | **87** | 90 | 90 | 93 |

- **Properties of THEIR core,** present on their unmodified files exactly as recorded:
  - the load-use stall (hazard 1);
  - the slot-7 store spill (hazard 2);
  - the broadcast collision;
  - the 8-cycle early-clear minimum;
  - the slot-reuse rules T1, T3, T4;
  - the vl > 8 empty-slot rule.
  
  The vl write-gate hazard (A.2) was measured on their design.
- **NOT a property of their core: the "count_gen off-by-one".** On their files a vl = 8 instruction writes all 8 elements (EXP D, V0). The "vl = 8 ran 7" observation of 2026-10-03 was made on the 2026-04-14 gating, and `>` restores the element that gating removed.
- **Differ on their core:**
  - vl = 1 writes nothing (EXP A/B/C), so the EXP C "2 of 8 slots land" dead-end figure is a property of the modified core;
  - slot reuse T5 fails;
  - DONE rises 6 cycles per pixel earlier (PIX1).

### H.6 Wording recommended for the paper

> ATEE-Lite reuses the vector execution unit of I2SRV32-V [1] (commit a0b4378). Nine of its sixteen source files are used unchanged. Four changes are needed for the ATEE-Lite controller:
>
> 1. The element counter runs vl elements (`count_gen.vhd`).
> 2. The vector-register write enable is gated by the write-back stage's own done flag.
> 3. The scratchpad write enable is gated by the memory stage's own done flag.
> 4. DONE is asserted only after every pipeline stage has drained.
>
> In the original core, the counter stops one element early and the two write enables stay open one cycle longer. Together they write exactly vl elements, so the original behaviour is self-consistent and is not a defect. Changes 1-3 replace that pair with an equivalent one that never writes an element outside the vector. This matters for the ATEE-Lite schedule, which keeps slots loaded and places vectors in adjacent registers and memory blocks. Change 4 affects cycle counts only (3 cycles per CNN image). The dividers are removed by a generic. For simulation and synthesis without the vendor IP, behavioural models of the scratchpad block RAM and the divider are used; with the vendor IP models, every result is identical. All I2SRV32-V results in this paper were obtained on the unmodified repository. The core hazards reported in Section X (load-use stall, slot-7 store, broadcast collision, empty slot at vl > 8) reproduce identically on the unmodified files.

**Avoid:**
- "unmodified vector unit";
- "off-by-one bug in I2SRV32-V" (H.5 shows their counter is consistent with their gates);
- the EXP C "2 of 8" figure as a property of their core.

**Authorship:** the 2026-04-14 changes (2-4, plus started_r and the behavioural models) were made in the earlier phase of this project (rp_it2); who made them is not recorded.

