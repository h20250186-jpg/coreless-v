#!/usr/bin/env python3
"""NEW (2026-11-17). Cycle model for cnn_demo on Coreless-V at vl = 16.

Two schedules, both costed with the MEASURED slot rule (design note section 8:
a convoy costs its last real slot + 18 cycles at vl = 16; all 8 slots issued,
early clear 16 cycles after the last real slot):

  B  the schedule built in task G (hbm_lite_controller_cnn.v): replicated
     inputs, chunks of C = 9 preloaded weight taps, partial sums spilled in
     place, bias as the chunk-0 partial sum, 2x2 max-pool in a register
     (max into R_pool; the first pixel of a window takes max(acc, zero), which
     is the ReLU), pooled result written REPLICATED 16x for the next layer by
     strided stores (7 + 7 + 2 per output vector), FC = 1x1 conv, ReLU + plain
     store, argmax read back by the controller.
  F  the scalar-operand study (task F, design note section 10): no input
     replication; the input value is the MAC's scalar operand (ALUSrc = 01,
     RS1) from a controller-side input buffer (IBUF); 4 accumulators per 2x2
     window resident across one chunk; weights of a 9-tap chunk preloaded;
     pooled result stored once (plain) and copied DMEM -> IBUF between layers.

Prints per-layer convoy counts and cycles. Only CONVOY cycles come from the
slot rule; fixed per-layer overheads (descriptor fetch, init, argmax, copy)
are listed separately and labelled.
Usage: python cnn_schedule_model.py
"""
import math

SLOT = 18          # vl = 16
C = 9              # taps per chunk

def cost(last):
    return last + SLOT

# ---------------------------------------------------------------- schedule B
def b_tap_split(tl, first, npost, has_store):
    """taps taken by this convoy (rule of hbm_lite_controller_cnn.v)."""
    mb = 4 if first else 3
    cap = (7 - mb - npost) if has_store else (8 - mb - npost)
    cap = min(cap, 3)
    if tl <= cap:
        return tl, True
    return min(3, tl - 1), False

def b_pixel_chunk(Tc, final, pool, relu):
    """last-slot list for one pixel and one chunk."""
    lasts = []
    tl, first = Tc, True
    if not final:
        npost, st = 1, True            # psum store
    elif pool:
        npost, st = 1, False           # max into R_pool
    else:
        npost, st = (2 if relu else 1), True   # [ReLU] + store
    while True:
        n, last_c = b_tap_split(tl, first, npost, st)
        mb = 4 if first else 3
        last = mb + n - 1
        if last_c:
            last += npost
        lasts.append(last)
        tl -= n
        first = False
        if last_c:
            return lasts

def b_preload(Tc):
    return [min(3, Tc - 3 * i) - 1 for i in range(math.ceil(Tc / 3))]

def model_b(L):
    H, W, IC, K, OC, pool, relu = L['H'], L['W'], L['IC'], L['K'], L['OC'], L['pool'], L['relu']
    OH, OW = H - K + 1, W - K + 1
    T = K * K * IC
    groups = OC // 16
    chunks = [min(C, T - C * c) for c in range(math.ceil(T / C))]
    P = (OH // 2) * (OW // 2) * 4 if pool else OH * OW
    PP = (OH // 2) * (OW // 2)
    conv = {'preload': 0, 'pixel': 0, 'replicate': 0}
    ncv = {'preload': 0, 'pixel': 0, 'replicate': 0}
    for g in range(groups):
        for ci, Tc in enumerate(chunks):
            final = ci == len(chunks) - 1
            pl = b_preload(Tc)
            conv['preload'] += sum(cost(l) for l in pl); ncv['preload'] += len(pl)
            px = b_pixel_chunk(Tc, final, pool, relu)
            conv['pixel'] += P * sum(cost(l) for l in px); ncv['pixel'] += P * len(px)
            if final and pool and L['rep']:
                rep = [6, 6, 1]                   # strided stores k = 0..6 | 7..13 | 14..15
                conv['replicate'] += PP * sum(cost(l) for l in rep); ncv['replicate'] += PP * len(rep)
    return conv, ncv, dict(P=P, T=T, chunks=len(chunks), groups=groups)

# ---------------------------------------------------------------- schedule F
def pack(seq):
    """seq: list of kinds ('L','M','X','S'); greedy fill of 8 slots; a store may
    not sit in slot 7 (moved to the next convoy). Returns the last-slot list."""
    lasts, slot = [], 0
    for k in seq:
        if slot == 8 or (k == 'S' and slot == 7):
            lasts.append(slot - 1 if slot == 8 else 6); slot = 0
        slot += 1
    lasts.append(slot - 1)
    return lasts

def model_f(L):
    H, W, IC, K, OC, pool = L['H'], L['W'], L['IC'], L['K'], L['OC'], L['pool']
    OH, OW = H - K + 1, W - K + 1
    T = K * K * IC
    groups = OC // 16
    chunks = [min(C, T - C * c) for c in range(math.ceil(T / C))]
    conv = {'preload': 0, 'window': 0, 'stream': 0}
    if not pool:          # FC (P = 1): weights streamed, 4 taps per convoy, acc resident
        # first convoy: bias (slot 0) | W W W (1-3) | MAC x3 (4-6)
        # then:        W x n (0..n-1) | MAC x n (4..3+n), n <= 4, each MAC 4 slots after its W
        # end:         ReLU | store (one extra convoy)
        lasts = [6]
        left = T - 3
        while left > 0:
            n = min(4, left); left -= n
            lasts.append(3 + n)
        tail = pack(['M', 'S'])
        conv['stream'] = groups * (sum(cost(l) for l in lasts) + sum(cost(l) for l in tail))
        return conv, dict(T=T, groups=groups)
    PP = (OH // 2) * (OW // 2)
    for g in range(groups):
        for ci, Tc in enumerate(chunks):
            final = ci == len(chunks) - 1
            conv['preload'] += sum(cost(l) for l in b_preload(Tc))
            seq = ['L'] * 4 + ['M'] * (4 * Tc)
            seq += (['X', 'X', 'X', 'X', 'S'] if final else ['S'] * 4)
            conv['window'] += PP * sum(cost(l) for l in pack(seq))
    return conv, dict(PP=PP, T=T, groups=groups, chunks=len(chunks))

LAYERS = [
    dict(name='layer 1 (conv 3x3, 16 filters, bias, ReLU, 2x2 pool)', H=28, W=28, IC=1, K=3, OC=16, pool=True, relu=True, rep=True),
    dict(name='layer 2 (conv 3x3x16, 32 filters, bias, ReLU, 2x2 pool)', H=13, W=13, IC=16, K=3, OC=32, pool=True, relu=True, rep=True),
    dict(name='layer 3 (FC 800 -> 10, padded to 16, bias, ReLU)', H=1, W=1, IC=800, K=1, OC=16, pool=False, relu=True, rep=False),
]
IISC = [56052, 175674, 9883]

def main():
    print('Slot rule: convoy = last real slot + %d cycles (vl = 16), chunks of %d taps' % (SLOT, C))
    print()
    print('Schedule B (as built in G), CONVOY cycles only (fixed per-layer overheads not included):')
    tb = 0
    for L, ii in zip(LAYERS, IISC):
        conv, ncv, info = model_b(L)
        s = sum(conv.values()); tb += s
        print('  %s' % L['name'])
        print('    P=%(P)d pixels, T=%(T)d taps, %(chunks)d chunks, %(groups)d OC group(s)' % info)
        for k in conv:
            print('    %-10s convoys %7d  cycles %8d' % (k, ncv[k], conv[k]))
        print('    total %d   (IISc measured %d, ratio %.3f)' % (s, ii, s / ii))
    print('  all three layers, convoys only: %d (IISc 241,689 incl. 80 overhead)' % tb)
    print()
    print('Schedule F (scalar operand, PROJECTION, untested assumptions in the design note):')
    tf = 0
    for L, ii in zip(LAYERS, IISC):
        conv, info = model_f(L)
        s = sum(conv.values()); tf += s
        print('  %s: %s -> %d (IISc %d, ratio %.3f)' % (L['name'], {k: v for k, v in conv.items() if v}, s, ii, s / ii))
    copy = 13 * 13 * 16 + 5 * 5 * 32
    print('  + DMEM -> IBUF copies between layers, 1 word per cycle: %d + %d = %d (estimate)' % (13 * 13 * 16, 5 * 5 * 32, copy))
    print('  all three layers: %d convoy + %d copy = %d (IISc 241,689)' % (tf, copy, tf + copy))

if __name__ == '__main__':
    main()
