#!/usr/bin/env python3
"""NEW (2026-11-19, task H: provenance of the inherited vector unit).
Builds vector-unit source trees in sim_build_h/trees/<name>/vector_unit/ from
(a) their files at commit a0b43781 (read from external/i2srv32.zip, verified by
the zip comment) and (b) selected hunks of OUR rtl/vector_unit versions.
Nothing in rtl/ is changed.

A "hunk" here is one non-equal opcode of difflib.SequenceMatcher on the lines of
their file -> our file. `list` prints them with ids <file>:<n>.
Usage:
  python -I scripts/h_trees.py list
  python -I scripts/h_trees.py build <name> [<file>:<n> | <file>:all | cg_gt] ...
    cg_gt = only the one-line '>=' -> '>' change in count_gen.vhd (the off-by-one fix)
Every tree also gets our non-inherited files (controllers, tops, ibuf, config
regs, dmem_bram, div_gen_behav); whether they are compiled is up to the runner.
"""
import difflib, hashlib, os, shutil, sys, zipfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZIP = os.path.join(ROOT, 'external', 'i2srv32.zip')
OURS = os.path.join(ROOT, 'rtl', 'vector_unit')
OUT = os.path.join(ROOT, 'sim_build_h', 'trees')
COMMIT = 'a0b43781b03d8b9d5e4e217675e229a57da3bc62'
INH = ['alu.vhd', 'count_gen.vhd', 'cpu_inf.vhd', 'dmem_addr_xbar.vhd', 'exe_unit.vhd', 'lsu.vhd',
       'multicycle_ops.vhd', 'mypack.vhd', 'stall_gen.vhd', 'vec_decoder.v', 'vector_top.v', 'vminmax.vhd',
       'vrf_bank.vhd', 'v_wrapper.v', 'wrapper.vhd', 'xoutreg.vhd']

def upstream():
    z = zipfile.ZipFile(ZIP)
    assert z.comment.decode() == COMMIT, z.comment
    d = {}
    for n in z.namelist():
        if '/Source code/rtl/vector_unit/' in n and n.split('/')[-1] in INH:
            d[n.split('/')[-1]] = z.read(n)
    assert len(d) == len(INH)
    return d

def L(b):
    return b.decode('latin-1').splitlines(True)

def opcodes(a, b):
    return [o for o in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if o[0] != 'equal']

def apply(a, b, ops):
    out, pos = [], 0
    for tag, i1, i2, j1, j2 in sorted(ops, key=lambda o: o[1]):
        out += a[pos:i1] + b[j1:j2]
        pos = i2
    return out + a[pos:]

def main():
    up = upstream()
    if sys.argv[1] == 'list':
        for f in INH:
            ours = open(os.path.join(OURS, f), 'rb').read()
            if ours == up[f]:
                continue
            a, b = L(up[f]), L(ours)
            for k, (tag, i1, i2, j1, j2) in enumerate(opcodes(a, b)):
                print('%s:%d  %s their %d-%d -> our %d-%d' % (f, k, tag, i1 + 1, i2, j1 + 1, j2))
                for s in a[i1:i2][:6]:
                    print('     -', s.rstrip()[:110])
                for s in b[j1:j2][:6]:
                    print('     +', s.rstrip()[:110])
        return
    name, specs = sys.argv[2], sys.argv[3:]
    d = os.path.join(OUT, name, 'vector_unit')
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    files = {f: L(up[f]) for f in INH}
    want = {}
    for s in specs:
        if s == 'cg_gt':
            t = ''.join(files['count_gen.vhd'])
            old = '\telsif count_internal >= terminal_count then'
            assert t.count(old) == 1
            files['count_gen.vhd'] = L(t.replace(old, '\telsif count_internal > terminal_count then').encode('latin-1'))
            continue
        f, k = s.split(':')
        want.setdefault(f, set()).add(k)
    for f, ks in want.items():
        a, b = L(up[f]), L(open(os.path.join(OURS, f), 'rb').read())
        ops = opcodes(a, b)
        sel = ops if 'all' in ks else [ops[int(k)] for k in sorted(ks, key=int)]
        files[f] = apply(a, b, sel)
    for f in INH:
        open(os.path.join(d, f), 'wb').write(''.join(files[f]).encode('latin-1'))
    for f in os.listdir(OURS):
        if f not in INH and not f.endswith('.orig'):
            shutil.copyfile(os.path.join(OURS, f), os.path.join(d, f))
    with open(os.path.join(OUT, name, 'spec.txt'), 'w') as fh:
        fh.write('base: I2SRV32-V commit %s (external/i2srv32.zip)\nhunks: %s\n' % (COMMIT, ' '.join(specs) or '(none)'))
        for f in INH:
            b = ''.join(files[f]).encode('latin-1')
            fh.write('%s  %s  %s\n' % (hashlib.sha256(b).hexdigest(), f,
                     '=their' if b == up[f] else ('=ours' if b == open(os.path.join(OURS, f), 'rb').read() else 'mixed')))
    print(open(os.path.join(OUT, name, 'spec.txt')).read())

main()
