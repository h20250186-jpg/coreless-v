#!/usr/bin/env python3
"""Convert the conv8_3 .coe memory images of the I2SRV32-V repo into the .mif
files (one binary word per line) that the blk_mem_gen simulation wrappers of
mainMem and DMEM_0..7 load at time zero.

Usage: python gen_mif.py <Outputfiles dir> <output dir>
"""
import os
import sys

def coe_to_mif(coe_path, mif_path, width=32):
    with open(coe_path) as f:
        text = f.read()
    body = text.split('=', 2)[2]            # after MEMORY_INITIALIZATION_VECTOR=
    words = [w.strip() for w in body.replace(';', ',').split(',') if w.strip()]
    with open(mif_path, 'w', newline='\n') as f:
        for w in words:
            f.write(format(int(w, 16), '0%db' % width) + '\n')
    return len(words)

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    n = coe_to_mif(os.path.join(src, 'xmem.coe'), os.path.join(dst, 'mainMem.mif'))
    print('mainMem.mif  <- xmem.coe        : %d words' % n)
    for b in range(8):
        n = coe_to_mif(os.path.join(src, 'dmem_bank%d.coe' % b), os.path.join(dst, 'DMEM_%d.mif' % b))
        print('DMEM_%d.mif   <- dmem_bank%d.coe  : %d words' % (b, b, n))
