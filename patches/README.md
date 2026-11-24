# Patches against I2SRV32-V

Used by Coreless-V (internal name ATEE-Lite).

Base: https://github.com/RClabiisc/I2SRV32-V-v1, commit
`a0b43781b03d8b9d5e4e217675e229a57da3bc62` (Apache-2.0).

`tools/setup_upstream.py` applies these patches. You can also apply them with
`git apply` or `patch -p1` from the folder named in each row below. Lines keep
their original line endings. After applying, check the result against
`tools/expected_sha256.txt`.

| Patch | Applies in | What changes | Used by |
|---|---|---|---|
| `01_inherited_vector_unit.patch` | package root, after copying their `Source code/rtl/vector_unit/*` to `rtl/vector_unit/` and `defines.v` to `rtl/` | see below | every Coreless-V build |
| `02_iisc_paper_cfg_128KB.patch` | `external_2026/iisc_paper_cfg/` (a copy of their repository) | VMEM/DMEM address width 14 -> 12 on 6 lines in 4 VHDL files (128 KB scratchpad). DMEM IP depth 16384 -> 4096 is set by `scripts/v7_impl_iisc_papercfg.tcl` | paper-configuration experiment, their design |
| `03_atee_paper_cfg_128KB.patch` | `external_2026/atee_paper_cfg/` (copy of `rtl/vector_unit` after 01) | 14 -> 12 on 8 lines in 5 files | paper-configuration experiment, Coreless-V vl=16 |
| `04_dsp48_macro_standins.patch` | package root | NEW files `external/iisc_sim/xbip_dsp48_macro_missing.v` / `_zero.v` (also shipped as files) | every simulation and implementation of their design |
| `05_iisc_constraints_noexc.patch` | `external_2026/iisc_copy/`, applied to a copy of their `constraints.xdc` named `constraints_noexc.xdc` | the 34 timing exceptions and 3 Tcl variable lines commented out; pins unchanged | no-exceptions reference run only |

## Patch 01 in detail

| File | Change | Effect on results |
|---|---|---|
| `count_gen.vhd` | `done_gen` compares with `>` instead of `>=`, so the counter runs N elements for vl = N. A `started_r` gate (2026-04-14, vl = 1 workaround) keeps the first active cycle running; it is redundant with `>`. | Required, together with the exe_unit write-enable changes. Their `>=` plus their own write enables also write all vl elements for vl >= 2, so this is not a fix of a defect in their core (RESULTS.md "Task H", H.5). |
| `exe_unit.vhd` | (a) generic `ENABLE_DIV`, default 1; with 0 the 16 dividers are not generated and `DIV_BUSY` / `div_op` are tied to 0; (b) DMEM_0..7 Xilinx IP replaced by the behavioural `dmem_bram`; (c) `DONE`, `DMEM_WE` and `VREG_WE` gated by the per-stage DONE registers (`EXE_MEM_DONEs`, `MEM_WB_DONEs`) instead of `DONEs_internal` / `WB_FIN_DONEs`. | (a) all Virtex-7 builds use 0; (b) simulation and synthesis without their IP (with their IP models every result is identical, RESULTS.md "Task H"); (c) made 2026-04-14 in the project's earlier phase. The DMEM_WE and VREG_WE parts are REQUIRED: their write enables stay open one cycle past the vector, which together with the `>` count would write element vl. The DONE part changes cycle counts only (RESULTS.md "Task H", H.4). |
| `multicycle_ops.vhd` | `div_gen_0/1` IP replaced by the behavioural `div_gen_behav` (LATENCY 36) | only builds with `ENABLE_DIV = 1` |
| `mypack.vhd` | the 8 DMEM component declarations replaced by one `dmem_bram` component | follows (b) |
| `vector_top.v` | `vcsr_quant` port 9 -> 2 bits | none: `vector_top` is not instantiated by any Coreless-V top |
| `v_wrapper.v`, `wrapper.vhd` | pass `ENABLE_DIV` down | follows (a) |
| `defines.v` | three Coreless-V configuration-register address lines | not read by any Coreless-V build script |

The IISc runs (their design, `scripts/run_iisc_*`, `scripts/v7_*iisc*`) compile
their files from `external/` and `external_2026/` UNCHANGED, except for patches
02 and 05 in the two marked experiments.
