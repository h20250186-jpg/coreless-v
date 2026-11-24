#!/usr/bin/env python3
"""
generate_test_data.py — Generate test data + golden reference for Coreless-V verification.

Produces TWO test suites matching the original I2SRV32-V benchmarks:

  TEST 1: conv8_3  — 8x8 ramp image, integer kernels (1-9), no bias, no activation
                     Matches benchmarks/benchmarks/conv/conv8_3/ exactly
                     Output: 6x6x16 = 576 values (no pooling, no ReLU)

  TEST 2: mnist_conv1 — Real MNIST image (digit "7"), trained Q-format weights,
                         with bias and ReLU activation
                         Matches benchmarks/benchmarks/cnn_demo/ Conv1 layer
                         Output: 26x26x16 = 10816 values (no pooling in Coreless-V)

Outputs (.hex files for $readmemh in Verilog testbench):
  test1_input.hex       — 512 words (8x8 ramp 0..63, each pixel replicated 8x:
                                     one full 8-bank DMEM row per pixel)
  test1_weights.hex     — 144 words (9 kernel positions x 16 filters, OC-innermost)
  test1_bias.hex        — 16 words  (all zero)
  test1_golden.hex      — 576 words (expected conv2d output, [oh][ow][oc] order)

  test2_input.hex       — 6272 words (28x28 MNIST digit "7", each pixel replicated 8x)
  test2_weights.hex     — 144 words (trained Conv1 kernels from repo, OC-innermost)
  test2_golden.hex      — 10816 words (expected conv2d output, BIAS OMITTED, no ReLU)
  test2_golden_relu.hex — 10816 words (same, with ReLU)
  (The trained Conv1 bias is NOT applied: the controller has no bias path.)

Usage:
  python3 generate_test_data.py
  (creates files in ../testbench/)
"""

import os
import struct

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), '..', 'testbench')


def to_hex32(val):
    """Convert a signed 32-bit integer to 8-char hex string."""
    return format(val & 0xFFFFFFFF, '08X')


def write_hex_file(filename, values):
    """Write list of 32-bit integers as hex file (one word per line)."""
    path = os.path.join(OUTPUT_DIR, filename)
    with open(path, 'w') as f:
        for v in values:
            f.write(to_hex32(v) + '\n')
    print(f"  Written {len(values)} words to {filename}")


# =============================================================================
# TEST 1: conv8_3 — matches repo's benchmarks/conv/conv8_3/ exactly
# =============================================================================
def generate_test1():
    """
    Reproduce the conv8_3 benchmark from the original I2SRV32-V repo.
    
    Image: 8x8 ramp (0,1,2,...,63) — plain 32-bit integers
    Kernel: 3x3 x 16 filters, stored as [ker_pos][filter]
      ker[0..15]   = K[0][0] for filters 0-15 = {1,1,...,1}
      ker[16..31]  = K[0][1] for filters 0-15 = {2,2,...,2}
      ...
      ker[128..143]= K[2][2] for filters 0-15 = {9,9,...,9}
    Bias: all zeros
    No activation (ReLU off), no pooling
    
    Conv2D: output[oc][oh][ow] = sum over kh,kw of img[oh+kh][ow+kw] * ker[kh*3+kw][oc]
    Output: 6x6 spatial, 16 channels = 576 values
    
    NOTE: In the repo's kernel layout, each kernel position has 16 identical values
    (same weight for all filters). So all 16 output channels are identical.
    """
    print("\n=== TEST 1: conv8_3 (8x8 ramp, integer kernels) ===")
    
    IMG_SIZE = 8
    KER_SIZE = 3
    N_FILT = 16
    OUT_SIZE = IMG_SIZE - KER_SIZE + 1  # 6
    
    # Image: 8x8 ramp
    img = list(range(IMG_SIZE * IMG_SIZE))  # [0, 1, 2, ..., 63]
    
    # Kernel: 9 positions x 16 filters, OC-innermost [kh][kw][oc] (the repo's
    # native ker[pos*16 + filter] layout). This matches the HBM controller's
    # address formula:
    #   weight_offset = (kh * kernel_w + kw) * output_c + oc
    # so the 8 output channels of one OC group are 8 consecutive words = the
    # 8 elements (one per DMEM bank) of a unit-stride vl=8 vector load.
    # Weight value at position (kh, kw) = kh*3+kw+1 (same for all filters)
    ker = []
    for pos in range(9):  # 0..8 = K[0][0]..K[2][2]
        for filt in range(N_FILT):
            ker.append(pos + 1)

    # Bias: all zero
    bias = [0] * 16

    # Compute golden output
    # Weight access uses OC-innermost indexing: ker[(kh * 3 + kw) * 16 + oc]
    # Output order matches HBM controller: [oh][ow][oc] (OC-innermost), i.e.
    #   output_offset = (oh * OUT_W + ow) * output_c + oc
    golden = []
    for oh in range(OUT_SIZE):
        for ow in range(OUT_SIZE):
            for oc in range(N_FILT):
                acc = 0
                for kh in range(KER_SIZE):
                    for kw in range(KER_SIZE):
                        pixel = img[(oh + kh) * IMG_SIZE + (ow + kw)]
                        weight = ker[(kh * KER_SIZE + kw) * N_FILT + oc]
                        acc += pixel * weight
                golden.append(acc)

    assert len(golden) == OUT_SIZE * OUT_SIZE * N_FILT  # 576

    # Verify against repo's expected_output (first few values)
    # repo: 555, 555, ...(x16), 600, 600, ...(x16), 645, ...
    print(f"  Golden[0]:  {golden[0]} (oh=0,ow=0,oc=0, expects: 555)")
    print(f"  Golden[16]: {golden[16]} (oh=0,ow=1,oc=0, expects: 600)")
    print(f"  Golden[32]: {golden[32]} (oh=0,ow=2,oc=0, expects: 645)")

    # Input memory image: each pixel REPLICATED 8x so it fills all 8 DMEM banks
    # of its own row (word address = pixel_index * 8 + bank). A unit-stride
    # vl=8 load of that row then delivers the same pixel to all 8 output
    # channels of an OC group -- a broadcast done by layout, because a
    # MODE="10" broadcast load collides with other slots in the convoy.
    REPL = 8
    img_mem = []
    for p in img:
        img_mem.extend([p] * REPL)
    assert len(img_mem) == IMG_SIZE * IMG_SIZE * REPL  # 512

    # Write hex files (line i of each file = word i of that DMEM region)
    write_hex_file('test1_input.hex', img_mem)
    write_hex_file('test1_weights.hex', ker)
    write_hex_file('test1_bias.hex', bias)
    write_hex_file('test1_golden.hex', golden)
    
    return golden


# =============================================================================
# TEST 2: MNIST Conv1 — matches repo's cnn_demo Conv1 layer
# =============================================================================
def generate_test2():
    """
    Reproduce the CNN demo's Conv1 layer from the original I2SRV32-V repo.
    
    Image: 28x28 MNIST digit "7" (first test image from benchmarks/cnn_demo/app/c/img.c)
           Stored as 32-bit hex values (already in Q-format from repo)
    Kernel: 3x3x1x16 trained weights from benchmarks/cnn_demo/app/c/ker.c
    Bias: 16 trained values from benchmarks/cnn_demo/app/c/bias.c
    Activation: ReLU (max(0, x))
    No pooling (Coreless-V does conv-only; pooling is separate in the repo)
    
    Output: 26x26x16 = 10816 values
    
    NOTE: The repo's Conv1 INCLUDES MaxPool2x2, producing 13x13x16.
    Coreless-V does pure Conv2D (no pooling), producing 26x26x16.
    For paper comparison, we compare cycle counts for the convolution portion only.
    """
    print("\n=== TEST 2: MNIST Conv1 (28x28, trained weights, BIAS OMITTED) ===")
    
    IMG_SIZE = 28
    KER_SIZE = 3
    N_FILT = 16
    OUT_SIZE = IMG_SIZE - KER_SIZE + 1  # 26
    
    # Image: first MNIST test image from repo (digit "7")
    # These are the exact hex values from benchmarks/cnn_demo/app/c/img.c
    img_hex = [
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00747474, 0x007D7D7D,
        0x00ABABAC, 0x01000000, 0x01000000, 0x00969697, 0x005D5D5D, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00A9A9AA, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE,
        0x00DADADB, 0x001E1E1E, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00A9A9AA, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE,
        0x00D5D5D6, 0x008E8E8F, 0x00B0B0B1, 0x00FDFDFE, 0x00FDFDFE, 0x007A7A7A, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00343434,
        0x00FAFAFB, 0x00FDFDFE, 0x00D2D2D3, 0x00202020, 0x000C0C0C, 0x00000000, 0x00060606, 0x00CECECF,
        0x00FDFDFE, 0x008C8C8D, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x004D4D4D, 0x00FBFBFC, 0x00D2D2D3, 0x00191919, 0x00000000,
        0x00000000, 0x00000000, 0x007A7A7A, 0x00F8F8F9, 0x00FDFDFE, 0x00414141, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x001F1F1F, 0x00121212, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00D1D1D2, 0x00FDFDFE,
        0x00FDFDFE, 0x00414141, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00757575, 0x00F7F7F8, 0x00FDFDFE, 0x00C6C6C7, 0x000A0A0A, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x004C4C4C, 0x00F7F7F8, 0x00FDFDFE, 0x00E7E7E8,
        0x003F3F3F, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00808081, 0x00FDFDFE, 0x00FDFDFE, 0x00909091, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00B0B0B1, 0x00F6F6F7, 0x00FDFDFE, 0x009F9FA0, 0x000C0C0C,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00191919, 0x00EAEAEB,
        0x00FDFDFE, 0x00E9E9EA, 0x00232323, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00C6C6C7, 0x00FDFDFE, 0x00FDFDFE, 0x008D8D8E, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x004E4E4E, 0x00F8F8F9, 0x00FDFDFE,
        0x00BDBDBE, 0x000C0C0C, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00131313, 0x00C8C8C9, 0x00FDFDFE, 0x00FDFDFE, 0x008D8D8E, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00868687, 0x00FDFDFE, 0x00FDFDFE, 0x00ADADAE,
        0x000C0C0C, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00F8F8F9, 0x00FDFDFE, 0x00FDFDFE, 0x00191919, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00F8F8F9, 0x00FDFDFE, 0x00FDFDFE, 0x002B2B2B,
        0x00141414, 0x00141414, 0x00141414, 0x00141414, 0x00050505, 0x00000000, 0x00050505, 0x00141414,
        0x00141414, 0x00252525, 0x00969697, 0x00969697, 0x00969697, 0x00939394, 0x000A0A0A, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00F8F8F9, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE,
        0x00A8A8A9, 0x008F8F90, 0x00A6A6A7, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE,
        0x00FDFDFE, 0x00FDFDFE, 0x007B7B7B, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00AEAEAF, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE,
        0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE, 0x00FDFDFE,
        0x00F9F9FA, 0x00F7F7F8, 0x00F7F7F8, 0x00A9A9AA, 0x00757575, 0x00757575, 0x00393939, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00767676, 0x007B7B7B, 0x007B7B7B, 0x007B7B7B, 0x00A6A6A7, 0x00FDFDFE, 0x00FDFDFE,
        0x00FDFDFE, 0x009B9B9C, 0x007B7B7B, 0x007B7B7B, 0x00292929, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    ]
    assert len(img_hex) == 784, f"Image has {len(img_hex)} pixels, expected 784"
    
    # Kernel: 3x3x1x16 trained weights from cnn_demo/app/c/ker.c
    # Layout: ker[pos*16 + filter] — 9 positions x 16 filters = 144 values
    ker_hex = [
        0x003B11A9, 0xFFA922F1, 0xFFF06C8A, 0x00280537, 0xFFF7A54A, 0xFFD905DC, 0xFFA8F02E, 0x001BFEC4,
        0x0049226B, 0x00301C3A, 0x002BE795, 0xFFCDB65A, 0xFFDDEE75, 0x0051478E, 0x003429AB, 0x00459EA2,
        0xFFF1B325, 0x00091DEC, 0x001A81BE, 0xFFE554E2, 0x00619D94, 0xFFE5E5A8, 0xFFDA4F1A, 0x0022975A,
        0x005BC3B5, 0x00559AB6, 0x004CDFD9, 0xFFB0EE60, 0x0042C226, 0x00606713, 0x001C622B, 0x00556D3D,
        0xFF9049E0, 0x005B4BD2, 0x002DB22A, 0x000325F2, 0x003ED7C6, 0x0014DE11, 0xFFCC1C15, 0x001A1819,
        0x004614E8, 0xFFE72E8C, 0x002A7BB5, 0x001E2187, 0x0041E51E, 0x002381C6, 0x002A8696, 0x005354D8,
        0x00403E84, 0xFFC3CDB9, 0xFFC385B0, 0x002EF222, 0xFFEC0272, 0xFFABB14A, 0x00286403, 0x005AD5CF,
        0xFFC828CA, 0xFFDF3989, 0x004EC8AF, 0xFFF5B835, 0x000B1959, 0xFFE0800A, 0x0043F68B, 0xFFC9833E,
        0xFFFE84E1, 0xFFED18D4, 0x002558E5, 0x0051F946, 0x001B1FE9, 0x00079A20, 0xFFD4837F, 0x004111AE,
        0xFFC279AB, 0x003656E6, 0x004503DA, 0x0039959C, 0x0050E84F, 0xFFEFFB68, 0x003A4E2B, 0xFFE37A83,
        0xFFAE0B91, 0x000AF24C, 0x0026B784, 0x0011449C, 0x0041F84A, 0x00358AC1, 0xFFE46C8A, 0xFF94018F,
        0xFFCC62C9, 0x001FA20F, 0x002D3106, 0x00021365, 0xFFF4875A, 0x000AA25E, 0x00578B2F, 0x003B7130,
        0x0054962B, 0xFFC9113A, 0xFFBCBD7C, 0x00526AD5, 0x0003E01B, 0xFFC27263, 0x002D22C7, 0x00335931,
        0xFFA7F5AB, 0xFFC64797, 0x002443F5, 0x004983C6, 0x001B4494, 0xFFAA2970, 0xFFB7D16B, 0xFF8F64E7,
        0x0030281F, 0x002CE092, 0x002B87A2, 0x002A2DC4, 0x00075DAB, 0xFFE7847B, 0x003D4AFD, 0xFFBB476E,
        0xFFEA495A, 0x00365B81, 0x0018A1EF, 0x002EF27D, 0x001AEDD4, 0xFFB58A97, 0xFFB37D05, 0xFFDA55F6,
        0xFFF5F4B2, 0x003FF492, 0x003EBB11, 0x00367E4A, 0x0015636F, 0x004A558A, 0x004DB579, 0xFF81BE31,
        0xFFE38A3C, 0x002B7F24, 0xFFE14748, 0x003FD889, 0xFFD3ED36, 0xFFE2DF8A, 0xFFDECDD0, 0xFFE8EAF8,
    ]
    assert len(ker_hex) == 144, f"Kernel has {len(ker_hex)} values, expected 144"
    
    # Bias: 16 trained values from cnn_demo/app/c/bias.c
    bias_hex = [
        0xFFFF4C93, 0xFFFFEE0D, 0xFFFFB25A, 0xFFFEE597, 0x00008699, 0x000B9A9F, 0x0010945B, 0x000C6AF5,
        0x000CE56D, 0xFFF3E2B4, 0xFFFF6664, 0xFFFF2B39, 0xFFFF4C83, 0x000E1593, 0xFFFFD3BC, 0xFFFFE4FA,
    ]
    
    # Convert hex to signed 32-bit for Python arithmetic
    def to_signed32(v):
        if v >= 0x80000000:
            return v - 0x100000000
        return v

    img_s = [to_signed32(v) for v in img_hex]
    ker_s = [to_signed32(v) for v in ker_hex]

    # Compute golden output: Conv2D with integer multiply.
    #
    # The hardware MAC keeps the low 32 bits of each 32x32 product (Q_FORMAT = 0,
    # prod[31:0] in alu.vhd) and adds it to the accumulator modulo 2^32:
    #   acc[f] = sum over taps of (img[row][col] * ker[pos*16 + f])   (mod 2^32)
    #
    # *** BIAS IS DELIBERATELY OMITTED. *** The live hbm_lite_controller has no
    # bias path (tap 0 is a MUL that overwrites the accumulator), so this
    # workload is "MNIST conv1 input and trained weights, bias omitted". The
    # trained bias_hex above is kept for reference only and is not used.
    #
    # Output layout (same as repo): [oh][ow] position, then 16 filters
    # (OC-innermost). Total: 26 * 26 * 16 = 10816.
    # Two golden files: without activation, and with ReLU = max(0, signed acc).
    golden = []
    golden_relu = []
    for oh in range(OUT_SIZE):
        for ow in range(OUT_SIZE):
            for f in range(N_FILT):
                acc = 0
                for kh in range(KER_SIZE):
                    for kw in range(KER_SIZE):
                        pixel = img_s[(oh + kh) * IMG_SIZE + (ow + kw)]
                        weight = ker_s[(kh * KER_SIZE + kw) * N_FILT + f]
                        acc = (acc + pixel * weight) & 0xFFFFFFFF
                golden.append(acc)
                golden_relu.append(0 if acc >= 0x80000000 else acc)

    assert len(golden) == OUT_SIZE * OUT_SIZE * N_FILT  # 10816

    # Stats
    negative = sum(1 for g in golden if g >= 0x80000000)
    nonzero = sum(1 for g in golden if g != 0)
    print(f"  Output size: {OUT_SIZE}x{OUT_SIZE}x{N_FILT} = {len(golden)} values (bias omitted)")
    print(f"  Non-zero outputs: {nonzero} / {len(golden)} ({100*nonzero/len(golden):.1f}%)")
    print(f"  Negative outputs (clamped by ReLU): {negative} / {len(golden)}")
    print(f"  First 16 values (no ReLU): {[hex(g) for g in golden[:16]]}")

    # Input memory image: each pixel replicated 8x, one full 8-bank DMEM row
    # per pixel, exactly as for test 1.
    REPL = 8
    img_mem = []
    for px in img_hex:
        img_mem.extend([px] * REPL)
    assert len(img_mem) == IMG_SIZE * IMG_SIZE * REPL  # 6272

    # Write hex files (line i of each file = word i of that DMEM region)
    write_hex_file('test2_input.hex', img_mem)
    write_hex_file('test2_weights.hex', ker_hex)
    write_hex_file('test2_golden.hex', golden)
    write_hex_file('test2_golden_relu.hex', golden_relu)

    return golden


# =============================================================================
# TEST 1 is the key PoC — same data, same computation, verifiable
# =============================================================================
if __name__ == '__main__':
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    print("=" * 60)
    print("Coreless-V Test Data Generator")
    print("Matching I2SRV32-V benchmark methodology")
    print("=" * 60)
    
    golden1 = generate_test1()
    
    # Verify test1 against known repo values
    # [oh][ow][oc] order: oc=0 of the first 4 spatial positions (oh=0, ow=0..3)
    # sits at indices 0, 16, 32, 48
    repo_expected_start = [555, 600, 645, 690]
    match = all(golden1[i * 16] == repo_expected_start[i] for i in range(len(repo_expected_start)))
    print(f"\n  Repo validation: {'PASS' if match else 'FAIL'}")
    if not match:
        for i in range(len(repo_expected_start)):
            if golden1[i * 16] != repo_expected_start[i]:
                print(f"    Mismatch at [{i * 16}]: got {golden1[i * 16]}, expected {repo_expected_start[i]}")
    
    # Test 2: MNIST conv1, bias omitted (see generate_test2). There are no
    # upstream expected values for conv-only without bias and pooling, so this
    # golden has no built-in spot check; it was cross-checked against an
    # independent implementation when first generated (see CLAUDE.md).
    generate_test2()
    
    print("\n" + "=" * 60)
    print("Files generated in testbench/")
    print("Use $readmemh in Verilog testbench to load these files")
    print("=" * 60)
