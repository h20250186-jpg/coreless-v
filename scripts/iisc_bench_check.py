#!/usr/bin/env python3
"""NEW (2026-11-15). Checks one run of scripts/run_iisc_bench.ps1: reads
bench.json (from iisc_bench_prep.py) and dump.txt (from iisc_tb_bench.v) in the
run directory and prints cycles and exactness against the Python reference and
against THEIR expected_output[] where the program has one.
Usage: python iisc_bench_check.py <run dir>
"""
import json, os, sys

def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x

def main():
    d = sys.argv[1]
    b = json.load(open(os.path.join(d, 'bench.json')))
    mem, vrf, W = {}, {}, []
    t_end, xr, cnt = None, None, None
    for ln in open(os.path.join(d, 'dump.txt')):
        p = ln.split()
        if not p: continue
        if p[0] == 'M': mem[int(p[1], 16)] = int(p[2], 16) if 'x' not in p[2].lower() else None
        elif p[0] == 'V': vrf[int(p[1])] = int(p[2], 16) if 'x' not in p[2].lower() else None
        elif p[0] == 'W': W.append([int(p[2]), int(p[3]), int(p[4])])
        elif p[0] == 'E': t_end = int(p[1])
        elif p[0] == 'X': xr = [int(v) for v in p[1:]]
        elif p[0] == 'C': cnt = p[1:]
    # final DMEM / VRF contents written by iisc_bench_dump.tcl
    def load(fn):
        p = os.path.join(d, fn)
        if not os.path.exists(p): return None
        return [None if 'x' in v.lower() or 'u' in v.lower() else int(v, 16) for v in open(p).read().split()]
    banks = [load('dmem_%d.txt' % k) for k in range(8)]
    vrfb = [load('vrf_%d.txt' % k) for k in range(8)]
    if all(x is not None for x in banks):
        # order check: rows never written by the program must equal the initial image
        init = [[int(l, 2) for l in open(os.path.join(d, 'DMEM_%d.mif' % k))] for k in range(8)]
        same = sum(1 for k in range(8) for r in range(len(banks[k])) if banks[k][r] == init[k][r])
        rev = sum(1 for k in range(8) for r in range(len(banks[k])) if banks[k][len(banks[k]) - 1 - r] == init[k][r])
        n = sum(len(x) for x in banks)
        print('  DMEM dump: %d rows; equal to the initial image in %d (index order) / %d (reversed)' % (n, same, rev))
        if rev > same:
            banks = [x[::-1] for x in banks]
        for o in b['outputs']:
            if o['where'] == 'mem':
                for i in range(len(o['ref'])):
                    a = o['addr'] + 4 * i
                    mem[a] = banks[(a >> 2) & 7][(a >> 5) & 0x3FFF]
    if all(x is not None for x in vrfb) and len(vrfb[0]) == 32:
        # VHDL reg_array (31 downto 0): get_value lists index 31 first
        order = os.environ.get('VRF_ORDER', 'desc')
        regs = [x[::-1] if order == 'desc' else x for x in vrfb]
        for o in b['outputs']:
            if o['where'] == 'vrf':
                for e in range(len(o['ref'])):
                    vrf[e] = regs[e % 8][o['addr'] + e // 8]
        print('  VRF dump: 8 banks x 32 registers (order %s); v0 element 0..7 = %s'
              % (order, [regs[k][0] for k in range(8)]))
    print('CHECK %s (%s)' % (b['program'], b['rel']))
    for (name, e, r), (ti, to, x) in zip(b['windows'], W):
        print('  window %-10s reset->entry %d | entry->return %d | reset->return %d' % (name, ti, to - ti, to))
    if b['end_pc']:
        print('  reset -> main returns %d' % t_end)
    if b['err_count_addr']:
        print('  err_count writes %s, non-zero writes %s, last value %s' % tuple(cnt))
    for o in b['outputs']:
        ref, th = o['ref'], o['theirs']
        if o['where'] == 'mem':
            got = [mem.get(o['addr'] + 4 * i) for i in range(len(ref))]
        elif o['where'] == 'vrf':
            if not vrf:
                print('  %-30s: not read (run without VRF dump)' % o['label']); continue
            got = [vrf.get(i) for i in range(len(ref))]
        else:
            got = [W[-1][2]]
        got = [None if g is None else s32(g) for g in got]
        def cmp(a, lab):
            ok = sum(1 for i in range(len(a)) if got[i] is not None and got[i] == a[i])
            mx = max((abs(got[i] - a[i]) for i in range(len(a)) if got[i] is not None), default=None)
            unk = sum(1 for g in got if g is None)
            print('  %-30s vs %-22s: %d / %d exact, max |diff| %s%s' % (o['label'], lab, ok, len(a), mx,
                  (', %d undefined (x)' % unk) if unk else ''))
        cmp(ref, 'Python reference')
        if th:
            cmp(th, 'THEIR expected_output')
        if o['where'] == 'x10':
            ex = b['extra']
            print('  x10 at return %d (+1/+5/+10 cycles: %s); Python argmax %d (max value %d); label %d -> %s'
                  % (got[0], xr, ex['argmax'], ex['max_value'], ex['label'],
                     'CORRECT' if got[0] == ex['label'] else 'WRONG'))

if __name__ == '__main__':
    main()
