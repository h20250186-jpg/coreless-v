#!/usr/bin/env python3
"""NEW (2026-11-17, scalar-operand variant). Read-only check of runs of
scripts/run_atee_sc.ps1.
  conv runs (dir sim_build/atee_sc/conv/conv<S>[_distinct]): every output word
      against the Python reference (gen_conv_sizes.py) and THEIR
      expected_output (not for the distinct set); cycles.
  cnn runs (dir with img<k> subdirs): layer-1 / layer-2 outputs (plain, NOT
      replicated) against THEIR Y / Y2 (DMEM dumps of their design's runs,
      sim_build/iisc_bench/cnn_img<k>) and the Python reference; FC scores
      against the reference; class against reference, label and THEIR digit;
      cycles per layer (total and in convoy states).
Usage: python atee_sc_check.py conv <dir> [<dir> ...]
       python atee_sc_check.py cnn <run dir> [from to]
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from atee_cnn_check import theirs, s32          # unchanged helper (their Y / Y2 / digit)

def read_run(d):
    if not os.path.exists(os.path.join(d, 'cnn_dump.txt')):
        return None
    ref = json.load(open(os.path.join(d, 'cnn_ref.json')))
    mem = {}
    for ln in open(os.path.join(d, 'cnn_dump.txt')):
        a, v = ln.split()
        mem[int(a, 16)] = s32(int(v, 16))
    log = open(os.path.join(d, 'xsim_run.log')).read()
    m = re.search(r'CNN_DONE cycles (\d+) class (\d+) err (\d+) hostwe (\d+)', log)
    lay = [int(x) for x in re.findall(r'layer \d+: start at \+\d+, cycles (\d+)', log)]
    conv = [int(x) for x in re.findall(r'\(convoy states (\d+), other', log)]
    return ref, mem, m, lay, conv

def check_conv(dirs):
    for d in dirs:
        rr = read_run(d)
        if not rr:
            print('%s: no dump' % d); continue
        ref, mem, m, lay, conv = rr
        base = int(ref['layout']['OUT'])
        got = [mem.get(base + 4 * i) for i in range(len(ref['golden']))]
        ex_g = sum(1 for a, b in zip(got, ref['golden']) if a == b)
        line = '%s: cycles %s (convoy states %s), cfg_error %s, hostwe %s ; outputs exact vs reference %d / %d' % (
            os.path.basename(d), m.group(1) if m else None, conv, m.group(3) if m else None,
            m.group(4) if m else None, ex_g, len(got))
        if ref.get('theirs'):
            ex_t = sum(1 for a, b in zip(got, ref['theirs']) if a == b)
            line += ' ; vs THEIR expected_output %d / %d' % (ex_t, len(got))
        print(line)

def check_cnn(run, lo, hi):
    rs = []
    for k in range(lo, hi + 1):
        rr = read_run(os.path.join(run, 'img%d' % k))
        if not rr:
            continue
        ref, mem, m, lay, conv = rr
        L = ref['layout']
        ty1, ty2, tdig = theirs(k)
        r = dict(k=k, label=ref['label'], cycles=int(m.group(1)) if m else None, lay=tuple(lay), conv=tuple(conv),
                 err=int(m.group(3)) if m else None, hostwe=int(m.group(4)) if m else None, tdig=tdig)
        y1 = [mem.get(int(L['OUT1']) + 4 * i) for i in range(2704)]
        r['L1t'] = sum(1 for a, b in zip(y1, ty1) if a == b); r['L1r'] = sum(1 for a, b in zip(y1, ref['y1']) if a == b)
        if ref['layers'] >= 2:
            y2 = [mem.get(int(L['OUT2']) + 4 * i) for i in range(800)]
            r['L2t'] = sum(1 for a, b in zip(y2, ty2) if a == b); r['L2r'] = sum(1 for a, b in zip(y2, ref['y2']) if a == b)
        if ref['layers'] >= 3:
            fc = [mem.get(int(L['OUT3']) + 4 * i) for i in range(16)]
            r['fc'] = sum(1 for i in range(10) if fc[i] == ref['fc'][i]); r['pad0'] = sum(1 for i in range(10, 16) if fc[i] == 0)
            r['cls'] = mem.get(int(L['CLASS'])); r['port'] = int(m.group(2)) if m else None; r['ref_am'] = ref['argmax']
        rs.append(r)
    n = len(rs)
    print('run %s: %d images checked' % (run, n))
    if not n:
        return
    agg = lambda f: sum(1 for r in rs if f(r))
    print('  cycles (layer-busy): %s' % sorted(set(r['cycles'] for r in rs)))
    print('  per-layer cycles: %s' % sorted(set(r['lay'] for r in rs)))
    print('  per-layer cycles in convoy states (ISSUE/WAIT/NEXT): %s' % sorted(set(r['conv'] for r in rs)))
    print('  cfg_error = 0: %d / %d ; host writes while busy = 0: %d / %d' % (agg(lambda r: r['err'] == 0), n, agg(lambda r: r['hostwe'] == 0), n))
    print('  layer 1 (13x13x16 = 2704): images bit-exact vs THEIR output %d / %d (values %d / %d) ; vs reference %d / %d'
          % (agg(lambda r: r['L1t'] == 2704), n, sum(r['L1t'] for r in rs), 2704 * n, agg(lambda r: r['L1r'] == 2704), n))
    if 'L2t' in rs[0]:
        print('  layer 2 (5x5x32 = 800): images bit-exact vs THEIR output %d / %d (values %d / %d) ; vs reference %d / %d'
              % (agg(lambda r: r['L2t'] == 800), n, sum(r['L2t'] for r in rs), 800 * n, agg(lambda r: r['L2r'] == 800), n))
    if 'fc' in rs[0]:
        print('  FC scores: all 10 bit-exact vs reference %d / %d ; padded outputs 10..15 = 0: %d / %d'
              % (agg(lambda r: r['fc'] == 10), n, agg(lambda r: r['pad0'] == 6), n))
        print('  class: port == memory %d / %d ; == reference argmax %d / %d'
              % (agg(lambda r: r['port'] == r['cls']), n, agg(lambda r: r['cls'] == r['ref_am']), n))
        print('  CORRECT vs label: ATEE-SC %d / %d ; reference %d / %d ; THEIR design %d / %d'
              % (agg(lambda r: r['cls'] == r['label']), n, agg(lambda r: r['ref_am'] == r['label']), n,
                 agg(lambda r: r['tdig'] == r['label']), n))
        print('  ATEE-SC misses (image, label, class): %s' % [(r['k'], r['label'], r['cls']) for r in rs if r['cls'] != r['label']])
    bad = [r['k'] for r in rs if r['L1t'] != 2704 or ('L2t' in r and r['L2t'] != 800)
           or ('fc' in r and (r['fc'] != 10 or r['cls'] != r['ref_am']))]
    print('  images with ANY mismatch: %s' % (bad if bad else 'none'))

if __name__ == '__main__':
    if sys.argv[1] == 'conv':
        check_conv(sys.argv[2:])
    else:
        lo, hi = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (0, 99)
        check_cnn(sys.argv[2], lo, hi)
