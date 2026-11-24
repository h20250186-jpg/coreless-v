#!/usr/bin/env python3
"""Creates the patch files in release/patches/ from the Coreless-V working tree.

Run from the working tree root (the folder that holds rtl/, external/ and
external_2026/), with the I2SRV32-V repository unpacked at
external/I2SRV32-V-v1-master (commit a0b43781b03d8b9d5e4e217675e229a57da3bc62):

    python -I release/tools/make_patches.py

Each patch is a unified diff (paths a/... b/..., usable with `git apply` or
`patch -p1`, and with release/tools/setup_upstream.py, which needs neither).
Lines keep their original line endings. Also writes release/tools/expected_sha256.txt,
the SHA-256 of every file the setup script reconstructs.
"""
import difflib, hashlib, os, sys

ROOT = os.getcwd()
UP = os.path.join(ROOT, 'external', 'I2SRV32-V-v1-master')
OUT = os.path.join(ROOT, 'release', 'patches')
SHA = os.path.join(ROOT, 'release', 'tools', 'expected_sha256.txt')

def rd(p):
    with open(p, 'rb') as f:
        return f.read()

def lines(b):
    return b.decode('latin-1').splitlines(True)

def diff(a_bytes, b_bytes, path_a, path_b):
    a = lines(a_bytes) if a_bytes is not None else []
    b = lines(b_bytes)
    fa = '/dev/null' if a_bytes is None else 'a/' + path_a
    out = []
    for l in difflib.unified_diff(a, b, fa, 'b/' + path_b, n=3):
        if not l.endswith('\n'):
            l += '\n\\ No newline at end of file\n'
        out.append(l)
    return ''.join(out)

def write(name, header, parts):
    with open(os.path.join(OUT, name), 'w', encoding='latin-1', newline='') as f:
        for h in header:
            f.write('# ' + h + '\n' if h else '#\n')
        f.write('\n')
        for p in parts:
            f.write(p)
    print('wrote', name, sum(len(p) for p in parts), 'bytes')

os.makedirs(OUT, exist_ok=True)
sha = []
def rec(rel_in_release, b):
    sha.append((hashlib.sha256(b).hexdigest(), rel_in_release))

UPVU = os.path.join(UP, 'Source code', 'rtl', 'vector_unit')
# 1. inherited vector-unit files as used by every Coreless-V build
modified = ['count_gen.vhd', 'exe_unit.vhd', 'multicycle_ops.vhd', 'mypack.vhd',
            'vector_top.v', 'v_wrapper.v', 'wrapper.vhd']
identical = ['alu.vhd', 'cpu_inf.vhd', 'dmem_addr_xbar.vhd', 'lsu.vhd', 'stall_gen.vhd',
             'vec_decoder.v', 'vminmax.vhd', 'vrf_bank.vhd', 'xoutreg.vhd']
parts = []
for n in modified:
    a = rd(os.path.join(UPVU, n)); b = rd(os.path.join(ROOT, 'rtl', 'vector_unit', n))
    parts.append(diff(a, b, 'rtl/vector_unit/' + n, 'rtl/vector_unit/' + n))
    rec('rtl/vector_unit/' + n, b)
for n in identical:
    b = rd(os.path.join(ROOT, 'rtl', 'vector_unit', n))
    assert b == rd(os.path.join(UPVU, n)), n
    rec('rtl/vector_unit/' + n, b)
a = rd(os.path.join(UP, 'Source code', 'rtl', 'defines.v')); b = rd(os.path.join(ROOT, 'rtl', 'defines.v'))
parts.append(diff(a, b, 'rtl/defines.v', 'rtl/defines.v')); rec('rtl/defines.v', b)
for n in ['timescale.v', 'verilogutils.vh']:
    b = rd(os.path.join(ROOT, 'rtl', n)); assert b == rd(os.path.join(UP, 'Source code', 'rtl', n)), n
    rec('rtl/' + n, b)
write('01_inherited_vector_unit.patch', [
    'ATEE-Lite changes to files of the I2SRV32-V vector unit (Apache-2.0, see',
    'third_party/I2SRV32-V/). Base: github.com/RClabiisc/I2SRV32-V-v1, commit',
    'a0b43781b03d8b9d5e4e217675e229a57da3bc62, folder "Source code/rtl/" copied to rtl/.',
    'Applied by tools/setup_upstream.py. Every ATEE-Lite result was measured with these files.',
    '',
    'count_gen.vhd       done_gen ">=" -> ">" so vl=N runs N elements (the off-by-one fix,',
    '                    2026-10-03), plus a started_r gate for the first active cycle.',
    'exe_unit.vhd        generic ENABLE_DIV (2026-10-11; 0 removes the 16 dividers);',
    '                    DMEM_0..7 IP -> behavioural dmem_bram; DONE / DMEM_WE / VREG_WE',
    '                    gated by the per-stage DONE registers (EXE_MEM_/MEM_WB_DONEs).',
    '                    The gating dates from 2026-04-14 (earlier project phase). The',
    '                    DMEM_WE / VREG_WE parts are REQUIRED with the ">" count; DONE',
    '                    changes cycle counts only (RESULTS.md "Task H").',
    'multicycle_ops.vhd  div_gen_0/1 IP -> behavioural div_gen_behav (LATENCY 36).',
    'mypack.vhd          DMEM_0..7 component declarations -> one dmem_bram component.',
    'vector_top.v        vcsr_quant port 9 -> 2 bits (vector_top is not instantiated by',
    '                    any ATEE-Lite top).',
    'v_wrapper.v,',
    'wrapper.vhd         pass the ENABLE_DIV generic down to exe_unit.',
    'defines.v           three ATEE configuration-register address lines.',
    'Unchanged and fetched as is: alu, cpu_inf, dmem_addr_xbar, lsu, stall_gen, vec_decoder,',
    'vminmax, vrf_bank, xoutreg, timescale.v, verilogutils.vh.',
], parts)

# 2. IISc paper-configuration experiment (128 KB scratchpad), their design
PC = os.path.join(ROOT, 'external_2026', 'iisc_paper_cfg')
parts = []
for n in ['cpu_inf.vhd', 'exe_unit.vhd', 'mypack.vhd', 'wrapper.vhd']:
    rel = 'Source code/rtl/vector_unit/' + n
    a = rd(os.path.join(UP, rel)); b = rd(os.path.join(PC, rel))
    parts.append(diff(a, b, rel, rel)); rec('external_2026/iisc_paper_cfg/' + rel, b)
write('02_iisc_paper_cfg_128KB.patch', [
    'EXPERIMENT (2026-11-14), "paper configuration" of THEIR design: vector scratchpad',
    '16 KB per bank, 128 KB total (repo build: 64 KB per bank, 512 KB).',
    'Applies to a copy of their repository at external_2026/iisc_paper_cfg/ (paths below',
    'are relative to that folder). VMEM_ADDR_WIDTH / DMEM_ADDR_WIDTH 14 -> 12 on 6 lines;',
    "cpu_inf's DMEM_END decode constant is deliberately left unchanged.",
    'Not in this patch (IP containers are binary): DMEM_0..7 Write_Depth_A 16384 -> 4096 and',
    'their init files, set by scripts/v7_impl_iisc_papercfg.tcl (stage ipprep).',
    'Result: RESULTS.md "Paper-configuration experiment (128 KB scratchpad)".',
], parts)

# 3. Coreless-V vl=16 paper configuration
AC = os.path.join(ROOT, 'external_2026', 'atee_paper_cfg', 'vector_unit')
parts = []
for n in sorted(os.listdir(AC)):
    if n.endswith('.orig'):
        continue
    b = rd(os.path.join(AC, n)); a = rd(os.path.join(ROOT, 'rtl', 'vector_unit', n))
    rec('external_2026/atee_paper_cfg/vector_unit/' + n, b)
    if a != b:
        parts.append(diff(a, b, 'vector_unit/' + n, 'vector_unit/' + n))
write('03_atee_paper_cfg_128KB.patch', [
    'EXPERIMENT (2026-11-14), "paper configuration" of ATEE-Lite vl=16: 4K x 32 per DMEM',
    'bank (128 KB). Applies to external_2026/atee_paper_cfg/vector_unit/, a copy of',
    'rtl/vector_unit/ AFTER patch 01 (paths below are relative to external_2026/atee_paper_cfg/).',
    '14 -> 12 on 8 lines in 5 files. Built by scripts/v7_impl_atee_papercfg.tcl.',
    'Result: RESULTS.md "Paper-configuration experiment (128 KB scratchpad)".',
], parts)

# 4. DSP-macro stand-ins (new files; their repo instantiates but does not ship these IPs)
parts = []
for n in ['xbip_dsp48_macro_missing.v', 'xbip_dsp48_macro_zero.v']:
    b = rd(os.path.join(ROOT, 'external', 'iisc_sim', n))
    parts.append(diff(None, b, None, 'external/iisc_sim/' + n))
write('04_dsp48_macro_standins.patch', [
    'Stand-ins for xbip_dsp48_macro_1 / _2, which their rtl/EVA/EVA_update.v instantiates',
    'but their repository does not ship. NEW files written for this project (ASSUMED',
    'functions, not checked against the original IP); the same two files are also in',
    'external/iisc_sim/ of this package. _missing = A*B+C and (D+A)*B+C, one register;',
    '_zero = all outputs 0 (sensitivity test). Both give identical results on every',
    'run where they were compared: RESULTS.md "Data-TLB stand-in probe" and',
    '"A.1 - DSP-macro stand-ins during inference".',
    'The Vivado 2026.1 copies (external_2026/iisc_copy/, iisc_paper_cfg/) use _missing.',
], parts)

# 5. their constraints.xdc without timing exceptions (optional no-exceptions run)
rel = 'Source code/constraints/constraints.xdc'
a = rd(os.path.join(UP, rel)); b = rd(os.path.join(ROOT, 'external_2026', 'iisc_copy', 'constraints_noexc.xdc'))
write('05_iisc_constraints_noexc.patch', [
    'Their constraints.xdc with the 34 timing exceptions and the 3 Tcl variable lines they',
    'use commented out; pin constraints unchanged. Reference run only (2026-11-17, task E);',
    'their timing is quoted WITH exceptions. The setup script writes the result to',
    'external_2026/iisc_copy/constraints_noexc.xdc. Used by scripts/v7_impl_iisc_noexc.tcl.',
], [diff(a, b, rel, 'constraints_noexc.xdc')])
rec('external_2026/iisc_copy/constraints_noexc.xdc', b)

# conv8_3 init files of the 2026.1 copies: must equal their shipped Outputfiles
OF = os.path.join(UP, 'benchmarks', 'benchmarks', 'conv', 'conv8_3', 'Outputfiles')
for cp in ['iisc_copy', 'iisc_paper_cfg']:
    d = os.path.join(ROOT, 'external_2026', cp, 'conv8_3_coe')
    for n in sorted(os.listdir(d)):
        b = rd(os.path.join(d, n)); assert b == rd(os.path.join(OF, n)), (cp, n)
        rec('external_2026/%s/conv8_3_coe/%s' % (cp, n), b)

with open(SHA, 'w', newline='\n') as f:
    for h, p in sha:
        f.write('%s  %s\n' % (h, p))
print('wrote expected_sha256.txt,', len(sha), 'entries')
