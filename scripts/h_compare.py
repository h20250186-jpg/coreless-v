#!/usr/bin/env python3
"""NEW (2026-11-19, task H). Compares one run of scripts/h_run_sc.ps1 with the
RECORDED run of the same workload (read-only on both):
  - output dump (cnn_dump.txt, every stored DMEM word written by the testbench dump)
  - the CNN_DONE line (cycles, class, err, host writes while busy)
  - every per-layer cycle line
Prints one line: SAME / DIFFERENT with details.
Usage: python -I h_compare.py <new run dir> <recorded run dir>
"""
import re, sys, os
new, rec = sys.argv[1], sys.argv[2]
def load(d):
    log = open(os.path.join(d, 'xsim_run.log')).read()
    done = re.search(r'CNN_DONE[^\n]*', log)
    lay = re.findall(r'layer \d+: start at \+\d+, cycles \d+[^\n]*', log)
    dump = open(os.path.join(d, 'cnn_dump.txt')).read() if os.path.exists(os.path.join(d, 'cnn_dump.txt')) else None
    return (done.group(0) if done else None), lay, dump
a, b = load(new), load(rec)
msgs = []
if a[0] != b[0]: msgs.append('CNN_DONE new "%s" vs recorded "%s"' % (a[0], b[0]))
if a[1] != b[1]: msgs.append('layer lines differ: new %s vs recorded %s' % (a[1], b[1]))
if a[2] is None: msgs.append('no dump in new run')
elif a[2] != b[2]:
    A = dict(l.split() for l in a[2].splitlines()); B = dict(l.split() for l in b[2].splitlines())
    diff = [k for k in sorted(set(A) | set(B)) if A.get(k) != B.get(k)]
    msgs.append('dump: %d of %d words differ (first %s: new %s recorded %s)' % (len(diff), len(B), diff[0], A.get(diff[0]), B.get(diff[0])))
words = len(b[2].splitlines()) if b[2] else 0
print('  COMPARE %s vs recorded: %s' % (os.path.basename(new.rstrip('\\/')), 'SAME (dump %d words identical, CNN_DONE and layer cycles identical)' % words if not msgs else 'DIFFERENT: ' + '; '.join(msgs)))
