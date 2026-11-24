#!/usr/bin/env python3
"""NEW (2026-11-17, task G). Read-only check of Coreless-V cnn_demo runs
(scripts/run_atee_cnn.ps1) against
  THEIRS : their layer outputs Y (layer 1+2) and Y2 (layer 3+4) read from the
           DMEM dumps of their design's runs (sim_build/iisc_bench/cnn_img<k>,
           2026-11-15, assumed stand-ins; A.1 showed the zero-stand-in runs give
           identical DMEM), digit = their a0 at layer3 return (dump.txt W 2)
  REF    : the exact Python reference (cnn_ref.json, iisc_bench_prep.reference)
For each image: layer-1 output (16 copies of every value must be equal; copy 0
compared), layer-2 output (same), FC scores (16 words: 10 vs REF, 6 padded
must be 0), class (vs REF argmax, label, and THEIR digit), cycles.
Usage: python atee_cnn_check.py <run dir, e.g. sim_build/atee_cnn/L1> [from to]
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, 'sim_build', 'iisc_bench')
Y_ADDR, Y2_ADDR = 0x10C840, 0x10F280

def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x

def theirs(k):
    d = os.path.join(BENCH, 'cnn_img%d' % k)
    banks = [open(os.path.join(d, 'dmem_%d.txt' % b)).read().split() for b in range(8)]
    def word(a):
        o = (a - 0x100000) // 4
        return s32(int(banks[o % 8][o // 8], 16))
    y1 = [word(Y_ADDR + 4 * i) for i in range(2704)]
    y2 = [word(Y2_ADDR + 4 * i) for i in range(800)]
    W = [l.split() for l in open(os.path.join(d, 'dump.txt')) if l.startswith('W ')]
    return y1, y2, int(W[2][4])

def check(run, k):
    d = os.path.join(run, 'img%d' % k)
    if not os.path.exists(os.path.join(d, 'cnn_dump.txt')):
        return None
    ref = json.load(open(os.path.join(d, 'cnn_ref.json')))
    L = ref['layout']
    mem = {}
    for ln in open(os.path.join(d, 'cnn_dump.txt')):
        a, v = ln.split()
        mem[int(a, 16)] = s32(int(v, 16))
    log = open(os.path.join(d, 'xsim_run.log')).read()
    m = re.search(r'CNN_DONE cycles (\d+) class (\d+) err (\d+) hostwe (\d+)', log)
    lay = [int(x) for x in re.findall(r'layer \d+: start at \+\d+, cycles (\d+)', log)]
    conv = [int(x) for x in re.findall(r'\(convoy states (\d+), other', log)]
    ty1, ty2, tdig = theirs(k)
    r = dict(k=k, label=ref['label'], cycles=int(m.group(1)) if m else None, layers_cyc=lay, conv_cyc=conv,
             err=int(m.group(3)) if m else None, hostwe=int(m.group(4)) if m else None, their_digit=tdig)
    def layer(base, n, refv, thv):
        rep_bad = 0; c0 = []
        for i in range(n):
            vals = [mem.get(base + 4 * (i * 16 + c)) for c in range(16)]
            if any(v != vals[0] for v in vals): rep_bad += 1
            c0.append(vals[0])
        ex_t = sum(1 for i in range(n) if c0[i] == thv[i])
        ex_r = sum(1 for i in range(n) if c0[i] == refv[i])
        md = max(abs(c0[i] - thv[i]) for i in range(n) if c0[i] is not None) if c0 else 0
        return dict(n=n, exact_theirs=ex_t, exact_ref=ex_r, rep_bad=rep_bad, maxdiff_theirs=md)
    r['L1'] = layer(int(L['OUT1']), 2704, ref['y1'], ty1)
    if ref['layers'] >= 2:
        r['L2'] = layer(int(L['OUT2']), 800, ref['y2'], ty2)
    if ref['layers'] >= 3:
        fc = [mem.get(int(L['OUT3']) + 4 * i) for i in range(16)]
        r['fc_exact_ref'] = sum(1 for i in range(10) if fc[i] == ref['fc'][i])
        r['fc_pad_zero'] = sum(1 for i in range(10, 16) if fc[i] == 0)
        r['class_mem'] = mem.get(int(L['CLASS']))
        r['class_port'] = int(m.group(2)) if m else None
        r['ref_argmax'] = ref['argmax']
    return r

def main():
    run = sys.argv[1]
    lo, hi = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (0, 99)
    rs = [x for x in (check(run, k) for k in range(lo, hi + 1)) if x]
    n = len(rs)
    print('run %s: %d images checked' % (run, n))
    if not n:
        return
    def agg(key):
        return sum(1 for r in rs if key(r))
    cyc = sorted(set(r['cycles'] for r in rs))
    print('  cycles (layer-busy): %s' % (cyc if len(cyc) <= 4 else '%d distinct, min %d max %d' % (len(cyc), cyc[0], cyc[-1])))
    lc = sorted(set(tuple(r['layers_cyc']) for r in rs))
    print('  per-layer cycles: %s' % lc)
    cc = sorted(set(tuple(r['conv_cyc']) for r in rs))
    if cc and cc[0]:
        print('  per-layer cycles in convoy states (ISSUE/WAIT/NEXT): %s' % cc)
    print('  cfg_error = 0: %d / %d ; host writes while busy = 0: %d / %d' % (agg(lambda r: r['err'] == 0), n, agg(lambda r: r['hostwe'] == 0), n))
    for Lk, nm in (('L1', 'layer 1 (conv+pool, 13x13x16 = 2704)'), ('L2', 'layer 2 (conv+pool, 5x5x32 = 800)')):
        if Lk in rs[0]:
            print('  %s:' % nm)
            print('    images bit-exact vs THEIR output (all values): %d / %d ; values exact %d / %d ; max |diff| %d'
                  % (agg(lambda r: r[Lk]['exact_theirs'] == r[Lk]['n']), n, sum(r[Lk]['exact_theirs'] for r in rs),
                     sum(r[Lk]['n'] for r in rs), max(r[Lk]['maxdiff_theirs'] for r in rs)))
            print('    images bit-exact vs Python reference: %d / %d ; values with a bad replica: %d'
                  % (agg(lambda r: r[Lk]['exact_ref'] == r[Lk]['n']), n, sum(r[Lk]['rep_bad'] for r in rs)))
    if 'fc_exact_ref' in rs[0]:
        print('  FC scores: images with all 10 bit-exact vs reference: %d / %d ; padded outputs 10..15 = 0: %d / %d'
              % (agg(lambda r: r['fc_exact_ref'] == 10), n, agg(lambda r: r['fc_pad_zero'] == 6), n))
        print('  class: port == memory: %d / %d ; == reference argmax: %d / %d'
              % (agg(lambda r: r['class_port'] == r['class_mem']), n, agg(lambda r: r['class_mem'] == r['ref_argmax']), n))
        print('  CORRECT vs label: Coreless-V %d / %d ; reference %d / %d ; THEIR design %d / %d'
              % (agg(lambda r: r['class_mem'] == r['label']), n, agg(lambda r: r['ref_argmax'] == r['label']), n,
                 agg(lambda r: r['their_digit'] == r['label']), n))
        wrong = [(r['k'], r['label'], r['class_mem']) for r in rs if r['class_mem'] != r['label']]
        print('  Coreless-V misses (image, label, class): %s' % wrong)
        tw = [(r['k'], r['label'], r['their_digit']) for r in rs if r['their_digit'] != r['label']]
        print('  THEIR misses (image, label, digit): %s' % tw)
    bad = [r['k'] for r in rs if r['L1']['exact_theirs'] != r['L1']['n'] or r['L1']['rep_bad']
           or ('L2' in r and (r['L2']['exact_theirs'] != r['L2']['n'] or r['L2']['rep_bad']))
           or ('fc_exact_ref' in r and (r['fc_exact_ref'] != 10 or r['class_mem'] != r['ref_argmax']))]
    print('  images with ANY mismatch: %s' % (bad if bad else 'none'))

if __name__ == '__main__':
    main()
