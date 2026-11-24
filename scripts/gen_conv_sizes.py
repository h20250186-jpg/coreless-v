#!/usr/bin/env python3
"""
Data for the I2SRV32-V CONV2D 3x3 benchmarks at several image sizes
(their benchmarks/benchmarks/conv/conv{S}_3), for BOTH designs.

New script (2026-11-11). Reads THEIR files only: app/c/img.c, app/c/ker.c,
app/c/expected_output.c, include/header.h, riscv-spike.dump. No NumPy.

Usage:
  python gen_conv_sizes.py <size> <out dir> [--distinct]

Writes into <out dir>:
  conv_input.hex     IMG*IMG*8 words : pixel p replicated in words p*8..p*8+7
  conv_weights.hex   144 words       : OC-innermost [(kh*3+kw)*16 + oc]
  conv_golden.hex    OH*OW*16 words  : Python reference, OC-innermost [(oh*OW+ow)*16 + oc]
  conv_theirs.hex    OH*OW*16 words  : THEIR expected_output[] (only without --distinct)
  conv_params.txt    sizes + their symbol addresses, read by both testbenches
Prints the reference-vs-theirs comparison (exact matches, max |diff|).

--distinct : replace their (identical-per-filter) kernel by the mixed-sign,
             distinct-per-filter weights used for the conv8_3 distinct set,
             w[tap][oc] = 3*oc + tap - 19 ; their input image is kept.
"""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
BENCH = os.path.join(ROOT, 'external', 'I2SRV32-V-v1-master', 'benchmarks', 'benchmarks', 'conv')


def c_array(path):
    """Integer values between the first '{' and the matching '}' of a C file."""
    with open(path) as f:
        text = f.read()
    body = text[text.index('{') + 1:text.rindex('}')]
    return [int(v) for v in re.findall(r'-?\d+', body)]


def header_define(path, name):
    with open(path) as f:
        for line in f:
            m = re.match(r'\s*#define\s+%s\s+(\S+)' % name, line)
            if m:
                return m.group(1)
    raise ValueError('%s not defined in %s' % (name, path))


def dump_symbols(path, names):
    out = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'^([0-9a-f]{8}) <(\w+)>:', line)
            if m and m.group(2) in names:
                out[m.group(2)] = int(m.group(1), 16)
    return out


def hex32(v):
    return '%08X' % (v & 0xFFFFFFFF)


def wrap32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def main():
    size = int(sys.argv[1])
    out = sys.argv[2]
    distinct = '--distinct' in sys.argv[3:]
    d = os.path.join(BENCH, 'conv%d_3' % size)

    img_size = int(header_define(os.path.join(d, 'include', 'header.h'), 'IMG_SIZE'))
    ker_size = int(header_define(os.path.join(d, 'include', 'header.h'), 'KER_SIZE'))
    n_filt = int(header_define(os.path.join(d, 'include', 'header.h'), 'N_FILT_LAYER1'))
    assert img_size == size and ker_size == 3, (img_size, ker_size)

    img = c_array(os.path.join(d, 'app', 'c', 'img.c'))
    ker = c_array(os.path.join(d, 'app', 'c', 'ker.c'))
    theirs = c_array(os.path.join(d, 'app', 'c', 'expected_output.c'))
    osz = img_size - ker_size + 1
    n_out = osz * osz * n_filt
    taps = ker_size * ker_size
    assert len(img) == img_size * img_size, len(img)
    assert len(ker) == taps * n_filt, len(ker)
    assert len(theirs) == n_out, (len(theirs), n_out)

    if distinct:
        ker = [3 * oc + tap - 19 for tap in range(taps) for oc in range(n_filt)]

    # Python reference: correlation, no bias (their bias is all zero), stride 1,
    # no padding, 32-bit wrap (the cores keep the low 32 bits).
    golden = []
    for oh in range(osz):
        for ow in range(osz):
            for oc in range(n_filt):
                acc = 0
                for kh in range(ker_size):
                    for kw in range(ker_size):
                        acc += img[(oh + kh) * img_size + (ow + kw)] * ker[(kh * ker_size + kw) * n_filt + oc]
                golden.append(wrap32(acc))

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'conv_input.hex'), 'w', newline='\n') as f:
        for p in img:
            for _ in range(8):
                f.write(hex32(p) + '\n')
    with open(os.path.join(out, 'conv_weights.hex'), 'w', newline='\n') as f:
        for w in ker:
            f.write(hex32(w) + '\n')
    with open(os.path.join(out, 'conv_golden.hex'), 'w', newline='\n') as f:
        for g in golden:
            f.write(hex32(g) + '\n')
    if not distinct:
        with open(os.path.join(out, 'conv_theirs.hex'), 'w', newline='\n') as f:
            for t in theirs:
                f.write(hex32(t) + '\n')

    sym = dump_symbols(os.path.join(d, 'riscv-spike.dump'),
                       {'Y', 'err_count', 'expected_output', 'conv2d', 'main'})
    in_words = img_size * img_size * 8
    with open(os.path.join(out, 'conv_params.txt'), 'w', newline='\n') as f:
        # one decimal or hex value per line, in this order (read with $fscanf)
        f.write('%d\n%d\n%d\n%d\n%d\n%d\n' % (img_size, ker_size, n_filt, osz, in_words, n_out))
        f.write('%08x\n%08x\n%08x\n%d\n' % (sym['Y'], sym['expected_output'], sym['err_count'], 1 if distinct else 0))

    exact = sum(1 for a, b in zip(golden, theirs) if a == b)
    maxd = max(abs(a - b) for a, b in zip(golden, theirs))
    print('conv%d_3%s: input %dx%d, kernel %dx%d, %d filters, %d outputs (%dx%dx%d)'
          % (size, ' DISTINCT weights' if distinct else '', img_size, img_size, ker_size, ker_size,
             n_filt, n_out, osz, osz, n_filt))
    print('  their symbols: Y=0x%08x expected_output=0x%08x err_count=0x%08x conv2d=0x%x main=0x%x'
          % (sym['Y'], sym['expected_output'], sym['err_count'], sym['conv2d'], sym['main']))
    print('  output range of the reference: min %d, max %d' % (min(golden), max(golden)))
    if not distinct:
        print('  Python reference vs THEIR expected_output: %d / %d exact, max |diff| %d' % (exact, n_out, maxd))
    else:
        print('  (their expected_output does not apply to the distinct-weight variant)')


if __name__ == '__main__':
    main()
