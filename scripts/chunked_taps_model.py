#!/usr/bin/env python3
"""NEW (2026-11-15). Cycle and memory model for a CHUNKED-TAPS schedule on
Coreless-V (design note docs/chunked_taps_design.md). PROJECTION ONLY: no RTL of
this schedule exists. Every constant below is a measured cycle count of the
existing vl=8 / vl=16 controllers (RESULTS.md "CONV2D 3x3 at image sizes",
"vl=16 controller"); the model reproduces the recorded 9-tap counts exactly
(printed by --check).

vl=8   compute convoy with n taps (n input loads + n MACs): 2n + 9 cycles
       +1 if it carries the store (last convoy of a chunk)
       +1 if it carries a partial-sum / bias load (first convoy of a chunk > 0,
          or of chunk 0 when a bias is loaded)
       weight-preload convoy with n loads: n + 9 cycles
vl=16  compute convoy: 23 cycles (all 8 slots issued), +1 for the store convoy;
       the partial-sum load uses the free slot 0 of the chunk's first convoy
       (chunks are built with >= 2 convoys so the store never meets it)
       weight-preload convoy (3 vl=16 loads): 20 cycles
both   per layer: 3 init + 16 output-size divider = 19 cycles
Chunk capacity (taps whose weights sit in the VRF at once): vl=8 15 of 16
(multiple of 3), vl=16 9 (the ReLU-path register limit; 11 without ReLU).
"""
import math, sys

INIT = 19
MEM_WORDS = 512 * 1024 // 4

def chunks(T, C):
    k = math.ceil(T / C)
    base = [C] * (k - 1) + [T - C * (k - 1)]
    return base

def convoys(Tc):
    return [3] * (Tc // 3) + ([Tc % 3] if Tc % 3 else [])

def cycles(vl, P, T, OC, bias=False, relu=False):
    C = 15 if vl == 8 else 9
    g = math.ceil(OC / vl)                     # output-channel groups (OC padded)
    tot = INIT
    for _ in range(g):
        for ci, Tc in enumerate(chunks(T, C)):
            cv = convoys(Tc)
            if vl == 8:
                pre = sum(n + 9 for n in cv)
                px = sum(2 * n + 9 for n in cv) + 1               # + store
                if ci > 0 or bias: px += 1                        # psum / bias load
                if relu and ci == len(chunks(T, C)) - 1: px += 3  # fused ReLU: 3,619 - 3,403 = 72 x 3 (measured)
            else:
                pre = 20 * math.ceil(Tc / 3)
                px = 23 * len(cv) + 1
                if len(cv) == 1 and (ci > 0 or bias): px += 23    # single-convoy chunk: extra convoy
                if relu and ci == len(chunks(T, C)) - 1: px += 3  # fused ReLU (73 vs 70 measured)
            tot += pre + P * px
    return tot

def mem(vl, in_vals, T, OC, P):
    """words: input values replicated vl times, weights T x OCpad, outputs P x OCpad"""
    ocp = math.ceil(OC / vl) * vl
    w = in_vals * vl + T * ocp + P * ocp
    return w, w <= MEM_WORDS

def check():
    print('check vl=8  conv8_3 :', cycles(8, 36, 9, 16), '(recorded 3,403)')
    print('check vl=8  64x64   :', cycles(8, 3844, 9, 16), '(recorded 353,739)')
    print('check vl=16 conv8_3 :', cycles(16, 36, 9, 16), '(recorded 2,599)')
    print('check vl=16 64x64   :', cycles(16, 3844, 9, 16), '(recorded 269,159)')
    print('check vl=16 MNIST ReLU:', cycles(16, 676, 9, 16, relu=True), '(recorded 49,427)')
    print('check vl=8  MNIST ReLU:', cycles(8, 676, 9, 16, relu=True), '(recorded 66,339)')

def row(name, P, T, OC, in_vals, bias=False, relu=False):
    out = [name, P, T, OC]
    for vl in (8, 16):
        c = cycles(vl, P, T, OC, bias, relu)
        w, ok = mem(vl, in_vals, T, OC, P)
        out += [c, w, 'fits' if ok else 'DOES NOT FIT']
    return out

def table():
    rows = []
    for S in (8, 16, 32, 64):
        O = S - 4
        rows.append(row('CONV2D 5x5 %dx%d, 1 in-ch, 32 filters (as conv32_5)' % (S, S), O * O, 25, 32, S * S))
    for S in (8, 16, 32, 64):
        O = S - 4
        rows.append(row('CONV2D 5x5 %dx%d, 1 in-ch, 16 filters' % (S, S), O * O, 25, 16, S * S))
    for D in (8, 16, 32, 64):
        rows.append(row('MATMUL %dx%d as 1x1 conv (P=%d, taps=%d, OC=%d)' % (D, D, D, D, D), D, D, D, D * D))
    rows.append(row('MLP layer 1: 784 -> 32, bias, ReLU', 1, 784, 32, 784, True, True))
    rows.append(row('MLP layer 2: 32 -> 16, bias, ReLU', 1, 32, 16, 32, True, True))
    rows.append(row('MLP layer 3: 16 -> 10 (OC padded), bias', 1, 16, 10, 16, True, False))
    rows.append(row('cnn_demo layer 1: 28x28, 3x3, 16 filters, bias, ReLU (26x26 conv)', 676, 9, 16, 784, True, True))
    rows.append(row('cnn_demo layer 2: 13x13x16, 3x3x16 = 144 taps, 32 filters, bias, ReLU (11x11 conv)', 121, 144, 32, 13 * 13 * 16, True, True))
    rows.append(row('cnn_demo layer 2, only the 10x10 conv outputs the pooling uses', 100, 144, 32, 13 * 13 * 16, True, True))
    rows.append(row('cnn_demo layer 3: FC 800 -> 10 (OC padded), bias, ReLU', 1, 800, 10, 800, True, True))
    print('| Workload | P | taps | OC | vl=8 cycles | vl=8 words | vl=8 fit | vl=16 cycles | vl=16 words | vl=16 fit |')
    print('|---|---|---|---|---|---|---|---|---|---|')
    for r in rows:
        print('| ' + ' | '.join('{:,}'.format(x) if isinstance(x, int) else str(x) for x in r) + ' |')

if __name__ == '__main__':
    check()
    table()
