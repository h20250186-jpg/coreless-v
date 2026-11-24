#!/usr/bin/env python3
"""NEW (2026-11-17, scalar-operand variant). Slot-rule cycle model of
hbm_lite_controller_sc.v AS BUILT (convoy shapes taken from the RTL), for the
CONV2D 3x3 benchmarks (8/16/32/64) and the three cnn_demo layers.
Uses pack() and the slot rule (last real slot + 18 at vl = 16) of
scripts/cnn_schedule_model.py (unchanged, imported).
Only convoy cycles are modelled; the per-layer fixed cost (descriptor fetch,
init, DMEM -> IBUF copy, argmax) is printed separately: copy = n + 2 cycles.
Usage: python sc_schedule_model.py
"""
import math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cnn_schedule_model import pack, b_preload, cost, C

def model(H, W, IC, K, OC, pool, relu):
    OH, OW = H - K + 1, W - K + 1
    T = K * K * IC
    groups = OC // 16
    out = {'preload': 0, 'window': 0, 'stream': 0}
    if OH == 1 and OW == 1 and not pool:
        lasts = [3 + min(3, T)]
        left = T - min(3, T)
        while left > 0:
            n = min(4, left); left -= n
            lasts.append(3 + n)
        lasts.append(1 if relu else 0)
        out['stream'] = groups * sum(cost(l) for l in lasts)
        return out
    nwin = (OH // 2) * (OW // 2) if pool else (OH * OW) // 4
    chunks = [min(C, T - C * c) for c in range(math.ceil(T / C))]
    for g in range(groups):
        for ci, Tc in enumerate(chunks):
            final = ci == len(chunks) - 1
            out['preload'] += sum(cost(l) for l in b_preload(Tc))
            seq = ['L'] * 4 + ['M'] * (4 * Tc)
            if not final:
                seq += ['S'] * 4
            elif pool:
                seq += ['X'] * (4 if relu else 3) + ['S']
            else:
                seq += (['X'] * 4 if relu else []) + ['S'] * 4
            out['window'] += nwin * sum(cost(l) for l in pack(seq))
    return out

CASES = [('conv8_3', 8, 8, 1, 3, 16, False, False, 0), ('conv16_3', 16, 16, 1, 3, 16, False, False, 0),
         ('conv32_3', 32, 32, 1, 3, 16, False, False, 0), ('conv64_3', 64, 64, 1, 3, 16, False, False, 0),
         ('cnn layer 1', 28, 28, 1, 3, 16, True, True, 0), ('cnn layer 2', 13, 13, 16, 3, 32, True, True, 13 * 13 * 16),
         ('cnn layer 3 (FC)', 1, 1, 800, 1, 16, False, True, 800)]

def main():
    print('Scalar-operand controller as built: convoy cycles (slot rule, last + 18), copy = n + 2')
    for name, H, W, IC, K, OC, pool, relu, ncopy in CASES:
        o = model(H, W, IC, K, OC, pool, relu)
        print('  %-18s convoy %8d  %s  copy %s' % (name, sum(o.values()), {k: v for k, v in o.items() if v},
                                                  (ncopy + 2) if ncopy else '-'))

if __name__ == '__main__':
    main()
