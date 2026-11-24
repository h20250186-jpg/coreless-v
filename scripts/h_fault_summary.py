#!/usr/bin/env python3
"""NEW (2026-11-19, task H step 5). Read-only summary of the five fault
testbenches across vector-unit trees: for every test (=== header) the compact
result of each result line (counts like 7/8 and PASS/FAIL/OK/WRONG), one column
per tree. Sources: sim_build_h/<tree>/fault/<tb>/xsim.log and, as column
"recorded", sim_build/<tb>/xsim.log (the logs behind the recorded results).
Usage: python -I h_fault_summary.py <tree> [<tree> ...]
"""
import os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TBS = ['convoy', 'convoy_multi', 'lane_load', 'convoy_reuse', 'convoy_vl16']

def parse(path):
    if not os.path.exists(path):
        return None
    res, cur = {}, None
    for ln in open(path, errors='replace'):
        s = ln.strip()
        m = re.match(r'=== (\S+?)[:\s]', s)
        if m:
            cur = m.group(1); res.setdefault(cur, []); continue
        if cur is None or s.startswith('t='):
            continue
        if '->' in s or re.search(r'\b(OK|WRONG|PASS|FAIL)\b', s) or 'collision' in s.lower():
            counts = re.findall(r'\d+/\d+', s)
            verdict = re.findall(r'\b(PASS|FAIL|OK|WRONG|correct)\b', s)
            frag = ' '.join(counts) + (' ' + verdict[-1] if verdict else '')
            res[cur].append(frag.strip() or s[:40])
    return res

trees = sys.argv[1:]
for tb in TBS:
    cols = [('recorded', parse(os.path.join(ROOT, 'sim_build', tb, 'xsim.log')))]
    cols += [(t, parse(os.path.join(ROOT, 'sim_build_h', t, 'fault', tb, 'xsim.log'))) for t in trees]
    print('### %s' % tb)
    names = []
    for _, r in cols:
        for k in (r or {}):
            if k not in names:
                names.append(k)
    print('  %-8s' % 'test' + ''.join(' | %-30s' % c for c, _ in cols))
    for n in names:
        row = '  %-8s' % n
        for _, r in cols:
            v = 'no log' if r is None else ('(absent)' if n not in r else '; '.join(r[n]) or '(no result line)')
            row += ' | %-30s' % v[:30]
        print(row)
