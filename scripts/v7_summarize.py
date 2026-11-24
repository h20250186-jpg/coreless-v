#!/usr/bin/env python3
"""NEW (2026-11-13). Reads the post-route reports of one Virtex-7 run directory
(scripts/v7_impl_atee.tcl or v7_impl_iisc.tcl) and prints: utilization
(LUT, FF, latch, BRAM tiles, DSP), the design timing summary (WNS/TNS/
failing endpoints, WHS/THS/failing endpoints), the per-clock table, and the
hierarchy rows requested on the command line.

Usage: python -I v7_summarize.py <run dir> [<instance name> ...]
"""
import re
import sys
import os


def table_rows(text, title_regex):
    m = re.search(title_regex, text)
    if not m:
        return []
    rows = []
    for line in text[m.end():].splitlines():
        if line.startswith('|'):
            rows.append([c.strip() for c in line.strip().strip('|').split('|')])
        elif rows and not line.startswith('+') and line.strip() == '':
            break
    return rows


def main():
    d = sys.argv[1]
    want = sys.argv[2:]
    u = open(os.path.join(d, 'post_route_utilization.rpt'), errors='replace').read()
    print('== utilization (post-route)')
    for key in ('Slice LUTs', 'LUT as Logic', 'LUT as Memory', 'Slice Registers', 'Register as Flip Flop',
                'Register as Latch', 'Slice', 'Block RAM Tile', 'RAMB36/FIFO', 'RAMB18', 'DSPs', 'Bonded IOB',
                'BUFGCTRL', 'MMCME2_ADV'):
        for line in u.splitlines():
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            if cells and re.sub(r'\*+$', '', cells[0]).strip() == key and len(cells) >= 5:
                print('   %-22s used %-10s available %-10s util%% %s' % (key, cells[1], cells[-2] if len(cells) > 5 else cells[3], cells[-1]))
                break
    t = open(os.path.join(d, 'post_route_timing_summary.rpt'), errors='replace').read()
    print('== design timing summary')
    m = re.search(r'Design Timing Summary.*?\n\s*WNS\(ns\).*?\n\s*-+.*?\n(.*?)\n', t, re.S)
    if m:
        v = m.group(1).split()
        names = ['WNS', 'TNS', 'TNS fail', 'TNS total', 'WHS', 'THS', 'THS fail', 'THS total', 'WPWS', 'TPWS', 'TPWS fail', 'TPWS total']
        print('   ' + ', '.join('%s=%s' % (n, x) for n, x in zip(names, v)))
    m = re.search(r'Intra Clock Table\s*\n-+\s*\n(.*?)\n\n\n', t, re.S)
    if m:
        print('== intra-clock table')
        for line in m.group(1).splitlines():
            if line.strip():
                print('   ' + line.rstrip())
    m = re.search(r'Inter Clock Table\s*\n-+\s*\n(.*?)\n\n\n', t, re.S)
    if m:
        print('== inter-clock table')
        for line in m.group(1).splitlines():
            if line.strip():
                print('   ' + line.rstrip())
    m = re.search(r'Clock Summary\s*\n-+\s*\n(.*?)\n\n\n', t, re.S)
    if m:
        print('== clocks')
        for line in m.group(1).splitlines():
            if line.strip():
                print('   ' + line.rstrip())
    h = os.path.join(d, 'post_route_utilization_hier.rpt')
    if want and os.path.exists(h):
        ht = open(h, errors='replace').read().splitlines()
        hdr = None
        for line in ht:
            if line.startswith('|') and 'Instance' in line and 'Total LUTs' in line:
                hdr = [c.strip() for c in line.strip().strip('|').split('|')]
                print('== hierarchy  ' + ' | '.join(hdr))
                break
        for w in want:
            for line in ht:
                if line.startswith('|'):
                    cells = [c.strip() for c in line.strip().strip('|').split('|')]
                    if cells[0] == w or cells[0].startswith(w + ' ') or cells[0] == '(' + w + ')':
                        print('   ' + ' | '.join(cells))
                        break
            else:
                print('   %s : NOT FOUND' % w)


if __name__ == '__main__':
    main()
