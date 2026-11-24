#!/usr/bin/env python3
"""NEW (2026-11-19). Paper benchmark rows on Coreless-V's scalar-operand
controller (hbm_lite_controller_sc.v, unchanged): CONV2D 5x5 (their
conv/conv32_5) and MATMUL 16 / 32 / 64 (their matmul/matmul<D>) as a 1x1
convolution with chunked taps. Inputs and the Python reference come from the
program's ELF via scripts/iisc_bench_prep.py (unchanged, imported); their
expected_output[] is used as a second reference where present.

MATMUL as a 1x1 convolution: C = A * B (D x D, Q32.0). Output pixel i = row i
of A, input channels k = 0..D-1 (IBUF index i*D + k = A row-major),
weight[tap = k][oc = j] = B[k][j] (B row-major), output (i*D + j) = C
row-major. H = 1, W = D, IC = D, K = 1, OC = D, no bias, no ReLU, no pool.

Modes:
  prep <prog> <work>     prog = conv32_5 | matmul8 | matmul16 | matmul32 | matmul64
  model                  slot-rule model (scripts/sc_schedule_model.py) per row
  fit                    which paper rows fit the controller's limits
Writes cnn_params.txt, cnn_load.txt, cnn_ref.json as scripts/atee_sc_prep.py
(the same testbench, testbench/atee_sc_tb.v).
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from atee_sc_prep import write_run, put_desc, D

IBUF_WORDS = 4096

def shape(prog):
    if prog == 'conv32_5':
        return dict(H=32, W=32, IC=1, K=5, OC=32)
    n = int(prog[len('matmul'):])
    return dict(H=1, W=n, IC=n, K=1, OC=n)

def limits(s):
    oh, ow = s['H'] - s['K'] + 1, s['W'] - s['K'] + 1
    why = []
    if s['OC'] % 16:
        why.append('OC = %d is not a multiple of 16' % s['OC'])
    if s['H'] * s['W'] * s['IC'] > IBUF_WORDS:
        why.append('input H*W*IC = %d > %d words (IBUF)' % (s['H'] * s['W'] * s['IC'], IBUF_WORDS))
    if (oh * ow) % 4 and oh * ow != 1:
        why.append('output pixels %d not a multiple of 4' % (oh * ow))
    return why

def distinct_data(prog, s):
    """--distinct: their data cannot detect every placement error (conv32_5:
    all 32 filters identical; matmul: B has 10 distinct columns). Seeded
    mixed-sign values, Q32.0; reference by plain nested loops."""
    import random
    from iisc_bench_prep import s32
    rnd = random.Random(20261119 + sum(map(ord, prog)))
    if prog == 'conv32_5':
        S, F = 32, 32
        img = [rnd.randint(-100, 100) for _ in range(S * S)]
        ker = [rnd.randint(-50, 50) for _ in range(25 * F)]
        O = S - 4
        gold = [s32(sum(img[(oh + r) * S + ow + c] * ker[(r * 5 + c) * F + f] for r in range(5) for c in range(5)))
                for oh in range(O) for ow in range(O) for f in range(F)]
        return img, ker, gold
    n = s['W']
    A = [rnd.randint(-100, 100) for _ in range(n * n)]
    B = [rnd.randint(-100, 100) for _ in range(n * n)]
    gold = [s32(sum(A[i * n + k] * B[k * n + j] for k in range(n))) for i in range(n) for j in range(n)]
    return A, B, gold

def prep(prog, work, distinct=False):
    import iisc_bench_prep as ib
    os.makedirs(work, exist_ok=True)
    rel, kind, funcs = ib.PROGRAMS[prog]
    pdir = os.path.join(ib.BENCH, *rel.split('/'))
    sections, syms, words = ib.read_elf(os.path.join(pdir, 'riscv-spike.elf'))
    outs = ib.reference(kind, words, syms, {})
    golden, theirs = outs[0][3], outs[0][4]
    s = shape(prog)
    why = limits(s)
    if why:
        print('%s does NOT fit: %s' % (prog, '; '.join(why)))
        sys.exit(2)
    if distinct:
        ibuf, wts, golden = distinct_data(prog, s)
        theirs = None
    elif kind == 'conv5':
        img, _ = ib.arr(words, syms, 'img'); ker, _ = ib.arr(words, syms, 'ker')
        assert len(img) == 1024 and len(ker) == 25 * 32
        ibuf, wts = img, ker                       # ker[(r*5+c)*F + f] = weight[tap][oc]
    else:
        A, _ = ib.arr(words, syms, 'a_mat'); B, _ = ib.arr(words, syms, 'b_mat')
        n = s['W']
        assert len(A) == n * n and len(B) == n * n
        ibuf, wts = A, B                           # B[k*n + j] = weight[tap = k][oc = j]
    L = dict(DESC=D, ZB=D + 0x100, W=D + 0x400, PS=D + 0x8000, OUT=D + 0x18000)
    oh, ow = s['H'] - s['K'] + 1, s['W'] - s['K'] + 1
    nout = oh * ow * s['OC']
    assert nout == len(golden)
    nwin = (oh * ow) // 4
    assert L['W'] + 4 * len(wts) <= L['PS'] and L['PS'] + nwin * 4 * 64 <= L['OUT']
    L['END'] = L['OUT'] + 4 * nout
    mem = {}
    for i, v in enumerate(wts):
        mem[L['W'] + 4 * i] = v
    put_desc(mem, L['DESC'], [[s['H'], s['W'], s['IC'], s['K'], s['OC'], 0, 0, L['W'], L['ZB'], L['PS'], L['OUT'], 0, 0]])
    ref = dict(mode='paper', program=prog, distinct=distinct, shape=s, golden=golden, theirs=theirs, layout=L,
               dmem_bytes_used=L['END'] - D, ibuf_words=len(ibuf))
    nl = write_run(work, mem, ibuf, L['DESC'], 1, [(L['OUT'], nout)], ref)
    ex = sum(1 for a, b in zip(golden, theirs) if a == b) if theirs else None
    print('%s%s: shape %s, %d load words (IBUF %d), %d outputs; Python reference vs THEIR expected_output: %s'
          % (prog, ' (distinct data)' if distinct else '', s, nl, len(ibuf), nout, ('%d / %d' % (ex, nout)) if theirs else 'n/a'))

def model():
    from sc_schedule_model import model as m
    for prog in ('conv32_5', 'matmul16', 'matmul32', 'matmul64'):
        s = shape(prog)
        o = m(s['H'], s['W'], s['IC'], s['K'], s['OC'], False, False)
        print('  %-9s convoy cycles %8d  %s' % (prog, sum(o.values()), {k: v for k, v in o.items() if v}))

def fit():
    rows = [('CONV2D 3x3 8/16/32/64 (conv<S>_3)', [dict(H=S, W=S, IC=1, K=3, OC=16) for S in (8, 16, 32, 64)]),
            ('CONV2D 5x5 32x32 (conv32_5)', [shape('conv32_5')]),
            ('MATMUL 8 (matmul8) as 1x1 conv', [shape('matmul8')]),
            ('MATMUL 16/32/64 as 1x1 conv', [shape('matmul%d' % n) for n in (16, 32, 64)])]
    for name, ss in rows:
        print('  %-36s %s' % (name, ' | '.join(('fits' if not limits(s) else 'NO: ' + '; '.join(limits(s))) for s in ss)))

if __name__ == '__main__':
    if sys.argv[1] == 'prep':
        prep(sys.argv[2], sys.argv[3], '--distinct' in sys.argv[4:])
    elif sys.argv[1] == 'model':
        model()
    else:
        fit()
