#!/usr/bin/env python3
"""NEW (2026-11-19, task H step 4). Read-only summary of the main-design runs on
one vector-unit tree (sim_build_h/<tree>/sc/...) against the RECORDED runs
(sim_build/atee_sc/conv, /paper, /L3): per workload, cycles new vs recorded and
the number of output-dump words that differ; for cnn_demo the totals over the
images present. Correctness against the references is printed separately by
scripts/atee_sc_check.py (unchanged), called by the caller.
Usage: python -I h_step4_summary.py <tree>
"""
import os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tree = sys.argv[1]
B = os.path.join(ROOT, 'sim_build_h', tree, 'sc')
R = os.path.join(ROOT, 'sim_build', 'atee_sc')

def load(d):
    lp = os.path.join(d, 'xsim_run.log')
    if not os.path.exists(lp):
        return None
    log = open(lp).read()
    m = re.search(r'CNN_DONE cycles (\d+) class (\d+) err (\d+) hostwe (\d+)', log)
    lay = [int(x) for x in re.findall(r'layer \d+: start at \+\d+, cycles (\d+)', log)]
    dp = os.path.join(d, 'cnn_dump.txt')
    dump = dict(l.split() for l in open(dp)) if os.path.exists(dp) else {}
    return (int(m.group(1)) if m else None), lay, dump

def cmp(new, rec):
    a, b = load(new), load(rec)
    if a is None:
        return None
    diff = sum(1 for k in set(a[2]) | set(b[2]) if a[2].get(k) != b[2].get(k))
    return a[0], b[0], a[1], b[1], diff, len(b[2])

print('tree %s' % tree)
for name, rec in [('conv8', 'conv/conv8'), ('conv16', 'conv/conv16'), ('conv32', 'conv/conv32'), ('conv64', 'conv/conv64'),
                  ('conv32_5', 'paper/conv32_5'), ('matmul16', 'paper/matmul16'), ('matmul32', 'paper/matmul32'),
                  ('matmul64', 'paper/matmul64')]:
    r = cmp(os.path.join(B, name), os.path.join(R, *rec.split('/')))
    if r is None:
        print('  %-9s not run' % name); continue
    print('  %-9s cycles %7d (recorded %7d, %+d)  output words differing %5d of %5d  -> %s'
          % (name, r[0], r[1], r[0] - r[1], r[4], r[5], 'SAME' if r[4] == 0 and r[0] == r[1] else 'DIFFERENT'))
cd = os.path.join(B, 'cnn')
if os.path.isdir(cd):
    ks = sorted(int(n[3:]) for n in os.listdir(cd) if n.startswith('img'))
    same = cyc_same = out_same = 0; dw = []; dc = set(); lays = set()
    for k in ks:
        r = cmp(os.path.join(cd, 'img%d' % k), os.path.join(R, 'L3', 'img%d' % k))
        if r is None:
            continue
        dc.add(r[0] - r[1]); lays.add(tuple(x - y for x, y in zip(r[2], r[3])))
        cyc_same += r[0] == r[1] and r[2] == r[3]; out_same += r[4] == 0; dw.append(r[4])
        same += r[0] == r[1] and r[2] == r[3] and r[4] == 0
    print('  cnn_demo  %d images: identical to recorded (outputs AND cycles) %d ; outputs identical %d ; cycles identical %d'
          % (len(ks), same, out_same, cyc_same))
    print('            cycle difference vs recorded (total): %s ; per layer: %s' % (sorted(dc), sorted(lays)))
    print('            output words differing per image: min %d, max %d, images with >0: %d' % (min(dw), max(dw), sum(1 for x in dw if x)))
