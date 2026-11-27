# Coreless-V

**Status:** Research code accompanying a paper under submission.

Coreless-V (internal name ATEE-Lite) is a near-memory convolution accelerator for FPGAs. It reuses the
8-bank vector execution unit and the on-chip vector scratchpad of the
I2SRV32-V RISC-V vector processor [1]. The scalar RISC-V core that drives that
unit is replaced by a small hardware controller. The host writes the layer
descriptions (for the main design: one 13-word descriptor per layer in the
scratchpad, plus the descriptor base and layer count in configuration
registers) and sets a start bit once. The
controller then issues the vector instructions itself, as staggered
"convoys" in the unit's eight instruction slots. Everything is in block RAM:
no DMA, no external memory.

The main design is the **scalar-operand controller (SC)**:

| File | What it is |
|---|---|
| `rtl/vector_unit/hbm_lite_controller_sc.v` | Layer controller, vl = 16. Each input pixel is the scalar operand of the multiply-accumulate. Taps are processed in chunks of 9, with partial sums spilled to the scratchpad. |
| `rtl/vector_unit/ibuf_ram.v` | Input buffer (4,096 x 32 bit) that supplies the scalar operand |
| `rtl/vector_unit/atee_top_sc.v` | Top level: configuration registers, controller, buffer, vector unit |
| `rtl/vector_unit/tensor_config_regs.v` | Configuration registers |

The development designs are kept and reproducible:

| Design | Files |
|---|---|
| vl = 8 general schedule | `hbm_lite_controller.v`, `atee_top.v`, `outsize_div.v` |
| vl = 16, replicated input | `hbm_lite_controller_vl16.v`, `atee_top_vl16.v` |
| CNN, replicated input with chunked taps (G) | `hbm_lite_controller_cnn.v`, `atee_top_cnn.v` |
| Step 5 (output-stationary), archived | `archive/step5_output_stationary/` |
| Step 6 (weight-stationary), archived | `archive/step6_weight_stationary/` |
| Original DMA-era single-lane build, archived | `archive/cpu_and_dma/` (our three files only) |

All numbers are in `RESULTS.md`, each with its method and the console output it
came from. This README gives commands, not numbers.

## What is in this package, and what is not

| Folder | Contents |
|---|---|
| `rtl/vector_unit/` | Our RTL only: 13 files, the controllers, top levels, input buffer, configuration registers, output-size divider, and the behavioural stand-ins `dmem_bram.vhd` / `div_gen_behav.vhd` for Xilinx IP. |
| `testbench/` | All testbenches, the SAIF Tcl scripts, and the conv8_3 / MNIST-conv1 data (`test1_*`, `test2_*`). |
| `scripts/` | Build, run, check, power and implementation scripts; Python reference models and cycle models. |
| `external/iisc_sim/` | Our simulation glue for THEIR design: testbenches, the clock model, the DSP-macro stand-ins, and the IP regeneration script. |
| `docs/` | Design note for the chunked-tap and scalar-operand schedules, plus model outputs. |
| `patches/` | Our changes to I2SRV32-V files, as unified diffs (see `patches/README.md`). |
| `tools/` | `setup_upstream.py` (fetch, patch, verify), `make_patches.py` (how the patches were made), and the tool-path configuration `paths.example.ps1` / `load_paths.ps1` (see "Setup"). |
| `third_party/I2SRV32-V/` | Their licence (Apache-2.0). |

**Not included: the I2SRV32-V repository.** That covers their RTL, their IP
containers and their benchmark programs. It is referenced by URL and commit, and
`tools/setup_upstream.py` rebuilds it locally. This includes the 16 files of
their vector unit that our design instantiates; 7 of those carry our changes,
applied by `patches/01_inherited_vector_unit.patch`. See `NOTICE.md`.

Also not included: the third-party files that were in the original project's
archive (OpenCores UART16550, OR1200 and Wishbone files, and an older scalar
CPU). None of them is part of any measured design.

## Tools (versions of record)

| Tool | Version | Used for |
|---|---|---|
| Windows 10, Windows PowerShell | 5.1 | all `*.ps1` drivers |
| Vivado / xsim | **2019.1** (WebPACK), at `<VIVADO_2019_ROOT>` | every functional simulation; Artix-7 stand-in synthesis; netlist-SAIF simulation |
| Vivado | **2026.1** (BASIC licence), at `<VIVADO_2026_ROOT>` | Virtex-7 XC7VX485T (`xc7vx485tffg1761-2`) implementation; RTL-SAIF simulation; all `report_power` runs |
| Python | 3.12.10, standard library only, at `<PYTHON>` | data preparation, reference models, checks |

Run Python as `python -I`.

## Setup

### Tool paths

The install locations are set in ONE file, not in the scripts. Copy the
example and edit it:

```
copy tools\paths.example.ps1 tools\paths.ps1
```

| Placeholder | Variable in `tools\paths.ps1` | Meaning | Example (author's machine; installer default) |
|---|---|---|---|
| `<VIVADO_2019_ROOT>` | `$VIVADO2019_ROOT` | Vivado 2019.1 install folder (has `bin\xvlog.bat`) | `C:\Xilinx\Vivado\2019.1` |
| `<VIVADO_2026_ROOT>` | `$VIVADO2026_ROOT` | Vivado 2026.1 install folder (has `bin\vivado.bat`) | `C:\AMDDesignTools\2026.1\Vivado` |
| `<PYTHON>` | `$PYTHON` | Python 3.12 interpreter | `python` (first on PATH) |
| `<PROJECT_ROOT>` | none | the folder holding this README; every script finds it from its own location | — |

- `tools\paths.ps1` is git-ignored. Without it, the scripts use the values of
  `tools\paths.example.ps1`.
- Every `scripts\*.ps1` driver loads the file through `tools\load_paths.ps1`.
- `external/iisc_sim/ip_config.tcl` writes its memory-init paths as
  `<PROJECT_ROOT>/…` and resolves them when it is sourced.
- `RESULTS.md` (this public copy) also uses `<XILINX_ROOT>` (the Vivado 2019.1
  install parent) and `<AUTHOR_LOCAL>` (files on the author's machine that are
  not in this package) in place of local paths.

### Upstream files

```
python -I tools\setup_upstream.py --download                # or: --zip <I2SRV32-V zip>
python -I tools\setup_upstream.py --zip <zip> --vivado2026  # also the Vivado 2026.1 working copies
```

The setup script does five things:

1. It unpacks the I2SRV32-V repository at commit
   `a0b43781b03d8b9d5e4e217675e229a57da3bc62` into `external/I2SRV32-V-v1-master/`.
2. It copies their vector-unit files into `rtl/vector_unit/`, and `defines.v`,
   `timescale.v` and `verilogutils.vh` into `rtl/`.
3. It applies patch 01 to those files.
4. With `--vivado2026`, it also builds `external_2026/iisc_copy/`,
   `iisc_paper_cfg/` and `atee_paper_cfg/`, and applies patches 02, 03 and 05.
5. It checks the SHA-256 of all 64 rebuilt files against
   `tools/expected_sha256.txt`. These are the bytes every recorded result was
   measured with. The check prints `PASS` or names each mismatch.

Before any IISc Virtex-7 run, upgrade their IP in the 2026.1 copy. Then copy
the upgraded containers into the paper-configuration copy:

```
<VIVADO_2026_ROOT>\bin\vivado.bat -mode batch -source scripts/v2026_gate_b2.tcl
copy "external_2026\iisc_copy\Source code\IP\*.xcix" "external_2026\iisc_paper_cfg\Source code\IP\"
```

`upgrade_ip` rewrites the `.xcix` files in place, so re-run the setup step before
repeating it.

## Reproducing the results

All commands run from the package root. `ps` stands for
`powershell -ExecutionPolicy Bypass -File`. Each run prints a PASS/FAIL or
exact/mismatch line; compare it with the RESULTS.md section named in the table.

**Long runs.** Start implementation runs and long SAIF simulations detached,
so they survive the console:

- Vivado runs: `ps scripts\launch_vivado2026_detached.ps1 -Tcl <tcl> -Tag <tag> [-TclArgs ...]`
- PowerShell scripts without arguments: `ps scripts\launch_ps_detached.ps1 -Script <ps1> -Out <log> -Name <task>`

Run one implementation at a time.

### Main design (SC): cycles and correctness

| Result | RESULTS.md section | Command |
|---|---|---|
| Isolated scalar-operand convoy tests | "Scalar-operand variant (SC)", Step 1 | `ps scripts\run_convoy_scalar.ps1` |
| CONV2D 3x3 at 8 / 16 / 32 / 64 (their data; distinct data) | SC, Gate 1 | `ps scripts\run_atee_sc.ps1 -Mode conv -Size 8` (16, 32, 64; add `-Distinct`) |
| cnn_demo, 100 MNIST images, all three layers from one start | SC, Gate 2 | `ps scripts\run_atee_sc.ps1 -Mode cnn -Layers 3 -From 0 -To 99` |
| CONV2D 5x5 and MATMUL 16 / 32 / 64 (as 1x1 convolution) | "Main design …", item 3 | `ps scripts\run_atee_sc_paper.ps1 -Programs conv32_5,matmul16,matmul32,matmul64` (again with `-Distinct`) |
| Cycle model (slot rule) | SC "The build"; item 3 | `python -I scripts\sc_schedule_model.py`; `python -I scripts\atee_sc_paper.py model` |
| Per-filter µs, Table VIII placement | "Main design …", item 4 | arithmetic on the rows above (shown in RESULTS.md) |

### Main design (SC): area, timing, power on Virtex-7 (Vivado 2026.1)

| Result | RESULTS.md section | Command |
|---|---|---|
| Full-chip implementation (LUT/FF/BRAM/DSP, WNS) | "SC: Virtex-7 full-chip build" | `vivado -mode batch -source scripts/v7_impl_atee_sc.tcl`, then `python -I scripts\v7_summarize.py synth_build_2026\v7_xc7vx485t\atee_sc` |
| Control logic and LUT decomposition vs IISc | "Main design …", item 1 | the SC run above and IISc Run 3 below; the subtraction is shown in RESULTS.md |
| Power, netlist-SAIF, conv8_3 | item 2 | `ps scripts\v7_power_atee_sc.ps1 -Workload conv8` |
| Power, netlist-SAIF, cnn_demo image 0, per layer | item 2 | see note 1 below |

Power is measured for Coreless-V only. A power comparison with I2SRV32-V is
future work, as in the paper.

**Note 1, cnn_demo SAIF windows (152k and 242k cycles).** These use
condition-triggered windows. First build the snapshot with
`ps scripts\v7_power_atee_sc.ps1 -Workload cnn` (for the RTL-SAIF runs under
"Additional measurements" below: `ps scripts\v7_rtlsaif_atee_sc.ps1 -Workload cnn`
or `ps scripts\v7_rtlsaif_iisc_cnn.ps1`). Stop it once its xsim run has started;
its stepped window takes hours. Then run
`ps scripts\v7_power_cnn_cond.ps1 -Design sc_netlist_seg` (RTL-SAIF runs:
`-Design sc_rtl` or `-Design iisc_rtl`). On conv8_3 the two window methods were
checked to give identical power (RESULTS.md, item 2).

### I2SRV32-V, their design and programs (comparison baseline)

| Result | RESULTS.md section | Command |
|---|---|---|
| conv8_3 baseline, conv2d() cycles, err_count | "1c. Comparison with I2SRV32-V" | `ps scripts\run_iisc_baseline.ps1` |
| CONV2D 3x3 at 8 / 16 / 32 / 64 | "CONV2D 3x3 at image sizes 8 / 16 / 32 / 64" | `ps scripts\run_iisc_conv_sizes.ps1 -Size 8` (16, 32, 64) |
| Their benchmark programs (CONV2D 5x5, MATMUL, cnn_demo, SAXPY, perceptron) | "Paper benchmark rows, measured on their design" | `ps scripts\run_iisc_bench.ps1 -Program <name>`; batches: `ps scripts\run_iisc_bench_batch.ps1 -List "..."`; summary `python -I scripts\iisc_bench_summary.py` |
| cnn_demo on 100 images | same, "cnn_demo (Table IX CNN)" | `ps scripts\run_iisc_bench.ps1 -Program cnn -Image 0`, then `ps scripts\run_iisc_cnn_images.ps1 -From 1 -To 99` |
| DSP-macro stand-in sensitivity (TLB) | "Data-TLB stand-in probe"; "A.1" | `ps scripts\run_iisc_baseline_dtlb.ps1 -StandIn zero` (and `assumed`); `ps scripts\run_iisc_cnn_probe.ps1 -StandIn zero` (and `assumed`) |
| Virtex-7 Run 3, area (their constraints as written) | "Virtex-7 XC7VX485T, Vivado 2026.1" | `vivado -mode batch -source scripts/v7_impl_iisc.tcl`; analysis `scripts/v7_iisc_analyze.tcl` |
| Vivado 2026.1 gives the same conv8_3 cycles as 2019.1 | "Gate test re-run (2026-11-12/13)" | `ps scripts\run_iisc_conv8_3_2026.ps1 -MainImage xmem` |

### Development designs

| Result | RESULTS.md section | Command |
|---|---|---|
| vl = 8 conv8_3, ablation chain, ReLU, MNIST conv1 | "1a", "1b" | `ps scripts\run_conv8_3.ps1 [-EarlyClear 0\|1] [-Activation 1] [-Workload mnist] [-NoDiv]` |
| Step 5 / Step 6 / DMA-era baseline | "1a" | `ps scripts\run_conv8_3_step5.ps1`, `..._step6.ps1`, `ps scripts\run_conv8_3_regression.ps1` (the only DMA build) |
| vl = 8 at conv sizes 8–64 | "CONV2D 3x3 at image sizes …" | `ps scripts\run_conv_sizes.ps1 -Size 8` |
| vl = 16 controller | "vl=16 controller (2026-11-11)" | `ps scripts\run_conv_vl16.ps1 -Size 8` (also `-Workload mnist`, `-LimitTest`) |
| CNN design G, 100 images | "G: cnn_demo on ATEE-Lite …" | `ps scripts\run_atee_cnn.ps1 -Layers 3 -From 0 -To 99` |
| Virtex-7 vl = 16 / vl = 8 / G | "Virtex-7 XC7VX485T …", "G: Virtex-7 …" | `scripts/v7_impl_atee.tcl -tclargs vl16` (or `vl8`), `scripts/v7_impl_atee_cnn.tcl` |
| Virtex-7 power vl = 16 / vl = 8 | "Virtex-7 power (2026-11-14)", "RTL-SAIF method" | `ps scripts\v7_power_atee.ps1 -Design atee_vl16 -Mode new`; `ps scripts\v7_rtlsaif_atee.ps1 -Design vl16` |
| Artix-7 stand-in synthesis and power (2019.1) | sections 2–5, "Out-of-context synthesis" | `scripts/synth_atee.tcl`, `synth_atee_nodiv.tcl`, `synth_atee_ooc.tcl`, `ps scripts\run_power_saif.ps1` |
| Chunked-tap and CNN schedule models | "C", "F" | `python -I scripts\chunked_taps_model.py`, `chunked_taps_alt_model.py`, `cnn_schedule_model.py` |

## Issue-rule tests (vector unit alone)

The controllers follow a small set of issue rules for the vector unit
(RESULTS.md sections 6 and A.2). Each test below drives the vector unit
(`v_wrapper`) alone and runs a convoy shape that a rule excludes next to one
that follows it.

| Issue rule | Testbench | Command |
|---|---|---|
| No load in the slot directly ahead of its reader | `testbench/convoy_tb.v` (V1/V1b) | `ps scripts\run_convoy.ps1` |
| No broadcast (stride-0) loads | `testbench/convoy_tb.v` (V3a–d) | same |
| No store in slot 7 | `testbench/convoy_multi_tb.v` (L3M3S) | `ps scripts\run_convoy_multi.ps1` |
| Slot j issued exactly j cycles after slot 0 (the slots are not 8 lanes) | `testbench/lane_load_tb.v` (EXP B, C) | `ps scripts\run_lane_load.ps1` |
| Slot reuse without a clear (T1–T6) | `testbench/convoy_reuse_tb.v` | `ps scripts\run_convoy_reuse.ps1` |
| No empty slot at vl > 8 | `testbench/convoy_vl16_tb.v` | `ps scripts\run_convoy_vl16.ps1` |
| Chunk boundary, with negative control | `testbench/convoy_chunk_tb.v` | `ps scripts\run_convoy_chunk.ps1` |
| vl a multiple of 8, on THEIR design | `scripts/iisc_vlhazard.py` | `ps scripts\run_iisc_vlhazard.ps1` |

The same testbenches, and the main design, can be run on THEIR unmodified
vector-unit files or on any subset of our changes (RESULTS.md "Task H"):
`python -I scripts\h_trees.py build <tree> <hunks>`, then
`ps scripts\h_run_fault.ps1 -Tree <tree> -Tb convoy` or
`ps scripts\h_run_sc.ps1 -Tree <tree> -Job conv -Items 8`. These scripts read
their files from the repository zip (`external/i2srv32.zip`, the
`--zip` given to `tools/setup_upstream.py`) and their IP simulation models from
`external/ip_extracted/` (produced as for `scripts/run_iisc_baseline.ps1`).

## Additional measurements

Additional measurements of the I2SRV32-V baseline are recorded in RESULTS.md.
They are not used in the paper. The commands for them:

| Measurement | RESULTS.md section | Command |
|---|---|---|
| Power by RTL-SAIF, SC conv8_3 / cnn_demo and IISc cnn_demo inference | "Main design …", item 2 | `ps scripts\v7_rtlsaif_atee_sc.ps1 -Workload conv8`; cnn_demo: note 1 (`-Design sc_rtl`, `-Design iisc_rtl`) |
| Paper-configuration experiment (128 KB) | "Paper-configuration experiment" | `scripts/v7_impl_iisc_papercfg.tcl`, `scripts/v7_impl_atee_papercfg.tcl` |
| No-exceptions reference run | "E: LUT decomposition on Virtex-7" | `scripts/v7_impl_iisc_noexc.tcl` |

## Attribution

Coreless-V is built on, and compared against, the I2SRV32-V vector processor of
the Reconfigurable Computation Lab, Department of Electronic Systems
Engineering, Indian Institute of Science, Bengaluru:
https://github.com/RClabiisc/I2SRV32-V-v1 (Apache License 2.0), commit
`a0b43781b03d8b9d5e4e217675e229a57da3bc62`. Its vector execution unit is used
with the changes listed in `patches/README.md`. See `NOTICE.md`.

[1] V. Naveen Chander and K. Varghese, "A Soft RISC-V Vector Processor for
Edge-AI," in *Proc. 35th International Conference on VLSI Design and 21st
International Conference on Embedded Systems (VLSID)*, 2022, pp. 263–268,
doi: 10.1109/VLSID2022.2022.00058.

## Citation

If you use this code, please cite the accompanying paper (under review):

> M. A. Qaisar and A. Hazarika, "Coreless-V: Replacing the Scalar Core with a
> Configuration-Driven Controller for a Soft RISC-V Vector Unit," under review.

```bibtex
@unpublished{qaisar_corelessv,
  author = {Malik Afnan Qaisar and Anakhi Hazarika},
  title  = {{Coreless-V}: Replacing the Scalar Core with a Configuration-Driven
            Controller for a Soft {RISC-V} Vector Unit},
  note   = {Under review},
  year   = {2026}
}
```

## Licence

Copyright 2026 Malik Afnan Qaisar and Anakhi Hazarika. Licensed under the
Apache License 2.0: see `LICENSE` and `NOTICE.md`. The I2SRV32-V material is
also under Apache-2.0; their licence is in
`third_party/I2SRV32-V/LICENSE-Apache-2.0.txt`.
