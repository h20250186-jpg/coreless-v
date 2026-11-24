#!/usr/bin/env python3
"""NEW (2026-11-15). Read-only analysis of the matmul32 run on THEIR design:
compares the output matrix read from their DMEM (dmem_<b>.txt in the run dir)
with A·B and with candidate models of what their matmul32.S computes
(accumulator v20 is not cleared between output rows).
Usage: python iisc_matmul32_analyze.py <run dir>
"""
import json, os, sys

def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x

d = sys.argv[1]
b = json.load(open(os.path.join(d, 'bench.json')))
o = b['outputs'][0]
banks = [[int(v, 16) for v in open(os.path.join(d, 'dmem_%d.txt' % k)).read().split()] for k in range(8)]
D = 32
hw = []
for i in range(D * D):
    a = o['addr'] + 4 * i
    hw.append(s32(banks[(a >> 2) & 7][(a >> 5) & 0x3FFF]))
ref = o['ref']
exact = [i for i in range(D * D) if hw[i] == ref[i]]
print('exact vs A.B: %d / %d, positions (row, col): %s' % (len(exact), D * D, [(i // D, i % D) for i in exact][:20]))
# model 1: accumulator never cleared -> prefix sums over rows
cum = [0] * D
m1 = []
for i in range(D):
    for j in range(D):
        cum[j] = s32(cum[j] + ref[i * D + j])
    m1 += list(cum)
print('model "v20 never cleared" (row prefix sums): %d / %d exact' % (sum(1 for i in range(D * D) if hw[i] == m1[i]), D * D))
# model 2: elements 16..31 cleared after each row (vmul v22 at vl=32 covers v22..v23 = elements 16..31)
cum = [0] * D
m2 = []
for i in range(D):
    for j in range(D):
        cum[j] = s32(cum[j] + ref[i * D + j]) if j < 16 else ref[i * D + j]
    m2 += list(cum)
print('model "elements 16..31 cleared, 0..15 carried": %d / %d exact' % (sum(1 for i in range(D * D) if hw[i] == m2[i]), D * D))
# model 3: columns 0..15 as model 1, columns 16..31 stored as 0
m3 = [m1[i] if (i % D) < 16 else 0 for i in range(D * D)]
print('model "cols 0..15 row prefix sums, cols 16..31 stored as 0": %d / %d exact'
      % (sum(1 for i in range(D * D) if hw[i] == m3[i]), D * D))
for r in (0, 1, 2, 31):
    print('row %2d hw  [0..3,16..19]: %s' % (r, [hw[r * D + j] for j in (0, 1, 2, 3, 16, 17, 18, 19)]))
    print('row %2d A.B [0..3,16..19]: %s' % (r, [ref[r * D + j] for j in (0, 1, 2, 3, 16, 17, 18, 19)]))
    print('row %2d m1  [0..3,16..19]: %s' % (r, [m1[r * D + j] for j in (0, 1, 2, 3, 16, 17, 18, 19)]))
