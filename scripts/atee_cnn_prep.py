#!/usr/bin/env python3
"""NEW (2026-11-17, task G). Prepares one cnn_demo image for Coreless-V's CNN
controller (rtl/vector_unit/hbm_lite_controller_cnn.v, testbench
testbench/atee_cnn_tb.v).

Inputs (read-only): their compiled cnn_demo ELF (weights ker, bias, ker2,
bias2, w3, bias3), the 100 shipped images (Demo/Application/img.c, labels in
expected_output.c), via scripts/iisc_bench_prep.py (unchanged, imported).
Pixel words = byte << 16, as their ISR5_uart stores them.

Writes into <work>:
  cnn_params.txt  descriptor base, number of layers, number of load words,
                  dump regions (address, words)
  cnn_load.txt    "addr data" (hex) for every NON-ZERO word to load (DMEM is
                  all-zero at the start of each simulation)
  cnn_ref.json    exact Python reference (iisc_bench_prep.reference: y1, y2,
                  FC after ReLU, argmax), label, DMEM layout
Usage: python atee_cnn_prep.py <image index> <work dir> <number of layers 1..3>
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iisc_bench_prep as ib

D = 0x100000
LAYOUT = dict(
    DESC=D + 0x000000, BIAS1=D + 0x000100, BIAS2=D + 0x000140, BIAS3=D + 0x0001C0,
    CLASS=D + 0x000200,
    W1=D + 0x000400,   # 9 taps x 16 OC        =    144 words
    W2=D + 0x000800,   # 144 taps x 32 OC      =  4,608 words
    W3=D + 0x005000,   # 800 taps x 16 OC pad  = 12,800 words
    IN1=D + 0x012000,  # 28x28 x 16 copies     = 12,544 words
    OUT1=D + 0x01E400, # 13x13x16 x 16 copies  = 43,264 words (= layer-2 input)
    OUT2=D + 0x048800, # 5x5x32 x 16 copies    = 12,800 words (= FC input)
    OUT3=D + 0x055000, # 16 words
    PS1=D + 0x055400,  # unused (layer 1 is one chunk)
    PS2=D + 0x056000,  # 100 pixels x 32 OC    =  3,200 words
    PS3=D + 0x05A000,  # 1 pixel x 16 OC
    END=D + 0x05A040,
)
Q824 = 3 << 4
F_RELU, F_POOL, F_REP, F_AMAX = 1, 2, 4, 8

def main():
    k, work, nl = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
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
    assert len(w3) == 8000 and len(b3) == 10, (len(w3), len(b3))

    mem = {}
    def put(a, v):
        mem[a] = v & 0xFFFFFFFF
    L = LAYOUT
    for i, v in enumerate(b1): put(L['BIAS1'] + 4 * i, v)
    for i, v in enumerate(b2): put(L['BIAS2'] + 4 * i, v)
    for i, v in enumerate(b3): put(L['BIAS3'] + 4 * i, v)          # 10..15 stay 0
    for i, v in enumerate(ker): put(L['W1'] + 4 * i, v)              # (r*3+c)*16 + f
    for i, v in enumerate(ker2): put(L['W2'] + 4 * i, v)             # ((r*3+c)*16+k)*32 + f
    for kk in range(800):                                            # w3[k*10+n] -> k*16+n
        for n in range(10):
            put(L['W3'] + 4 * (kk * 16 + n), w3[kk * 10 + n])
    for p, v in enumerate(img):                                      # 16 copies per pixel
        for r in range(16):
            put(L['IN1'] + 4 * (p * 16 + r), v)
    desc = [
        [28, 28, 1, 3, 16, F_RELU | F_POOL | F_REP | Q824, L['IN1'], L['W1'], L['BIAS1'], L['PS1'], L['OUT1'], 0, 0],
        [13, 13, 16, 3, 32, F_RELU | F_POOL | F_REP | Q824, L['OUT1'], L['W2'], L['BIAS2'], L['PS2'], L['OUT2'], 0, 0],
        [1, 1, 800, 1, 16, F_RELU | F_AMAX | Q824, L['OUT2'], L['W3'], L['BIAS3'], L['PS3'], L['OUT3'], 10, L['CLASS']],
    ]
    for li, dsc in enumerate(desc):
        for i, v in enumerate(dsc):
            put(L['DESC'] + 64 * li + 4 * i, v)
    load = sorted((a, v) for a, v in mem.items() if v != 0)
    regions = [(L['OUT1'], 13 * 13 * 16 * 16)]
    if nl >= 2: regions.append((L['OUT2'], 5 * 5 * 32 * 16))
    if nl >= 3: regions += [(L['OUT3'], 16), (L['CLASS'], 1)]
    with open(os.path.join(work, 'cnn_load.txt'), 'w', newline='\n') as f:
        for a, v in load:
            f.write('%08x %08x\n' % (a, v))
    with open(os.path.join(work, 'cnn_params.txt'), 'w', newline='\n') as f:
        f.write('%08x\n%d\n%d\n%d\n' % (L['DESC'], nl, len(load), len(regions)))
        for a, n in regions:
            f.write('%08x %d\n' % (a, n))
    json.dump(dict(image=k, label=labels[k], layers=nl, y1=y1, y2=y2,
                   fc=extra['fc_after_relu'], argmax=extra['argmax'],
                   layout={a: b for a, b in L.items()}, load_words=len(load),
                   dmem_bytes_used=L['END'] - D),
              open(os.path.join(work, 'cnn_ref.json'), 'w'))
    print('image %d label %d, layers %d, %d non-zero load words, reference argmax %d'
          % (k, labels[k], nl, len(load), extra['argmax']))

if __name__ == '__main__':
    main()
