# NOTICE

Coreless-V
Copyright 2026 Malik Afnan Qaisar and Anakhi Hazarika. Licensed under the Apache License 2.0; see `LICENSE`.

## I2SRV32-V (Apache License 2.0)

This work builds on the I2SRV32-V RISC-V vector processor, Reconfigurable
Computation Lab, Department of Electronic Systems Engineering, Indian Institute
of Science (IISc), Bengaluru:

- Repository: https://github.com/RClabiisc/I2SRV32-V-v1
- Commit: a0b43781b03d8b9d5e4e217675e229a57da3bc62
- Licence: Apache License 2.0, copy in `third_party/I2SRV32-V/LICENSE-Apache-2.0.txt`.
  The repository has no NOTICE file.
- Paper: V. Naveen Chander and K. Varghese, "A Soft RISC-V Vector Processor for
  Edge-AI," VLSID 2022, pp. 263–268, doi: 10.1109/VLSID2022.2022.00058.

**Not redistributed here:** their RTL, IP containers, constraints, benchmark
programs, data and documents. `tools/setup_upstream.py` fetches them from the
commit above.

**Material in this package that contains or derives from I2SRV32-V content:**

| Item | Content | Change notice |
|---|---|---|
| `patches/01`–`05` | unified diffs of their files; the context lines are excerpts of their files | header of each patch, and `patches/README.md` |
| `scripts/iisc_timing_exceptions.xdc` | the 34 timing-exception lines of their `constraints.xdc`, verbatim | file header |
| `scripts/iisc_timing_exceptions_ooc.xdc` | the same, re-rooted to the `cpu` top; 11 lines commented out | file header |
| `external/iisc_sim/vector_top_blackbox.v` | port list of their `vector_top.v` | file header |
| `external/iisc_sim/ip_config.tcl` | parameter values read from their `.xci` files | file header; the 9 `Coe_File` entries use `<PROJECT_ROOT>`, resolved when the file is sourced |
| `scripts/generate_test_data.py`, `testbench/test1_*.hex`, `testbench/test2_*.hex` | the script embeds their conv8_3 benchmark values and their cnn_demo MNIST image and trained conv1 weights; the hex files are its output, laid out for our controller | script header |

After `tools/setup_upstream.py` has run, the working tree holds MODIFIED
versions of 8 of their files: `count_gen.vhd`, `exe_unit.vhd`,
`multicycle_ops.vhd`, `mypack.vhd`, `vector_top.v`, `v_wrapper.v`, `wrapper.vhd`
and `defines.v`. With `--vivado2026` it also holds 4 modified VHDL files in
`external_2026/iisc_paper_cfg/` and `external_2026/iisc_copy/constraints_noexc.xdc`.
Their changes are described in `patches/README.md`. Anyone who redistributes
those files must meet Apache-2.0 section 4. That includes a prominent notice
in each modified file.

## MNIST

The cnn_demo images are the 100 MNIST test images shipped in the I2SRV32-V
repository (`Demo/Application/img.c`). The MNIST database is by Y. LeCun,
C. Cortes and C. J. C. Burges.
