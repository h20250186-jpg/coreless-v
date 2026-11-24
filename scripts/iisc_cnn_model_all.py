#!/usr/bin/env python3
"""NEW (2026-11-15). For all 100 images shipped in their repo
(Demo/Application/img.c, labels in expected_output.c): the exact Q8.24 Python
reference of cnn_demo (scripts/iisc_bench_prep.py), its arg-max, and the
arg-max of the model of what their design computes in layer3 ("FC elements 8,9
= bias3 only", found on image 73 and checked on every simulated image). These
are MODEL predictions; the measured digits come from the simulations
(scripts/iisc_bench_summary.py cnn).
Usage: python iisc_cnn_model_all.py
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iisc_bench_prep as p

_, syms, words = p.read_elf(os.path.join(p.BENCH, 'cnn_demo', 'riscv-spike.elf'))
b3, _ = p.arr(words, syms, 'bias3')
dimg = p.c_arrays(os.path.join(p.REPO, 'Demo', 'Application', 'img.c'))
labels = p.c_arrays(os.path.join(p.REPO, 'Demo', 'Application', 'expected_output.c'))

def amax(v):
    best = 0
    for n in range(10):
        if v[n] > v[best]:
            best = n
    return best

ref_ok = mod_ok = 0
rows = []
for k in range(100):
    extra = {'img_words': [(x & 0xFF) << 16 for x in dimg[k * 784:(k + 1) * 784]]}
    p.reference('cnn', words, syms, extra)
    fc = extra['fc_after_relu']
    r = amax(fc)
    m = amax(list(fc[:8]) + [b3[8], b3[9]])
    ref_ok += (r == labels[k]); mod_ok += (m == labels[k])
    rows.append((k, labels[k], r, m))
print('reference arg-max == label: %d / 100; model ("e8,e9 = bias") arg-max == label: %d / 100' % (ref_ok, mod_ok))
print('labels 8 or 9: %d' % sum(1 for r in rows if r[1] in (8, 9)))
print('reference misses:', [(k, l, r) for k, l, r, m in rows if r != l])
print('model misses (image, label, model digit):', [(k, l, m) for k, l, r, m in rows if m != l])
with open(os.path.join(p.ROOT, 'docs', 'iisc_cnn_model_all.txt'), 'w') as f:
    f.write('image label reference_argmax model_argmax\n')
    for r in rows:
        f.write('%d %d %d %d\n' % r)
print('written docs/iisc_cnn_model_all.txt')
