#!/usr/bin/env python3
"""NEW (2026-11-17, scalar-operand variant). Prepares one run of Coreless-V's
scalar-operand controller (rtl/vector_unit/hbm_lite_controller_sc.v, top
atee_top_sc.v, testbench testbench/atee_sc_tb.v). No input replication: the
first layer's input is written into the IBUF (host window 0x0030_0000), later
layers' inputs are copied DMEM -> IBUF by the controller (descriptor flag COPY).

Modes:
  conv <size> <work> [--distinct]
      their CONV2D 3x3 benchmark conv<size>_3 (8/16/32/64): data and golden from
      scripts/gen_conv_sizes.py (unchanged, run as a subprocess into <work>);
      one layer, Q32.0, bias 0 (their bias is all zero), no ReLU, no pool.
  cnn <image> <work> <layers 1..3>
      cnn_demo: their weights (compiled ELF) and shipped image, via
      scripts/iisc_bench_prep.py (unchanged, imported); Q8.24, bias, ReLU,
      2x2 max-pool, FC 800 -> 10 padded to 16 output channels, argmax.

Writes into <work>: cnn_params.txt, cnn_load.txt (DMEM: non-zero words only,
DMEM is all-zero at the start of a simulation; IBUF: EVERY word), cnn_ref.json.
"""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

D = 0x100000
IBUF = 0x300000
Q824 = 3 << 4
F_RELU, F_POOL, F_AMAX, F_COPY = 1, 2, 8, 64

def write_run(work, mem, ibuf, desc_base, nl, regions, ref):
    load = sorted((a, v & 0xFFFFFFFF) for a, v in mem.items() if v & 0xFFFFFFFF)
    load += [(IBUF + 4 * i, v & 0xFFFFFFFF) for i, v in enumerate(ibuf)]
    with open(os.path.join(work, 'cnn_load.txt'), 'w', newline='\n') as f:
        for a, v in load:
            f.write('%08x %08x\n' % (a, v))
    with open(os.path.join(work, 'cnn_params.txt'), 'w', newline='\n') as f:
        f.write('%08x\n%d\n%d\n%d\n' % (desc_base, nl, len(load), len(regions)))
        for a, n in regions:
            f.write('%08x %d\n' % (a, n))
    ref['load_words'] = len(load)
    json.dump(ref, open(os.path.join(work, 'cnn_ref.json'), 'w'))
    return len(load)

def put_desc(mem, base, descs):
    for li, dsc in enumerate(descs):
        for i, v in enumerate(dsc):
            mem[base + 64 * li + 4 * i] = v

def hexfile(path):
    def s32(x):
        return x - (1 << 32) if x & 0x80000000 else x
    return [s32(int(l, 16)) for l in open(path) if l.strip()]

def conv(size, work, distinct):
    os.makedirs(work, exist_ok=True)
    args = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'gen_conv_sizes.py'), str(size), work]
    if distinct:
        args.append('--distinct')
    subprocess.run(args, check=True)
    inp = hexfile(os.path.join(work, 'conv_input.hex'))[::8]          # replicated 8x there; one copy here
    wts = hexfile(os.path.join(work, 'conv_weights.hex'))
    gold = hexfile(os.path.join(work, 'conv_golden.hex'))
    tp = os.path.join(work, 'conv_theirs.hex')
    theirs = hexfile(tp) if (not distinct and os.path.exists(tp)) else None
    osz = size - 2
    L = dict(DESC=D, ZB=D + 0x100, W=D + 0x400, PS=D + 0x1000, OUT=D + 0x2000)
    L['END'] = L['OUT'] + 4 * osz * osz * 16
    mem = {}
    for i, v in enumerate(wts):
        mem[L['W'] + 4 * i] = v
    put_desc(mem, L['DESC'], [[size, size, 1, 3, 16, 0, 0, L['W'], L['ZB'], L['PS'], L['OUT'], 0, 0]])
    ref = dict(mode='conv', size=size, distinct=distinct, golden=gold, theirs=theirs, layout=L,
               dmem_bytes_used=L['END'] - D, ibuf_words=len(inp))
    n = write_run(work, mem, inp, L['DESC'], 1, [(L['OUT'], osz * osz * 16)], ref)
    print('conv%d_3%s: %d load words (IBUF %d), %d outputs' % (size, ' distinct' if distinct else '', n, len(inp), len(gold)))

def cnn(k, work, nl):
    import iisc_bench_prep as ib
    os.makedirs(work, exist_ok=True)
    pdir = os.path.join(ib.BENCH, 'cnn_demo')
    sections, syms, words = ib.read_elf(os.path.join(pdir, 'riscv-spike.elf'))
    dimg = ib.c_arrays(os.path.join(ib.REPO, 'Demo', 'Application', 'img.c'))
    labels = ib.c_arrays(os.path.join(ib.REPO, 'Demo', 'Application', 'expected_output.c'))
    img = [(p & 0xFF) << 16 for p in dimg[k * 784:(k + 1) * 784]]
    extra = {'img_words': img, 'label': labels[k], 'image_index': k}
    outs = ib.reference('cnn', words, syms, extra)
    y1, y2 = outs[0][3], outs[1][3]
    ker, _ = ib.arr(words, syms, 'ker'); b1, _ = ib.arr(words, syms, 'bias')
    ker2, _ = ib.arr(words, syms, 'ker2'); b2, _ = ib.arr(words, syms, 'bias2')
    w3, _ = ib.arr(words, syms, 'w3'); b3, _ = ib.arr(words, syms, 'bias3')
    assert len(ker) == 144 and len(b1) == 16 and len(ker2) == 4608 and len(b2) == 32
    assert len(w3) == 8000 and len(b3) == 10
    L = dict(DESC=D, BIAS1=D + 0x100, BIAS2=D + 0x140, BIAS3=D + 0x1C0, CLASS=D + 0x200,
             W1=D + 0x400,       # 9 x 16 words
             W2=D + 0x800,       # 144 x 32
             W3=D + 0x5000,      # 800 x 16 (OC padded 10 -> 16)
             OUT1=D + 0x12000,   # 13x13x16 = 2,704 words (= layer-2 input, copied to the IBUF)
             OUT2=D + 0x15000,   # 5x5x32 = 800 words (= FC input)
             OUT3=D + 0x16000,   # 16 words
             PS=D + 0x16400,     # layer 2: 25 windows x 4 acc x 16 = 1,600 words
             END=D + 0x17D00)
    mem = {}
    for i, v in enumerate(b1): mem[L['BIAS1'] + 4 * i] = v
    for i, v in enumerate(b2): mem[L['BIAS2'] + 4 * i] = v
    for i, v in enumerate(b3): mem[L['BIAS3'] + 4 * i] = v
    for i, v in enumerate(ker): mem[L['W1'] + 4 * i] = v
    for i, v in enumerate(ker2): mem[L['W2'] + 4 * i] = v
    for kk in range(800):
        for n in range(10):
            mem[L['W3'] + 4 * (kk * 16 + n)] = w3[kk * 10 + n]
    put_desc(mem, L['DESC'], [
        [28, 28, 1, 3, 16, F_RELU | F_POOL | Q824, 0, L['W1'], L['BIAS1'], L['PS'], L['OUT1'], 0, 0],
        [13, 13, 16, 3, 32, F_RELU | F_POOL | F_COPY | Q824, L['OUT1'], L['W2'], L['BIAS2'], L['PS'], L['OUT2'], 0, 0],
        [1, 1, 800, 1, 16, F_RELU | F_AMAX | F_COPY | Q824, L['OUT2'], L['W3'], L['BIAS3'], L['PS'], L['OUT3'], 10, L['CLASS']],
    ])
    regions = [(L['OUT1'], 2704)]
    if nl >= 2: regions.append((L['OUT2'], 800))
    if nl >= 3: regions += [(L['OUT3'], 16), (L['CLASS'], 1)]
    ref = dict(mode='cnn', image=k, label=labels[k], layers=nl, y1=y1, y2=y2,
               fc=extra['fc_after_relu'], argmax=extra['argmax'], layout=L,
               dmem_bytes_used=L['END'] - D, ibuf_words=784)
    n = write_run(work, mem, img, L['DESC'], nl, regions, ref)
    print('image %d label %d, layers %d, %d load words (IBUF 784), reference argmax %d'
          % (k, labels[k], nl, n, extra['argmax']))

def main():
    if sys.argv[1] == 'conv':
        conv(int(sys.argv[2]), sys.argv[3], '--distinct' in sys.argv[4:])
    else:
        cnn(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]))

if __name__ == '__main__':
    main()
