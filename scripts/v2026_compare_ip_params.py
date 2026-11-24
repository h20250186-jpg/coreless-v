#!/usr/bin/env python3
"""NEW (2026-11-12). Pre-(c) check 1 of the Vivado 2026.1 gate test.

Compares, per IP, the user parameters (PARAM_VALUE.*) of the ORIGINAL 2020.2
.xci (extracted from their .xcix) with the parameters of the same IP in the
2026.1 copy after upgrade_ip / generate_target (dumped by v2026_gate_b2.tcl as
params_<ip>.txt, from list_property CONFIG.*).

Optionally also compares the model parameters (MODELPARAM_VALUE.C_*) of the
original .xci with the C_* generics found in the generated 2026.1 simulation
wrapper of each IP (paths listed in files_<ip>.txt).

Usage: python -I v2026_compare_ip_params.py <orig_xci dir> <gate_b2 dir> [<dir with the .xcix contents extracted>]
Writes <gate_b2 dir>/param_compare.txt and prints a summary.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

SPIRIT = '{http://www.spiritconsortium.org/XMLSchema/SPIRIT/1685-2009}'


def orig_params(path):
    user, model = {}, {}
    root = ET.parse(path).getroot()
    for el in root.iter(SPIRIT + 'configurableElementValue'):
        ref = el.get(SPIRIT + 'referenceId') or ''
        val = (el.text or '').strip()
        if ref.startswith('PARAM_VALUE.'):
            user[ref[len('PARAM_VALUE.'):]] = val
        elif ref.startswith('MODELPARAM_VALUE.'):
            model[ref[len('MODELPARAM_VALUE.'):]] = val
    return user, model


def new_params(path):
    d = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if '=' in line:
                k, v = line.split('=', 1)
                d[k] = v
    return d


def sim_generics(files_txt):
    """C_* generics/parameters from the generated simulation wrapper."""
    gens = {}
    if not os.path.exists(files_txt):
        return gens, None
    ip = os.path.basename(files_txt)[len('files_'):-len('.txt')]
    wrapper = None
    with open(files_txt) as f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 4:
                continue
            p = parts[3]
            if EXTRACT_ROOT and '/IP/' in p:
                # the generated files live inside the .xcix; use the extracted copy
                p = os.path.join(EXTRACT_ROOT, p.split('/IP/', 1)[1])
            base = os.path.basename(p)
            if 'simulation' in parts[0] and base in (ip + '.v', ip + '.vhd') and os.sep + 'sim' in p.replace('/', os.sep):
                wrapper = p
    if wrapper and os.path.exists(wrapper):
        txt = open(wrapper, errors='replace').read()
        for m in re.finditer(r'\.(C_[A-Za-z0-9_]+)\s*\(\s*([^)]*?)\s*\)', txt):
            gens[m.group(1)] = m.group(2)
        for m in re.finditer(r'\b(C_[A-Za-z0-9_]+)\s*=>\s*([^,\n)]+)', txt):
            gens.setdefault(m.group(1), m.group(2).strip())
    return gens, wrapper


def norm(v):
    v = v.strip().strip('"')
    if re.fullmatch(r"\d+'[bdh][0-9a-fA-F_]+", v):
        base = {'b': 2, 'd': 10, 'h': 16}[v.split("'")[1][0]]
        return str(int(v.split("'")[1][1:].replace('_', ''), base))
    return v


EXTRACT_ROOT = None


def main():
    global EXTRACT_ROOT
    odir, gdir = sys.argv[1], sys.argv[2]
    if len(sys.argv) > 3:
        EXTRACT_ROOT = sys.argv[3]
    out = []
    totals = []
    for fn in sorted(os.listdir(odir)):
        if not fn.endswith('.xci'):
            continue
        ip = fn[:-4]
        ou, om = orig_params(os.path.join(odir, fn))
        npath = os.path.join(gdir, 'params_%s.txt' % ip)
        if not os.path.exists(npath):
            out.append('== %s: NO 2026.1 PARAMS (IP missing)' % ip)
            totals.append((ip, None, None, None, None))
            continue
        nu = new_params(npath)
        diffs, only_o = [], []
        for k, v in sorted(ou.items()):
            if k not in nu:
                only_o.append(k)
            elif norm(v) != norm(nu[k]):
                diffs.append((k, v, nu[k]))
        only_n = sorted(k for k in nu if k not in ou and k != 'IPDEF')
        gens, wrapper = sim_generics(os.path.join(gdir, 'files_%s.txt' % ip))
        mdiffs, mmissing = [], []
        for k, v in sorted(om.items()):
            if not k.startswith('C_'):
                continue
            if k not in gens:
                mmissing.append(k)
            elif norm(v) != norm(gens[k]):
                mdiffs.append((k, v, gens[k]))
        out.append('== %s  (orig user params %d, 2026.1 params %d; %s)' % (ip, len(ou), len(nu), nu.get('IPDEF', '?')))
        for k, a, b in diffs:
            out.append('   USER DIFF  %-45s orig=%r  2026.1=%r' % (k, a, b))
        if only_o:
            out.append('   USER only in original (%d): %s' % (len(only_o), ' '.join(only_o)))
        if only_n:
            out.append('   USER only in 2026.1  (%d): %s' % (len(only_n), ' '.join(only_n)))
        out.append('   sim wrapper: %s (%d C_* found)' % (wrapper, len(gens)))
        for k, a, b in mdiffs:
            out.append('   MODEL DIFF %-45s orig=%r  2026.1=%r' % (k, a, b))
        if mmissing:
            out.append('   MODEL C_* of original not in 2026.1 wrapper (%d): %s' % (len(mmissing), ' '.join(mmissing)))
        totals.append((ip, len(diffs), len(only_o), len(mdiffs), len(mmissing)))
    with open(os.path.join(gdir, 'param_compare.txt'), 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('\n'.join(out))
    print('\nSUMMARY ip / user diffs / user params missing in 2026.1 / model diffs / model params missing')
    for t in totals:
        print('  %-20s %s' % (t[0], ' / '.join(str(x) for x in t[1:])))


if __name__ == '__main__':
    main()
