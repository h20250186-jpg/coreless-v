#!/usr/bin/env python3
"""NEW (2026-11-16). Check A.2: minimal test of cnn_demo's final-layer
instruction pattern on THEIR design (FPGA_WRAPPER, 2019.1 xsim, the cnn_img0
snapshot of scripts/run_iisc_bench.ps1 = iisc_tb_bench.v + the assumed stand-ins,
reused unchanged).

Program: their compiled cnn_demo image, unchanged, EXCEPT the first words of
main (0x113c), which are replaced by a hand-assembled call of their own,
unmodified layer3 (0xdec):
    a1 = INP (4 words), a2 = W (4 rows of vl words), a3 = 4 (-> ONE pass of
    OUTER_LOOP = one 8-instruction convoy: 4 x vle32 in slots 0-3, 4 x vmacc
    into v20 in slots 4-7), a4 = BIAS, a5 = vl, a0 = 0; jal layer3; j .
Then the bias convoy of layer3 runs as compiled (vle32 v4 | vadd v28 | vadd.vv
v20 | vand v20 (ReLU) | vmax v10 | vmul x3, slots 0..7).
Data (Q8.24, their reset default): INP = 1.0 (1<<24) x 4, so each vmacc adds
W[r][n] exactly; W[r][n] = (n+1) << (6 r) (each row's contribution readable in
base 64). Data set A: BIAS = 0. Data set B: BIAS[n] = -(sum_r W[r][n]) - 7, so
the correct output is ReLU(-7) = 0 for every n.

PREDICTION (written before the runs), from vrf_bank.vhd line 86: bank i's
register write is gated by ('0'&wr_count) <= vl with wr_count = MEM_WB_counts(i),
the counter of SLOT i, not of the writing slot. When slot j writes element e
(bank i = e mod 8), slot i's counter is e + j - i = 8*(e div 8) + j. So slot j's
writes of the elements in register group g = e div 8 land only if 8g + j <= vl.
At vl = 10 the group-1 elements (8, 9) are written only by slots 0..2.

Usage: python iisc_vlhazard.py prep <work> <vl> <A|B>
       python iisc_vlhazard.py check <work>
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iisc_bench_prep as p

MAIN, LAYER3 = 0x113c, 0xdec
INP, W, BIAS = 0x110000, 0x110100, 0x110200

def lui(rd, imm): return ((imm >> 12) & 0xFFFFF) << 12 | rd << 7 | 0x37
def addi(rd, rs, imm): return (imm & 0xFFF) << 20 | rs << 15 | rd << 7 | 0x13
def li(rd, v):
    if -2048 <= v < 2048:
        return [addi(rd, 0, v)]
    hi = (v + 0x800) >> 12
    return [lui(rd, hi << 12), addi(rd, rd, v - (hi << 12))]
def jal(rd, off):
    return (((off >> 20) & 1) << 31 | ((off >> 1) & 0x3FF) << 21 | ((off >> 11) & 1) << 20
            | ((off >> 12) & 0xFF) << 12 | rd << 7 | 0x6F)

def data(vl, ds):
    s = [1 << 24] * 4
    w = [[(n + 1) << (6 * r) for n in range(vl)] for r in range(4)]
    if ds == 'A':
        b = [0] * vl
    else:
        b = [-(sum(w[r][n] for r in range(4))) - 7 for n in range(vl)]
    return s, w, b

def predict(vl, s, w, b):
    """Final v20 elements 0..vl-1 under the slot-i-counter write-gate rule."""
    out = []
    for e in range(vl):
        g = e // 8
        lands = lambda j: 8 * g + j <= vl
        v20 = 0                                   # cleared at vl=32 (8g+j <= 32 always)
        acc = 0
        for j in (4, 5, 6, 7):                    # vmacc slots, chained by forwarding
            acc = p.s32(acc + p.q824(s[j - 4], w[j - 4][e]))
            if lands(j): v20 = acc
        # bias convoy: slot 2 v20 = bias + v20 ; slot 3 v20 = max(v20, 0)
        t2 = p.s32(b[e] + v20)
        t3 = max(t2, 0)
        out.append(t3 if lands(3) else (t2 if lands(2) else v20))
    return out

def correct(vl, s, w, b):
    return [max(p.s32(b[e] + sum(p.q824(s[r], w[r][e]) for r in range(4))), 0) for e in range(vl)]

def prep(work, vl, ds):
    os.makedirs(work, exist_ok=True)
    pdir = os.path.join(p.BENCH, 'cnn_demo')
    sections, syms, words = p.read_elf(os.path.join(pdir, 'riscv-spike.elf'))
    assert syms['main'][0] == MAIN and syms['layer3'][0] == LAYER3
    base = p.read_coe(os.path.join(pdir, 'Scripts', 'base.hex'))
    img = [0] * 262144
    img[:len(base)] = base
    dmem = [[0] * 16384 for _ in range(8)]
    for a, x in words.items():
        if a < p.VMEM:
            img[1024 + a // 4] = x
        elif a < p.VMEM + 8 * 16384 * 4:
            o = (a - p.VMEM) // 4
            dmem[o % 8][o // 8] = x
    s, w, b = data(vl, ds)
    def put(a, v):
        o = (a - p.VMEM) // 4
        dmem[o % 8][o // 8] = v & p.MASK
    for r in range(4):
        put(INP + 4 * r, s[r])
        for n in range(vl):
            put(W + 4 * (r * vl + n), w[r][n])
    for n in range(vl):
        put(BIAS + 4 * n, b[n])
    code = li(11, INP) + li(12, W) + li(13, 4) + li(14, BIAS) + li(15, vl) + li(10, 0)
    jal_pc = MAIN + 4 * len(code)
    code += [jal(1, LAYER3 - jal_pc), jal(0, 0)]
    old = [img[1024 + MAIN // 4 + i] for i in range(len(code))]
    for i, x in enumerate(code):
        img[1024 + MAIN // 4 + i] = x
    with open(os.path.join(work, 'mainMem.mif'), 'w', newline='\n') as f:
        for x in img: f.write(format(x, '032b') + '\n')
    for k in range(8):
        with open(os.path.join(work, 'DMEM_%d.mif' % k), 'w', newline='\n') as f:
            for x in dmem[k]: f.write(format(x, '032b') + '\n')
    with open(os.path.join(work, 'preload.txt'), 'w', newline='\n') as f:
        f.write('0\n')
    with open(os.path.join(work, 'bench_params.txt'), 'w', newline='\n') as f:
        f.write('1\n%x %x\n0\n0\n0\n0 0\n' % (LAYER3, jal_pc + 4))
    pr, co = predict(vl, s, w, b), correct(vl, s, w, b)
    json.dump(dict(vl=vl, ds=ds, inp=s, w=w, bias=b, predicted=pr, correct=co, jal_pc=jal_pc,
                   patch=['%08x' % x for x in code], replaced=['%08x' % x for x in old]),
              open(os.path.join(work, 'hazard.json'), 'w'))
    print('vl %d data set %s: main patched with %d words at 0x%x (jal layer3 at 0x%x, return 0x%x)'
          % (vl, ds, len(code), MAIN, jal_pc, jal_pc + 4))
    print('  patch   :', ' '.join('%08x' % x for x in code))
    print('  predicted v20[0..%d]:' % (vl - 1), pr)
    print('  correct  v20[0..%d]:' % (vl - 1), co)

def check(work):
    h = json.load(open(os.path.join(work, 'hazard.json')))
    vl = h['vl']
    regs = [[int(v, 16) for v in open(os.path.join(work, 'vrf_%d.txt' % k)).read().split()][::-1] for k in range(8)]
    hw = [p.s32(regs[e % 8][20 + e // 8]) for e in range(vl)]
    W_ = [l.split() for l in open(os.path.join(work, 'dump.txt')) if l.startswith('W ')][0]
    okp = sum(1 for e in range(vl) if hw[e] == h['predicted'][e])
    okc = sum(1 for e in range(vl) if hw[e] == h['correct'][e])
    print('CHECK vl %d data set %s: layer3 entry -> return %d cycles, x10 at return %s'
          % (vl, h['ds'], int(W_[3]) - int(W_[2]), W_[4]))
    print('  hardware  v20[0..%d]: %s' % (vl - 1, hw))
    print('  correct   v20[0..%d]: %s' % (vl - 1, h['correct']))
    print('  predicted v20[0..%d]: %s' % (vl - 1, h['predicted']))
    print('  hardware == correct: %d / %d (wrong elements: %s); hardware == prediction: %d / %d'
          % (okc, vl, [e for e in range(vl) if hw[e] != h['correct'][e]], okp, vl))

if __name__ == '__main__':
    if sys.argv[1] == 'prep':
        prep(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    else:
        check(sys.argv[2])
