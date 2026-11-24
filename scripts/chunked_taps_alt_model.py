#!/usr/bin/env python3
"""NEW (2026-11-16). Layer-2 alternatives for docs/chunked_taps_design.md
(section 8), PROJECTION ONLY, no RTL.

Cost rule ("slot rule"): a convoy costs (last occupied slot + 10) cycles at
vl=8 and (last occupied slot + 18) at vl=16 (all 8 slots issued, early clear 16
cycles after the last real slot). MEASURED: it equals the FSM count in all 10
runs of testbench/convoy_chunk_tb.v (2026-11-16) and reproduces the six
recorded controller counts (printed by check()). It replaces the flat
"23 per vl=16 convoy" and "2n+9" constants of scripts/chunked_taps_model.py
(unchanged; its B numbers are printed for reference as B-old).
ReLU on the B path is the measured +3 per pixel at both vl (3,619 - 3,403 =
72 x 3; 73 - 70), as in the existing model.

Slot layouts (rules: no load directly before its reader, store <= slot 6,
unit-stride loads, every slot occupied at vl=16):
  B  per pixel and chunk, convoys of <= 3 taps:
       [PSUM] | X x n | MAC x n | [STORE]   (PSUM in slot 0 on chunks > 0 and,
       with a bias, on chunk 0; a 1-tap convoy needs one gap slot before its
       MAC; a convoy whose store would land in slot 7 is split: store alone in
       one extra convoy)
     preload convoys of <= 3 loads.
  D  per tap and Q-pixel tile, accumulators resident for ALL taps:
       a: W | X x q | MAC x q  (q <= 3)    b..: X x k | MAC x k  (k <= 4)
     tile start: Q bias loads into the accumulators; tile end: (ReLU, store)
     pairs, 3 per convoy.
  F  = D with the pixel value as a SCALAR operand (vmacc.vx, their layer2's
     form): per tap W | gap | MAC x q (q <= 6). ASSUMES a new controller-side
     input buffer supplying each MAC's scalar operand at no cycle cost.
"""
import math, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chunked_taps_model as old

INIT = 19

def cost(vl, last):
    return last + (10 if vl == 8 else 18)

def b_convoys(n_taps, psum, store):
    """last-slot list for one pixel and chunk on path B."""
    sizes = [3] * (n_taps // 3) + ([n_taps % 3] if n_taps % 3 else [])
    lasts = []
    for k, n in enumerate(sizes):
        s = 1 if (psum and k == 0) else 0
        m0 = s + 2 if n == 1 else s + n
        last = m0 + n - 1
        if store and k == len(sizes) - 1:
            if last + 1 <= 6:
                last += 1
            else:
                lasts.append(last); lasts.append(0); continue   # store alone in slot 0 of an extra convoy
        lasts.append(last)
    return lasts

def opt_B(vl, P, T, OC, bias, relu, C=None):
    C = C or (15 if vl == 8 else 9)
    g = math.ceil(OC / vl)
    ch = old.chunks(T, C)
    tot = INIT
    for _ in range(g):
        for ci, Tc in enumerate(ch):
            pre = sum(cost(vl, min(3, Tc - 3 * i) - 1) for i in range(math.ceil(Tc / 3)))
            px = sum(cost(vl, l) for l in b_convoys(Tc, ci > 0 or bias, True))
            if relu and ci == len(ch) - 1:
                px += 3
            tot += pre + P * px
    return tot

def d_tap_lasts(q):
    out = []
    a = min(3, q)
    out.append(3 if a == 1 else 1 + a + a - 1)          # W 0 | X 1..a | MAC a+1..2a
    r = q - a
    while r > 0:
        k = min(4, r); r -= k
        out.append(2 if k == 1 else 2 * k - 1)
    return out

def tile_ends(q, vl):
    start = sum(cost(vl, min(8, q - 8 * i) - 1) for i in range(math.ceil(q / 8)))
    end = sum(cost(vl, 2 * min(3, q - 3 * i) - 1) for i in range(math.ceil(q / 3)))
    return start + end

def opt_D(vl, P, T, OC, Q):
    def tile(q):
        return T * sum(cost(vl, l) for l in d_tap_lasts(q)) + tile_ends(q, vl)
    g = math.ceil(OC / vl); full, rem = divmod(P, Q)
    return INIT + g * (full * tile(Q) + (tile(rem) if rem else 0))

def opt_F(vl, P, T, OC, Q):
    def tile(q):
        per_tap = sum(cost(vl, 1 + min(6, q - 6 * i)) for i in range(math.ceil(q / 6)))
        return T * per_tap + tile_ends(q, vl)
    g = math.ceil(OC / vl); full, rem = divmod(P, Q)
    return INIT + g * (full * tile(Q) + (tile(rem) if rem else 0))

def regs(vl, n_vectors):
    return n_vectors * (1 if vl == 8 else 2)

def check():
    rows = [('vl=8  conv8_3', opt_B(8, 36, 9, 16, False, False), 3403),
            ('vl=8  CONV2D 3x3 64x64', opt_B(8, 3844, 9, 16, False, False), 353739),
            ('vl=8  MNIST conv1 ReLU', opt_B(8, 676, 9, 16, False, True), 66339),
            ('vl=16 conv8_3', opt_B(16, 36, 9, 16, False, False), 2599),
            ('vl=16 CONV2D 3x3 64x64', opt_B(16, 3844, 9, 16, False, False), 269159),
            ('vl=16 MNIST conv1 ReLU', opt_B(16, 676, 9, 16, False, True), 49427)]
    for n, mval, rec in rows:
        print('check %-24s slot rule %7d  recorded %7d  %s' % (n, mval, rec, 'EQUAL' if mval == rec else 'DIFFERENT'))
    # the chunk-boundary test's own split (taps 0..3 | 4..8, 3 pixels, one group, no INIT)
    for vl, mA, mB in ((8, 106, 113), (16, 170, 177)):
        pA = sum(cost(vl, l) for l in (2, 0)) + 3 * sum(cost(vl, l) for l in b_convoys(3, False, False) + b_convoys(1, False, True))
        pB = sum(cost(vl, l) for l in (2, 1)) + 3 * sum(cost(vl, l) for l in b_convoys(3, True, False) + b_convoys(2, False, True))
        print('check convoy_chunk_tb vl=%-2d run A slot rule %d measured %d; run B slot rule %d measured %d' % (vl, pA, mA, pB, mB))

def section5():
    """docs/chunked_taps_design.md section 5 rows, option B, slot rule vs old constants."""
    rows = []
    for S in (8, 16, 32, 64):
        rows.append(('CONV2D 5x5 %dx%d, 32 filters' % (S, S), (S - 4) ** 2, 25, 32, False, False))
    for S in (8, 16, 32, 64):
        rows.append(('CONV2D 5x5 %dx%d, 16 filters' % (S, S), (S - 4) ** 2, 25, 16, False, False))
    for D in (8, 16, 32, 64):
        rows.append(('MATMUL %dx%d as 1x1 conv' % (D, D), D, D, D, False, False))
    rows += [('MLP layer 1: 784 -> 32, bias, ReLU', 1, 784, 32, True, True),
             ('MLP layer 2: 32 -> 16, bias, ReLU', 1, 32, 16, True, True),
             ('MLP layer 3: 16 -> 10, bias', 1, 16, 10, True, False),
             ('cnn_demo layer 1 (26x26 conv), bias, ReLU', 676, 9, 16, True, True),
             ('cnn_demo layer 2 (11x11 conv), bias, ReLU', 121, 144, 32, True, True),
             ('cnn_demo layer 2, 10x10 the pooling reads', 100, 144, 32, True, True),
             ('cnn_demo FC 800 -> 10, bias, ReLU', 1, 800, 10, True, True)]
    print('| Workload | vl=8 old | vl=8 slot rule | vl=16 old | vl=16 slot rule |')
    print('|---|---|---|---|---|')
    for n, P, T, OC, bias, relu in rows:
        print('| %s | {:,} | {:,} | {:,} | {:,} |'.format(old.cycles(8, P, T, OC, bias, relu), opt_B(8, P, T, OC, bias, relu),
              old.cycles(16, P, T, OC, bias, relu), opt_B(16, P, T, OC, bias, relu)) % n)

if __name__ == '__main__':
    check()
    print()
    print('Section 5 of the design note, option B, old constants vs slot rule:')
    section5()
    IISC_L2 = 175674
    T, OC = 144, 32
    print()
    print('Layer 2: 13x13x16 -> 32 filters, 144 taps, bias + ReLU. Ours WITHOUT pooling; IISc layer2 measured = %d (includes the 2x2 max-pool).' % IISC_L2)
    print('| Option | vl | Q | registers (of 31) | P = 121 (11x11 conv) | P = 100 (10x10 the pooling reads) | P=100 / IISc |')
    print('|---|---|---|---|---|---|---|')
    def line(name, vl, Q, rg, a, b):
        print('| %s | %d | %s | %s | {:,} | {:,} | %.3f |'.format(a, b) % (name, vl, Q, rg, b / IISC_L2))
    for vl in (8, 16):
        line('B-old (existing note constants)', vl, '-', '%d taps + acc + 3 X' % (15 if vl == 8 else 9),
             old.cycles(vl, 121, T, OC, bias=True, relu=True), old.cycles(vl, 100, T, OC, bias=True, relu=True))
        line('B (spill), slot rule', vl, '-', str(regs(vl, (15 if vl == 8 else 9) + 1 + 3 + 1)),
             opt_B(vl, 121, T, OC, True, True), opt_B(vl, 100, T, OC, True, True))
        line('B9 (spill, chunk = one input channel), slot rule', vl, '-', str(regs(vl, 9 + 1 + 3 + 1)),
             opt_B(vl, 121, T, OC, True, True, C=9), opt_B(vl, 100, T, OC, True, True, C=9))
    # D: Q accumulators + 2 weight buffers (double-buffered across taps) + Q inputs + 1 zero
    for vl, Q in ((8, 7), (8, 11), (8, 4), (16, 4), (16, 6)):
        n = Q + 2 + Q + 1
        line('D (acc resident, weights streamed, no spill)', vl, Q, '%d%s' % (regs(vl, n), '' if regs(vl, n) <= 31 else ' TOO MANY'),
             opt_D(vl, 121, T, OC, Q), opt_D(vl, 100, T, OC, Q))
    n = 7 + 1 + 7
    line('D, Q=7, one weight buffer, ReLU vs scalar zero (2 untested assumptions)', 16, 7, '%d' % regs(16, n),
         opt_D(16, 121, T, OC, 7), opt_D(16, 100, T, OC, 7))
    for vl, Q in ((8, 6), (8, 4), (16, 6), (16, 4)):
        n = Q + 2 + 1
        line('F (= D + scalar pixel operand; NEW input-buffer datapath)', vl, Q, '%d' % regs(vl, n),
             opt_F(vl, 121, T, OC, Q), opt_F(vl, 100, T, OC, Q))
