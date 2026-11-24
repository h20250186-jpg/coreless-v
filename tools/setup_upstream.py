#!/usr/bin/env python3
"""Rebuilds the I2SRV32-V-derived files that this package does not ship, and
checks every one against tools/expected_sha256.txt.

The I2SRV32-V repository (Apache-2.0) is referenced, not redistributed:
    https://github.com/RClabiisc/I2SRV32-V-v1
    commit a0b43781b03d8b9d5e4e217675e229a57da3bc62
(the commit is the comment of the master-branch zip used for every recorded result).

Usage (from the package root; Python 3.8+, standard library only):
    python -I tools/setup_upstream.py --zip <path to the repository zip>
    python -I tools/setup_upstream.py --download        (fetches the zip of the commit)
Options:
    --vivado2026   also build the Vivado 2026.1 working copies
                   external_2026/iisc_copy/, iisc_paper_cfg/ and atee_paper_cfg/
                   (their IP containers are copied unchanged; the 2026.1 scripts
                   upgrade them in place, so re-run this step before a re-run)

Steps:
 1. unpack the repository to external/I2SRV32-V-v1-master/ (needed by every IISc
    simulation and implementation script);
 2. copy their rtl/vector_unit files and rtl/defines.v, timescale.v,
    verilogutils.vh into rtl/, apply patches/01_inherited_vector_unit.patch;
 3. (--vivado2026) build the 2026.1 copies and apply patches 02, 03, 05;
 4. verify SHA-256 of every reconstructed file.
"""
import argparse, hashlib, os, shutil, sys, urllib.request, zipfile

COMMIT = 'a0b43781b03d8b9d5e4e217675e229a57da3bc62'
URL = 'https://github.com/RClabiisc/I2SRV32-V-v1/archive/%s.zip' % COMMIT
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
UP = os.path.join(ROOT, 'external', 'I2SRV32-V-v1-master')
INHERITED_VU = ['alu.vhd', 'count_gen.vhd', 'cpu_inf.vhd', 'dmem_addr_xbar.vhd', 'exe_unit.vhd',
                'lsu.vhd', 'multicycle_ops.vhd', 'mypack.vhd', 'stall_gen.vhd', 'vec_decoder.v',
                'vector_top.v', 'vminmax.vhd', 'vrf_bank.vhd', 'v_wrapper.v', 'wrapper.vhd',
                'xoutreg.vhd']
ATEE_PAPER_CFG = ['alu.vhd', 'atee_top_vl16.v', 'count_gen.vhd', 'cpu_inf.vhd', 'div_gen_behav.vhd',
                  'dmem_addr_xbar.vhd', 'dmem_bram.vhd', 'exe_unit.vhd', 'hbm_lite_controller_vl16.v',
                  'lsu.vhd', 'multicycle_ops.vhd', 'mypack.vhd', 'outsize_div.v', 'stall_gen.vhd',
                  'tensor_config_regs.v', 'vminmax.vhd', 'vrf_bank.vhd', 'v_wrapper.v', 'wrapper.vhd',
                  'xoutreg.vhd']


def die(msg):
    sys.exit('ERROR: ' + msg)


# ---------------------------------------------------------------- patch applier
def parse_patch(path):
    """Returns [(target path, [hunks])]; hunk = (old_start, [(tag, text)])."""
    with open(path, 'rb') as f:
        L = f.read().decode('latin-1').splitlines(True)
    files, i = [], 0
    while i < len(L):
        if L[i].startswith('--- ') and i + 1 < len(L) and L[i + 1].startswith('+++ '):
            tgt = L[i + 1][4:].rstrip('\r\n')
            tgt = tgt[2:] if tgt.startswith('b/') else tgt
            new = L[i][4:].rstrip('\r\n') == '/dev/null'
            hunks, i = [], i + 2
            while i < len(L) and L[i].startswith('@@'):
                f_old, f_new = L[i].split()[1:3]
                old_start = int(f_old.split(',')[0][1:])
                n_old = int(f_old.split(',')[1]) if ',' in f_old else 1
                n_new = int(f_new.split(',')[1]) if ',' in f_new else 1
                body, i = [], i + 1
                while n_old > 0 or n_new > 0:      # hunk length from the @@ header
                    t = L[i][0]
                    if t not in ' -+':
                        die('%s: malformed hunk line %d' % (os.path.basename(path), i + 1))
                    body.append((t, L[i][1:]))
                    n_old -= t in ' -'
                    n_new -= t in ' +'
                    i += 1
                    if i < len(L) and L[i].startswith('\\'):   # "\ No newline at end of file"
                        body[-1] = (body[-1][0], body[-1][1].rstrip('\r\n'))
                        i += 1
                hunks.append((old_start, body))
            files.append((tgt, new, hunks))
        else:
            i += 1
    return files


def apply_patch(patch, base):
    for tgt, new, hunks in parse_patch(patch):
        p = os.path.join(base, *tgt.split('/'))
        old = [] if new else open(p, 'rb').read().decode('latin-1').splitlines(True)
        out, pos = [], 0
        for old_start, body in hunks:
            want = [s for t, s in body if t in ' -']
            at = max(old_start - 1, 0)
            if old[at:at + len(want)] != want:
                die('%s: hunk at line %d does not match %s' % (os.path.basename(patch), old_start, tgt))
            out += old[pos:at]
            out += [s for t, s in body if t in ' +']
            pos = at + len(want)
        out += old[pos:]
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(''.join(out).encode('latin-1'))
        print('  patched', os.path.relpath(p, ROOT))


# ---------------------------------------------------------------- steps
def unpack(zpath):
    with zipfile.ZipFile(zpath) as z:
        c = z.comment.decode('ascii', 'replace')
        if c and c != COMMIT:
            die('zip is commit %s, expected %s' % (c, COMMIT))
        print('zip commit:', c or '(no comment; cannot confirm commit, hashes are checked below)')
        if os.path.isdir(UP):
            print('external/I2SRV32-V-v1-master exists, not unpacked again')
            return
        names = z.namelist()
        top = names[0].split('/')[0] + '/'
        tmp = UP + '.tmp'
        for n in names:
            if not n.startswith(top) or n.endswith('/'):
                continue
            rel = n[len(top):]
            dst = os.path.join(tmp, *rel.split('/'))
            if os.path.relpath(dst, tmp).startswith('..'):
                die('unsafe path in zip: ' + n)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with z.open(n) as s, open(dst, 'wb') as d:
                shutil.copyfileobj(s, d)
        os.rename(tmp, UP)
        print('unpacked to external/I2SRV32-V-v1-master')


def inherited():
    src = os.path.join(UP, 'Source code', 'rtl')
    for n in INHERITED_VU:
        shutil.copyfile(os.path.join(src, 'vector_unit', n), os.path.join(ROOT, 'rtl', 'vector_unit', n))
    for n in ['defines.v', 'timescale.v', 'verilogutils.vh']:
        shutil.copyfile(os.path.join(src, n), os.path.join(ROOT, 'rtl', n))
    print('copied %d inherited files into rtl/' % (len(INHERITED_VU) + 3))
    apply_patch(os.path.join(ROOT, 'patches', '01_inherited_vector_unit.patch'), ROOT)


def vivado2026():
    e26 = os.path.join(ROOT, 'external_2026')
    coe = os.path.join(UP, 'benchmarks', 'benchmarks', 'conv', 'conv8_3', 'Outputfiles')
    for cp in ['iisc_copy', 'iisc_paper_cfg']:
        d = os.path.join(e26, cp)
        if os.path.exists(d):
            shutil.rmtree(d)
        shutil.copytree(os.path.join(UP, 'Source code'), os.path.join(d, 'Source code'))
        os.makedirs(os.path.join(d, 'conv8_3_coe'))
        for n in ['code.coe', 'xmem.coe'] + ['dmem_bank%d.coe' % k for k in range(8)]:
            shutil.copyfile(os.path.join(coe, n), os.path.join(d, 'conv8_3_coe', n))
        shutil.copyfile(os.path.join(ROOT, 'external', 'iisc_sim', 'xbip_dsp48_macro_missing.v'),
                        os.path.join(d, 'xbip_dsp48_macro_missing.v'))
        print('built external_2026/' + cp)
    # 05: constraints_noexc.xdc = their constraints.xdc + patch (target name is the file itself)
    shutil.copyfile(os.path.join(UP, 'Source code', 'constraints', 'constraints.xdc'),
                    os.path.join(e26, 'iisc_copy', 'constraints_noexc.xdc'))
    apply_patch(os.path.join(ROOT, 'patches', '05_iisc_constraints_noexc.patch'), os.path.join(e26, 'iisc_copy'))
    apply_patch(os.path.join(ROOT, 'patches', '02_iisc_paper_cfg_128KB.patch'), os.path.join(e26, 'iisc_paper_cfg'))
    a = os.path.join(e26, 'atee_paper_cfg', 'vector_unit')
    if os.path.exists(a):
        shutil.rmtree(a)
    os.makedirs(a)
    for n in ATEE_PAPER_CFG:
        shutil.copyfile(os.path.join(ROOT, 'rtl', 'vector_unit', n), os.path.join(a, n))
    apply_patch(os.path.join(ROOT, 'patches', '03_atee_paper_cfg_128KB.patch'), os.path.join(e26, 'atee_paper_cfg'))
    print('built external_2026/atee_paper_cfg/vector_unit')


def verify(with2026):
    bad = n = 0
    for line in open(os.path.join(HERE, 'expected_sha256.txt')):
        h, rel = line.rstrip('\n').split('  ', 1)
        if rel.startswith('external_2026/') and not with2026:
            continue
        p = os.path.join(ROOT, *rel.split('/'))
        got = hashlib.sha256(open(p, 'rb').read()).hexdigest() if os.path.exists(p) else 'missing'
        n += 1
        if got != h:
            bad += 1
            print('  MISMATCH', rel)
    print('verify: %d files, %d mismatches -> %s' % (n, bad, 'PASS' if bad == 0 else 'FAIL'))
    return bad == 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--zip')
    g.add_argument('--download', action='store_true')
    ap.add_argument('--vivado2026', action='store_true')
    a = ap.parse_args()
    z = a.zip
    if a.download:
        os.makedirs(os.path.join(ROOT, 'external'), exist_ok=True)
        z = os.path.join(ROOT, 'external', 'I2SRV32-V-v1-%s.zip' % COMMIT[:12])
        if not os.path.exists(z):
            print('downloading', URL, '(about 280 MB)')
            urllib.request.urlretrieve(URL, z)
    unpack(z)
    inherited()
    if a.vivado2026:
        vivado2026()
    sys.exit(0 if verify(a.vivado2026) else 1)
