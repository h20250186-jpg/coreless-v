#!/usr/bin/env python3
"""NEW (2026-11-14). Splits a write_verilog funcsim netlist into several files
at module boundaries, without changing any line, so that Vivado 2019.1 xvlog
can read it (2019.1 xvlog fails on the 1,704,045-line Virtex-7 IISc netlist
with a syntax error reported at line 1,048,575 = 2^20 - 1, where the text is
an ordinary wire declaration).
Every part after the first starts with the netlist's own `timescale line.
A split is made only after an `endmodule` line that is outside any
`ifdef/`ifndef block.

Usage: python -I split_netlist.py <netlist.v> <out dir> [max lines per part]
"""
import os
import re
import sys


def main():
    src, outd = sys.argv[1], sys.argv[2]
    maxl = int(sys.argv[3]) if len(sys.argv) > 3 else 900000
    os.makedirs(outd, exist_ok=True)
    ts = None
    parts, cur, depth = [], [], 0
    with open(src, 'r', newline='') as fh:
        for line in fh:
            s = line.strip()
            if ts is None and s.startswith('`timescale'):
                ts = line
            if re.match(r'`if(n)?def\b', s):
                depth += 1
            elif s.startswith('`endif'):
                depth -= 1
            cur.append(line)
            if s == 'endmodule' and depth == 0 and len(cur) >= maxl:
                parts.append(cur)
                cur = [ts] if ts else []
    if cur:
        parts.append(cur)
    names = []
    total = 0
    for i, p in enumerate(parts):
        n = os.path.join(outd, 'part%02d.v' % i)
        with open(n, 'w', newline='') as fo:
            fo.writelines(p)
        names.append(n)
        total += len(p) - (1 if i > 0 and ts else 0)
        print('SPLIT %s : %d lines' % (n, len(p)))
    print('SPLIT %d parts, %d source lines' % (len(parts), total))


if __name__ == '__main__':
    main()
