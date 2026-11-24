#!/usr/bin/env python3
"""NEW (2026-11-15). Prepares one I2SRV32-V benchmark program for simulation of
THEIR design (FPGA_WRAPPER) with external/iisc_sim/iisc_tb_bench.v.

Read-only on their repo. For the chosen program it
  1. parses the program's own riscv-spike.elf (sections, symbols),
  2. builds the memory images from the ELF exactly as their Scripts/hex.py
     lays them out (mainMem word 1024 + addr/4, page-table words 0..1023 from
     their Scripts/base.hex; DMEM bank b row r = addr 0x100000 + 4*(8r+b)),
  3. compares those images word by word with the SHIPPED xmem.coe /
     dmem_bank*.coe (Outputfiles, else Scripts) and reports every difference,
  4. finds, in riscv-spike.dump, each kernel call in main (entry = function
     symbol, return = jal address + 4) and the final self-loop after main,
  5. computes a Python reference from the program's source semantics
     (assembly in app/asm, inputs = the ELF's data symbols),
  6. writes bench_params.txt / preload.txt (testbench), mainMem.mif and
     DMEM_0..7.mif, and bench.json (for scripts/iisc_bench_check.py).

Usage: python iisc_bench_prep.py <program> <work dir> [image index for cnn]
Programs: saxpy8|16|32|64, perc8|16|32|64 (perceptron/mlpN_32),
          mlp256_8, mlp256_16, matmul8|16|32|64, conv8_3, conv32_5, cnn
"""
import json, os, re, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.join(ROOT, 'external', 'I2SRV32-V-v1-master')
BENCH = os.path.join(REPO, 'benchmarks', 'benchmarks')
VMEM = 0x100000
MASK = 0xFFFFFFFF

def s32(x):
    x &= MASK
    return x - (1 << 32) if x & 0x80000000 else x

PROGRAMS = {}
for n in (8, 16, 32, 64):
    PROGRAMS['saxpy%d' % n] = ('saxpy/saxpy%d' % n, 'saxpy', ['saxpy'])
    PROGRAMS['perc%d' % n] = ('perceptron/mlp%d_32' % n, 'mlp32', ['mlp32'])
    PROGRAMS['matmul%d' % n] = ('matmul/matmul%d' % n, 'matmul',
                                [{8: 'matmul', 16: 'matmul', 32: 'matmul32', 64: 'matmul64'}[n]])
PROGRAMS['mlp256_8'] = ('perceptron/mlp256_8', 'perceptron', ['perceptron'])
PROGRAMS['mlp256_16'] = ('perceptron/mlp256_16', 'perceptron', ['perceptron'])
PROGRAMS['conv8_3'] = ('conv/conv8_3', 'conv3', ['conv2d'])
PROGRAMS['conv32_5'] = ('conv/conv32_5', 'conv5', ['conv2d_5'])
PROGRAMS['cnn'] = ('cnn_demo', 'cnn', ['conv2d', 'layer2', 'layer3'])

# ---------------------------------------------------------------- ELF
def read_elf(path):
    d = open(path, 'rb').read()
    shoff, = struct.unpack_from('<I', d, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x2E)
    secs = []
    for i in range(shnum):
        secs.append(struct.unpack_from('<10I', d, shoff + i * shentsize))
    shstr = secs[shstrndx]
    def nm(tab, off):
        s = tab[4] + off
        return d[s:d.index(b'\0', s)].decode()
    sections = []
    for s in secs:
        sections.append(dict(name=nm(shstr, s[0]), type=s[1], flags=s[2], addr=s[3], off=s[4], size=s[5], link=s[6]))
    syms = {}
    for s in sections:
        if s['type'] == 2:  # SYMTAB
            strtab = secs[s['link']]
            for k in range(s['size'] // 16):
                st_name, val, size, info, other, shndx = struct.unpack_from('<IIIBBH', d, s['off'] + 16 * k)
                if st_name:
                    syms[nm(strtab, st_name)] = (val, size)
    words = {}
    for s in sections:
        if (s['flags'] & 2) and s['type'] != 8 and s['size']:   # ALLOC, not NOBITS
            blob = d[s['off']:s['off'] + s['size']]
            blob += b'\0' * (-len(blob) % 4)
            for k in range(0, len(blob), 4):
                words[s['addr'] + k] = struct.unpack_from('<I', blob, k)[0]
    return sections, syms, words

def read_coe(path):
    if not os.path.exists(path):
        return None
    body = open(path).read().split('=', 2)[2]
    return [int(w, 16) for w in body.replace(';', ',').split(',') if w.strip()]

def first_existing(*paths):
    for p in paths:
        if os.path.exists(p):
            return p
    return None

# ---------------------------------------------------------------- dump
def parse_dump(path, funcs):
    lines = open(path, errors='replace').read().splitlines()
    cur = None
    calls = {}
    end_pc = None
    after_main_call = False
    for ln in lines:
        m = re.match(r'^([0-9a-f]{8}) <([^>]+)>:', ln)
        if m:
            cur = m.group(2)
            continue
        m = re.match(r'^\s+([0-9a-f]+):\s+[0-9a-f]{8}\s+(\S+)\s+(.*)$', ln)
        if not m:
            continue
        a, op, args = int(m.group(1), 16), m.group(2), m.group(3)
        if cur == '_mstart':
            if after_main_call and end_pc is None:
                end_pc = a
            if op == 'jal' and '<main>' in args:
                after_main_call = True
        if cur == 'main' and op == 'jal':
            t = re.search(r'<(\w+)>', args)
            if t and t.group(1) in funcs and t.group(1) not in calls:
                calls[t.group(1)] = a
    return calls, end_pc

# ---------------------------------------------------------------- C arrays (Demo images)
def c_arrays(path):
    txt = open(path).read()
    return [int(v, 0) for v in re.findall(r'0x[0-9a-fA-F]+|\b\d+\b', txt.split('{', 1)[1])]

# ---------------------------------------------------------------- references
def arr(words, syms, name, n=None):
    a, size = syms[name]
    n = size // 4 if n is None else n
    return [s32(words.get(a + 4 * i, 0)) for i in range(n)], a

def q824(a, b):
    return s32((a * b) >> 24)

def relu(x):
    return x if x > 0 else 0

def reference(kind, words, syms, extra):
    outs = []   # (label, kind 'mem'|'vrf'|'x10', addr/reg, ref list, theirs list or None)
    th = None
    if 'expected_output' in syms:
        th, _ = arr(words, syms, 'expected_output')
    if kind == 'saxpy':
        x, _ = arr(words, syms, 'x_vec'); y, ya = arr(words, syms, 'y_vec')
        ref = [s32(64 * x[i] + y[i]) for i in range(len(x))]
        outs.append(('y_vec', 'mem', ya, ref, th))
    elif kind == 'mlp32':
        inp, _ = arr(words, syms, 'inp'); w, _ = arr(words, syms, 'weights')
        ref = [s32(sum(inp[k] * w[k * 32 + n] for k in range(len(inp)))) for n in range(32)]
        outs.append(('v20 (never stored)', 'vrf', 20, ref, th))
    elif kind == 'perceptron':
        inp, _ = arr(words, syms, 'inp'); w, _ = arr(words, syms, 'weights'); b, _ = arr(words, syms, 'bias')
        N = len(b); _, ya = arr(words, syms, 'Y', N)
        acc = [s32(sum(inp[k] * w[k * N + n] for k in range(len(inp)))) for n in range(N)]
        ref = [relu(s32(acc[n] + b[n])) for n in range(N)]
        outs.append(('Y', 'mem', ya, ref, th))
        extra['pre_relu'] = [s32(acc[n] + b[n]) for n in range(N)]
    elif kind == 'matmul':
        A, _ = arr(words, syms, 'a_mat'); B, _ = arr(words, syms, 'b_mat')
        D = int(round(len(A) ** 0.5)); _, ya = arr(words, syms, 'y_mat', D * D)
        ref = [s32(sum(A[i * D + k] * B[k * D + j] for k in range(D))) for i in range(D) for j in range(D)]
        outs.append(('y_mat', 'mem', ya, ref, th))
    elif kind == 'conv3':
        img, _ = arr(words, syms, 'img'); ker, _ = arr(words, syms, 'ker')
        S = int(round(len(img) ** 0.5)); O = S - 2; F = len(ker) // 9
        _, ya = arr(words, syms, 'Y', O * O * F)
        ref = [s32(sum(img[(oh + r) * S + ow + c] * ker[(r * 3 + c) * F + f] for r in range(3) for c in range(3)))
               for oh in range(O) for ow in range(O) for f in range(F)]
        outs.append(('Y', 'mem', ya, ref, th))
    elif kind == 'conv5':
        img, _ = arr(words, syms, 'img'); ker, _ = arr(words, syms, 'ker')
        S = int(round(len(img) ** 0.5)); O = S - 4; F = len(ker) // 25
        _, ya = arr(words, syms, 'Y', O * O * F)
        ref = [s32(sum(img[(oh + r) * S + ow + c] * ker[(r * 5 + c) * F + f] for r in range(5) for c in range(5)))
               for oh in range(O) for ow in range(O) for f in range(F)]
        outs.append(('Y', 'mem', ya, ref, th))
    elif kind == 'cnn':
        img = extra['img_words']                        # 784, already byte << 16
        ker, _ = arr(words, syms, 'ker'); b1, _ = arr(words, syms, 'bias')
        ker2, _ = arr(words, syms, 'ker2'); b2, _ = arr(words, syms, 'bias2')
        w3, _ = arr(words, syms, 'w3'); b3, _ = arr(words, syms, 'bias3')
        F1, F2, S = 16, 32, 28
        def conv1(oh, ow, f):
            acc = 0
            for r in range(3):
                for c in range(3):
                    acc = s32(acc + q824(img[(oh + r) * S + ow + c], ker[(r * 3 + c) * F1 + f]))
            return relu(s32(acc + b1[f]))
        P1 = 13
        y1 = [0] * (P1 * P1 * F1)
        for i in range(P1):
            for j in range(P1):
                for f in range(F1):
                    y1[(i * P1 + j) * F1 + f] = max(conv1(2 * i + a, 2 * j + c, f) for a in (0, 1) for c in (0, 1))
        def conv2(oh, ow, f):
            acc = 0
            for r in range(3):
                for k in range(F1):
                    for c in range(3):
                        acc = s32(acc + q824(y1[((oh + r) * P1 + ow + c) * F1 + k], ker2[((r * 3 + c) * F1 + k) * F2 + f]))
            return relu(s32(acc + b2[f]))
        P2 = 5
        y2 = [0] * (P2 * P2 * F2)
        for i in range(P2):
            for j in range(P2):
                for f in range(F2):
                    y2[(i * P2 + j) * F2 + f] = max(conv2(2 * i + a, 2 * j + c, f) for a in (0, 1) for c in (0, 1))
        fc = []
        for n in range(10):
            acc = 0
            for k in range(800):
                acc = s32(acc + q824(y2[k], w3[k * 10 + n]))
            fc.append(relu(s32(acc + b3[n])))
        best = 0
        for n in range(10):
            if fc[n] > fc[best]:
                best = n
        _, ya = arr(words, syms, 'Y', len(y1)); _, y2a = arr(words, syms, 'Y2', len(y2))
        outs.append(('Y (layer 1+2 output)', 'mem', ya, y1, None))
        outs.append(('Y2 (layer 3+4 output)', 'mem', y2a, y2, None))
        outs.append(('a0 at layer3 return (digit)', 'x10', 10, [best], None))
        extra['fc_after_relu'] = fc
        extra['argmax'] = best
        extra['max_value'] = fc[best]
    return outs

# ---------------------------------------------------------------- main
MODE = 'shipped'

def main():
    global MODE
    prog, work = sys.argv[1], sys.argv[2]
    img_idx = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    if len(sys.argv) > 4:
        MODE = sys.argv[4]          # 'shipped' (default) | 'relocated'
    rel, kind, funcs = PROGRAMS[prog]
    pdir = os.path.join(BENCH, *rel.split('/'))
    os.makedirs(work, exist_ok=True)
    sections, syms, words = read_elf(os.path.join(pdir, 'riscv-spike.elf'))
    print('program %s (%s), kind %s' % (prog, rel, kind))
    for s in sections:
        if (s['flags'] & 2) and s['size']:
            print('  section %-12s addr 0x%06x size %7d %s' % (s['name'], s['addr'], s['size'], 'NOBITS' if s['type'] == 8 else ''))

    # ---- images from the ELF, laid out as their hex.py does
    base = read_coe(first_existing(os.path.join(pdir, 'Scripts', 'base.hex'),
                                   os.path.join(BENCH, 'conv', 'conv8_3', 'Scripts', 'base.hex')))
    main_img = [0] * 262144
    main_img[:len(base)] = base
    dmem = [[0] * 16384 for _ in range(8)]
    vsec = [s for s in sections if s['name'] == '.vmem_data']
    vbase = vsec[0]['addr'] if vsec else VMEM
    for a, w in words.items():
        if a < VMEM:
            main_img[1024 + a // 4] = w
        elif a < VMEM + 8 * 16384 * 4:
            o = (a - VMEM) // 4
            dmem[o % 8][o // 8] = w
    if vbase != VMEM:
        print('NOTE: .vmem_data is linked at 0x%x, not 0x%x (older memory map).' % (vbase, VMEM))
    # ---- compare with what they shipped
    xm_path = first_existing(os.path.join(pdir, 'Outputfiles', 'xmem.coe'), os.path.join(pdir, 'Scripts', 'xmem.coe'))
    cc_path = first_existing(os.path.join(pdir, 'Outputfiles', 'code.coe'), os.path.join(pdir, 'Scripts', 'code.coe'))
    report = {}
    def cmp_main(label, img):
        if img is None:
            print('  %-34s: not shipped' % label); report[label] = 'not shipped'; return
        n = min(len(img), 262144)
        diff = [i for i in range(n) if img[i] != main_img[i]]
        print('  %-34s: %d words compared, %d differ%s' % (label, n, len(diff),
              (' (first at word %d: shipped %08x, ELF %08x)' % (diff[0], img[diff[0]], main_img[diff[0]])) if diff else ''))
        report[label] = len(diff)
    print('ELF image vs shipped images:')
    cmp_main('xmem.coe (%s)' % (os.path.relpath(xm_path, pdir) if xm_path else '-'), read_coe(xm_path) if xm_path else None)
    cc = read_coe(cc_path) if cc_path else None
    cmp_main('code.coe first 1 MB (%s)' % (os.path.relpath(cc_path, pdir) if cc_path else '-'), cc)
    for b in range(8):
        p = first_existing(os.path.join(pdir, 'Outputfiles', 'dmem_bank%d.coe' % b), os.path.join(pdir, 'Scripts', 'dmem_bank%d.coe' % b))
        sh = read_coe(p) if p else None
        if sh is None:
            print('  dmem_bank%d.coe                     : not shipped' % b); report['dmem%d' % b] = 'not shipped'; continue
        n = len(sh)
        diff = [r for r in range(n) if sh[r] != dmem[b][r]]
        extra_nz = sum(1 for r in range(n, 16384) if dmem[b][r])
        print('  dmem_bank%d.coe (%s): %d rows compared, %d differ, ELF non-zero rows beyond shipped length %d'
              % (b, os.path.relpath(p, pdir), n, len(diff), extra_nz))
        report['dmem%d' % b] = len(diff) + extra_nz
        if vbase != VMEM and MODE == 'shipped':
            dmem[b] = (sh + [0] * 16384)[:16384]
    if vbase != VMEM:
        if MODE == 'shipped':
            print('DMEM images = the SHIPPED dmem_bank*.coe (as their flow loads them); mainMem = ELF image')
        else:
            # RELOCATED variant: put the .vmem_data words in the DMEM rows the
            # vector LSU addresses for these addresses (bank addr[4:2], row addr[18:5]).
            for a, w in words.items():
                if vbase <= a < vbase + vsec[0]['size']:
                    dmem[(a >> 2) & 7][(a >> 5) & 0x3FFF] = w
            print('RELOCATED variant: .vmem_data words also placed in DMEM bank addr[4:2], row addr[18:5]')

    # ---- windows
    calls, end_pc = parse_dump(os.path.join(pdir, 'riscv-spike.dump'), funcs)
    wins = []
    for f in funcs:
        wins.append((f, syms[f][0], calls[f] + 4))
        print('window %-10s entry 0x%05x  call at 0x%05x  return 0x%05x' % (f, syms[f][0], calls[f], calls[f] + 4))
    if kind == 'cnn':
        end_pc = 0          # main never returns (while(1)); the run ends after layer3 returns
    print('final self-loop after main: 0x%x' % end_pc if end_pc else 'no main return (run ends after the last window)')

    # ---- inputs for the CNN (Demo images, UART replaced by a preload)
    extra = {}
    preload = []
    if kind == 'cnn':
        dimg = c_arrays(os.path.join(REPO, 'Demo', 'Application', 'img.c'))
        labels = c_arrays(os.path.join(REPO, 'Demo', 'Application', 'expected_output.c'))
        assert len(dimg) == 100 * 784 and len(labels) == 100, (len(dimg), len(labels))
        px = dimg[img_idx * 784:(img_idx + 1) * 784]
        extra['img_words'] = [(p & 0xFF) << 16 for p in px]   # ISR5_uart: ((int)read_val) << 16, char unsigned
        extra['label'] = labels[img_idx]
        extra['image_index'] = img_idx
        ib = syms['img_buf'][0]; pf = syms['pflag'][0]
        for i, v in enumerate(extra['img_words']):
            preload.append((1024 + (ib + 4 * i) // 4, v))
        preload.append((1024 + pf // 4, 1))
        print('CNN image %d (Demo/Application/img.c), label %d; img_buf 0x%x, pflag 0x%x preloaded'
              % (img_idx, labels[img_idx], ib, pf))
        for a in (ib, pf):
            assert words.get(a, 0) == 0 and a < VMEM

    outs = reference(kind, words, syms, extra)
    for o in outs:
        print('reference %-30s %-4s %s, %d values%s' % (o[0], o[1], hex(o[2]), len(o[3]),
              (', their expected_output[] present (%d)' % len(o[4])) if o[4] else ''))
        if o[4]:
            ex = sum(1 for i in range(len(o[3])) if o[3][i] == o[4][i])
            print('  Python reference vs THEIR expected_output[]: %d / %d exact, max |diff| %d'
                  % (ex, len(o[3]), max(abs(o[3][i] - o[4][i]) for i in range(len(o[3])))))

    # ---- files
    with open(os.path.join(work, 'mainMem.mif'), 'w', newline='\n') as f:
        for w in main_img:
            f.write(format(w, '032b') + '\n')
    for i, (a, v) in enumerate(preload):
        pass
    for b in range(8):
        with open(os.path.join(work, 'DMEM_%d.mif' % b), 'w', newline='\n') as f:
            for w in dmem[b]:
                f.write(format(w, '032b') + '\n')
    with open(os.path.join(work, 'preload.txt'), 'w', newline='\n') as f:
        f.write('%d\n' % len(preload))
        for idx, v in preload:
            f.write('%x %08x\n' % (idx, v & MASK))
    errc = syms.get('err_count', (0, 0))[0]
    mem_outs = [o for o in outs if o[1] == 'mem']
    with open(os.path.join(work, 'bench_params.txt'), 'w', newline='\n') as f:
        f.write('%d\n' % len(wins))
        for _, e, r in wins:
            f.write('%x %x\n' % (e, r))
        f.write('%x\n%x\n' % (end_pc, errc))
        f.write('%d\n' % len(mem_outs))
        for o in mem_outs:
            f.write('%x %d\n' % (o[2], len(o[3])))
        vrf = [o for o in outs if o[1] == 'vrf']
        f.write('%d %d\n' % ((vrf[0][2], len(vrf[0][3])) if vrf else (0, 0)))
    json.dump(dict(program=prog, rel=rel, kind=kind, windows=wins, end_pc=end_pc, err_count_addr=errc,
                   image_report=report, extra={k: v for k, v in extra.items() if k != 'img_words'},
                   outputs=[dict(label=o[0], where=o[1], addr=o[2], ref=o[3], theirs=o[4]) for o in outs]),
              open(os.path.join(work, 'bench.json'), 'w'))
    print('written: mainMem.mif, DMEM_0..7.mif, preload.txt (%d words), bench_params.txt, bench.json' % len(preload))

if __name__ == '__main__':
    main()
