#!/usr/bin/env python3
"""NEW (2026-11-15). Summarises every run of scripts/run_iisc_bench.ps1 and
scripts/run_iisc_cnn_images.ps1 (sim_build/iisc_bench/<run>/bench.json +
dump.txt + dmem/vrf dumps) into the tables of RESULTS.md "Paper benchmark
rows, measured on their design". Read only.
Usage: python iisc_bench_summary.py
"""
import glob, json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, 'sim_build', 'iisc_bench')
CHECK = os.path.join(ROOT, 'scripts', 'iisc_bench_check.py')

PUBLISHED = {   # Table VII vector #cycles; Table VIII / IX values (µs at 50 MHz -> cycles x 50)
    'saxpy8': 48, 'saxpy16': 56, 'saxpy32': 72, 'saxpy64': 104,
    'perc8': 3142, 'perc16': 3662, 'perc32': 5087, 'perc64': 6782,
    'matmul8': 1755, 'matmul16': 4610, 'matmul32': 20858, 'matmul64': 113786,
}

def run(d):
    if not os.path.exists(os.path.join(d, 'dump.txt')):
        return None
    out = subprocess.run([sys.executable, CHECK, d], capture_output=True, text=True).stdout
    b = json.load(open(os.path.join(d, 'bench.json')))
    W = []; end = None
    for ln in open(os.path.join(d, 'dump.txt')):
        p = ln.split()
        if p and p[0] == 'W': W.append((int(p[2]), int(p[3]), int(p[4])))
        if p and p[0] == 'E': end = int(p[1])
    return b, W, end, out

def kernels():
    print('| Run | Window | reset -> entry | entry -> return | reset -> return | reset -> main returns | Published (cycles) | Window / published | err_count (their check) | Output vs Python ref | Output vs THEIR expected |')
    print('|---|---|---|---|---|---|---|---|---|---|---|')
    for name in ['saxpy8', 'saxpy16', 'saxpy32', 'saxpy64', 'perc8', 'perc16', 'perc32', 'perc64',
                 'perc8_relocated', 'perc16_relocated', 'perc32_relocated', 'perc64_relocated',
                 'mlp256_8', 'mlp256_16', 'matmul8', 'matmul16', 'matmul32', 'matmul64', 'conv8_3', 'conv32_5']:
        r = run(os.path.join(BASE, name))
        if r is None:
            print('| %s | not finished | | | | | | | | | |' % name); continue
        b, W, end, out = r
        (ti, to, _), = W
        pub = PUBLISHED.get(name.replace('_relocated', ''))
        lines = [l.strip() for l in out.splitlines()]
        ec = [l for l in lines if l.startswith('err_count writes')]
        vs = [l for l in lines if ' vs ' in l and 'Python reference' in l]
        vt = [l for l in lines if ' vs ' in l and 'THEIR expected' in l]
        f = lambda L: L[0].split(':', 1)[1].strip() if L else '—'
        print('| %s | %s | %d | %d | %d | %s | %s | %s | %s | %s | %s |' % (
            name, b['windows'][0][0], ti, to - ti, to, end if end and end > 0 else '—',
            pub if pub else '—', ('%.4f' % ((to - ti) / pub)) if pub else '—',
            ec[0].replace('err_count writes ', '') if ec else '—', f(vs), f(vt)))

def literal_argmax(fc, b3):
    """Model of what their design computes in layer3 (found on image 73): FC
    elements 0..7 as the reference (ReLU(acc + bias)), elements 8 and 9 equal
    to bias3[8], bias3[9] (no MACs, no ReLU). Arg-max = first maximum."""
    v = list(fc[:8]) + [b3[8], b3[9]]
    best = 0
    for n in range(10):
        if v[n] > v[best]:
            best = n
    return best

def cnn():
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    import iisc_bench_prep as p
    _, syms, words = p.read_elf(os.path.join(p.BENCH, 'cnn_demo', 'riscv-spike.elf'))
    b3, _ = p.arr(words, syms, 'bias3')
    rows = []
    for d in sorted(glob.glob(os.path.join(BASE, 'cnn_img*')), key=lambda p: int(p.rsplit('img', 1)[1].split('_')[0])):
        r = run(d)
        if r is None: continue
        b, W, end, out = r
        ex = b['extra']
        lines = [l.strip() for l in out.splitlines()]
        exact = all(l.split(':', 1)[1].strip().split(' / ')[0] == l.split(' / ')[1].split(' ')[0]
                    for l in lines if 'vs Python reference' in l and not l.startswith('a0'))
        # FC outputs as their design leaves them in v20..v21 (VRF dump), elements 0..9
        regs = [[int(v, 16) for v in open(os.path.join(d, 'vrf_%d.txt' % k)).read().split()][::-1] for k in range(8)]
        s = lambda x: x - (1 << 32) if x & 0x80000000 else x
        hwfc = [s(regs[e % 8][20 + e // 8]) for e in range(10)]
        lit = list(ex['fc_after_relu'][:8]) + [b3[8], b3[9]]
        rows.append((ex['image_index'], ex['label'], W[-1][2], ex['argmax'], W, exact,
                     literal_argmax(ex['fc_after_relu'], b3), hwfc == lit, hwfc[:8] == ex['fc_after_relu'][:8]))
    if not rows:
        print('no CNN runs'); return
    n = len(rows)
    correct = sum(1 for r in rows if r[2] == r[1])
    agree = sum(1 for r in rows if r[2] == r[3])
    allx = sum(1 for r in rows if r[5])
    lit = sum(1 for r in rows if r[2] == r[6])
    fcl = sum(1 for r in rows if r[7])
    fc8 = sum(1 for r in rows if r[8])
    pyc = sum(1 for r in rows if r[3] == r[1])
    print('CNN images run: %d; hardware digit == label: %d; hardware digit == Python argmax: %d; Y and Y2 bit-exact: %d'
          % (n, correct, agree, allx))
    print('  Python (reference model, exact Q8.24 arithmetic) argmax == label: %d' % pyc)
    print('  FC elements 0..7 in v20 == reference: %d; whole FC vector == "elements 8,9 = bias3 only" model: %d; '
          'hardware digit == arg-max of that model: %d' % (fc8, fcl, lit))
    print('  labels 8 or 9 among the images run: %d' % sum(1 for r in rows if r[1] in (8, 9)))
    wrong = [(r[0], r[1], r[2]) for r in rows if r[2] != r[1]]
    print('misclassified (image, label, hardware digit):', wrong)
    for k, nm in enumerate(['conv2d', 'layer2', 'layer3']):
        vals = sorted(set(r[4][k][1] - r[4][k][0] for r in rows))
        print('  %s entry -> return: %s' % (nm, vals))
    vals = sorted(set(r[4][2][1] - r[4][0][0] for r in rows))
    print('  conv2d entry -> layer3 return: %s' % vals)
    vals = sorted(set(r[4][0][0] for r in rows))
    print('  reset -> conv2d entry: %s' % vals)
    vals = sorted(set(r[4][2][1] for r in rows))
    print('  reset -> layer3 return: %s' % vals)
    print('| Image | Label | Hardware digit (a0 at layer3 return) | Python argmax (reference) | Arg-max of "e8,e9 = bias" model | Y, Y2 bit-exact | FC vector == model |')
    print('|---|---|---|---|---|---|---|')
    for r in rows:
        print('| %d | %d | %d | %d | %d | %s | %s |' % (r[0], r[1], r[2], r[3], r[6], 'yes' if r[5] else 'NO', 'yes' if r[7] else 'NO'))

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'cnn':
        cnn()
    else:
        kernels()
