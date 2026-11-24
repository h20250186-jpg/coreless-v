#!/usr/bin/env python3
"""NEW (2026-11-19). Helper for scripts/v7_rtlsaif_iisc_cnn.ps1 (RTL-SAIF power
of THEIR cnn_demo in Vivado 2026.1).
  preload <work>      writes the words of <work>/preload.txt (img_buf[] and
                      pflag, written by scripts/iisc_bench_prep.py) into
                      <work>/mainMem.mif (one binary word per line). The 2019.1
                      testbench wrote the same words into the memory model
                      before reset release; the 2026.1 copy loads them from the
                      .mif at time zero instead.
  check <work> <ref>  gate: windows (dump.txt) and the final DMEM / VRF dumps of
                      the 2026.1 run against the 2019.1 run <ref> of the same image.
"""
import os, sys

def preload(work):
    p = os.path.join(work, 'mainMem.mif')
    lines = open(p).read().split('\n')
    if lines and lines[-1] == '':
        lines = lines[:-1]
    pl = open(os.path.join(work, 'preload.txt')).read().split()
    n = int(pl[0])
    ch = 0
    for i in range(n):
        idx, v = int(pl[1 + 2 * i], 16), int(pl[2 + 2 * i], 16)
        new = format(v, '032b')
        if lines[idx] != new:
            ch += 1
        lines[idx] = new
    with open(p, 'w', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    print('mainMem.mif: %d preload words written (%d changed a word), %d lines' % (n, ch, len(lines)))

def words(path):
    return [x.strip().lower().lstrip('0') or '0' for x in open(path) if x.strip()]

def check(work, ref):
    for fn in ['dump.txt']:
        a = open(os.path.join(work, fn)).read().split('\n')
        b = open(os.path.join(ref, fn)).read().split('\n')
        print('%s 2026.1: %s' % (fn, ' | '.join(l for l in a if l)))
        print('%s 2019.1: %s' % (fn, ' | '.join(l for l in b if l)))
        w26 = [l for l in a if l.startswith('W')]; w19 = [l for l in b if l.startswith('W')]
        print('  windows identical: %s' % (w26 == w19))
    tot = same = 0
    for kind, nb in (('dmem', 8), ('vrf', 8)):
        ks = ke = 0
        for i in range(nb):
            pa = os.path.join(work, '%s_%d.txt' % (kind, i)); pb = os.path.join(ref, '%s_%d.txt' % (kind, i))
            if not os.path.exists(pa):
                print('  %s missing' % pa); continue
            x, y = words(pa), words(pb)
            ke += len(y)
            ks += sum(1 for u, v in zip(x, y) if u == v) if len(x) == len(y) else 0
            if len(x) != len(y):
                print('  %s: length %d vs %d' % (pa, len(x), len(y)))
        print('  %s: %d of %d words identical to the 2019.1 run' % (kind, ks, ke))

if __name__ == '__main__':
    if sys.argv[1] == 'preload':
        preload(sys.argv[2])
    else:
        check(sys.argv[2], sys.argv[3])
