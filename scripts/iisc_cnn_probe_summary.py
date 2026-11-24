#!/usr/bin/env python3
"""NEW (2026-11-16). Read-only summary of the cnn_demo checks A.1 / A.3
(scripts/run_iisc_cnn_probe.ps1):
  zero   : the 100 images with the zero stand-ins (sim_build/iisc_cnn_probe/zero/img<k>)
           against the recorded 2026-11-15 runs with the assumed stand-ins
           (sim_build/iisc_bench/cnn_img<k>): digit, cycles, Y/Y2 exactness,
           whole DMEM image and VRF; probe counts summed over all images.
  uart   : image 7 over the UART path (sim_build/iisc_cnn_probe/assumed_uart/img7)
           against the preload runs of image 7 (assumed probe run and the
           2026-11-15 run): cycles per window, Y, Y2 (DMEM), FC vector (VRF), a0.
Usage: python iisc_cnn_probe_summary.py zero|uart
"""
import os, sys, json, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, 'sim_build', 'iisc_cnn_probe')
BENCH = os.path.join(ROOT, 'sim_build', 'iisc_bench')

def windows(d):
    # dump.txt line: "W <window> <t_in> <t_out> <x10>"
    W = [list(map(int, l.split()[2:5])) for l in open(os.path.join(d, 'dump.txt')) if l.startswith('W ')]
    return W   # [t_in, t_out, x10]

def mem(d):
    return [open(os.path.join(d, 'dmem_%d.txt' % b)).read().split() for b in range(8)]

def vrf(d):
    return [open(os.path.join(d, 'vrf_%d.txt' % b)).read().split() for b in range(8)]

def word(banks, a):
    o = (a - 0x100000) // 4
    return banks[o % 8][o // 8]

def probe(d):
    out = {}
    for ln in open(os.path.join(d, 'probe.txt')):
        if ':' in ln and ln.startswith('  '):
            k, v = ln.split(':', 1)
            try:
                out.setdefault(cur, {})[k.strip()] = [int(x) for x in v.split()]
            except ValueError:
                pass
        elif ln.startswith('ITLB') or ln.startswith('DTLB'):
            cur = ln[:4]
    return out

def compare_runs(a, b):
    ja = json.load(open(os.path.join(a, 'bench.json')))
    Wa, Wb = windows(a), windows(b)
    ma, mb = mem(a), mem(b)
    va, vb = vrf(a), vrf(b)
    res = {}
    for o in ja['outputs']:
        if o['where'] != 'mem': continue
        n = len(o['ref'])
        res[o['label']] = sum(1 for i in range(n) if word(ma, o['addr'] + 4 * i) == word(mb, o['addr'] + 4 * i))
    res['dmem words equal'] = sum(1 for k in range(8) for r in range(len(ma[k])) if ma[k][r] == mb[k][r])
    res['dmem words'] = sum(len(x) for x in ma)
    res['vrf words equal'] = sum(1 for k in range(8) for r in range(len(va[k])) if va[k][r] == vb[k][r])
    res['vrf words'] = sum(len(x) for x in va)
    return Wa, Wb, res

def zero():
    n = same_digit = same_cyc = exact = 0
    tot = {}
    diffs = []
    labels_ok = 0
    for k in range(100):
        dz = os.path.join(PROBE, 'zero', 'img%d' % k)
        da = os.path.join(BENCH, 'cnn_img%d' % k)
        if not os.path.exists(os.path.join(dz, 'dump.txt')) or not os.path.exists(os.path.join(dz, 'vrf_7.txt')):
            continue
        n += 1
        Wz, Wa, res = compare_runs(dz, da)
        jz = json.load(open(os.path.join(dz, 'bench.json')))
        dig_z, dig_a = Wz[2][2], Wa[2][2]
        same_digit += dig_z == dig_a
        labels_ok += dig_z == jz['extra']['label']
        cz = [w[1] - w[0] for w in Wz]; ca = [w[1] - w[0] for w in Wa]
        same_cyc += (cz == ca and Wz[0][0] == Wa[0][0])
        ok = res['dmem words equal'] == res['dmem words'] and res['vrf words equal'] == res['vrf words']
        exact += ok
        if not ok or dig_z != dig_a or cz != ca:
            diffs.append((k, dig_a, dig_z, cz, ca, res))
        for t, d in probe(dz).items():
            for key, v in d.items():
                acc = tot.setdefault(t, {}).setdefault(key, [0] * 7)
                for i in range(7): acc[i] += v[i]
    print('ZERO stand-ins: images run %d; digit == 2026-11-15 (assumed stand-ins) run: %d; digit == label: %d' % (n, same_digit, labels_ok))
    print('  windows (reset->entry and all three entry->return) identical: %d; whole DMEM (131,072 words) AND VRF (256 words) identical: %d' % (same_cyc, exact))
    print('  differences:', diffs if diffs else 'none')
    print('  probe counts summed over the %d images, phases 0..6 (before | conv2d | between | layer2 | between | layer3 | after):' % n)
    for t in ('ITLB', 'DTLB'):
        for key in ('miss', 'we', 'EVA_en', 'update_EVA', 'stand-in inputs change', 'stand-in outputs change', 'sorted_index change', 'EVA_addr change'):
            if key in tot.get(t, {}):
                print('    %s %-24s: %s' % (t, key, ' '.join(str(x) for x in tot[t][key])))

def uart():
    du = os.path.join(PROBE, 'assumed_uart', 'img7')
    for ref, name in ((os.path.join(PROBE, 'assumed', 'img7'), 'preload, probe testbench (2026-11-16)'),
                      (os.path.join(BENCH, 'cnn_img7'), 'preload, 2026-11-15 run')):
        Wu, Wr, res = compare_runs(du, ref)
        print('UART image 7 vs %s:' % name)
        for i, nm in enumerate(('conv2d', 'layer2', 'layer3')):
            print('  %s: UART entry %d, entry->return %d | preload entry %d, entry->return %d'
                  % (nm, Wu[i][0], Wu[i][1] - Wu[i][0], Wr[i][0], Wr[i][1] - Wr[i][0]))
        print('  a0 (digit) at layer3 return: UART %d, preload %d' % (Wu[2][2], Wr[2][2]))
        for k, v in res.items():
            print('  %s: %s' % (k, v))
    print(open(os.path.join(du, 'probe.txt')).read().split('events logged')[1].strip())

if __name__ == '__main__':
    {'zero': zero, 'uart': uart}[sys.argv[1]]()
