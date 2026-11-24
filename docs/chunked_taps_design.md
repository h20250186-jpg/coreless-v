# Chunked-taps schedule for Coreless-V — design note (2026-11-15)

Status: DESIGN NOTE ONLY. No RTL of this schedule exists and nothing here has
been simulated. Every cycle count below is a PROJECTION from a model whose
constants are measured counts of the two existing controllers. Numbers in this
note are quoted from `docs/chunked_taps_model_output.txt`, produced by
`scripts/chunked_taps_model.py`. RESULTS.md stays the source for every
measured number; it records this note as a projection, not a result.

## 1. Problem

Both existing controllers preload ALL tap weights of an output-channel group
into the vector register file (VRF) before sweeping the pixels:

- vl=8 controller: tap t in v(16+t). At most 16 taps (IC x KH x KW).
- vl=16 controller: each vector takes two registers. At most 9 taps on the
  ReLU path and 11 without ReLU.

Layers the paper benchmarks that exceed this:

| Workload | Taps |
|---|---|
| CONV2D 5x5 | 25 |
| MATMUL D x D as a 1x1 convolution | D (8 to 64) |
| MLP layer 1 (784 inputs) | 784 |
| cnn_demo layer 2 (3x3 kernel, 16 input channels) | 144 |
| cnn_demo FC layer (800 inputs) | 800 |

## 2. Options considered

| Option | Idea | Verdict |
|---|---|---|
| A. Stream weights per tap (Step-5 style) | Load the weight vector from memory for every tap of every pixel. | No tap limit. MEASURED on conv8_3: 12,387 cycles vs 3,403 for the preload schedule. Kept as the fallback. |
| B. Chunked preload, partial sums spilled in place | Split the taps into chunks of C. For each chunk, preload its C weight vectors, then sweep all pixels: load the pixel's partial sum, add C taps, store it back into the pixel's own output location. The last chunk applies bias / ReLU and writes the final value. | **Chosen.** Weights are loaded once per chunk instead of once per pixel. The extra cost is one partial-sum load and one store per pixel per chunk. No extra memory: the partial sum lives where the output will live. |
| C. Chunked preload, partial sums resident in the VRF | Keep the accumulators of a tile of pixels in registers across chunks. | Rejected. A chunk is reused across all pixels, so every pixel's accumulator would have to stay resident. Even a small pixel tile takes registers away from the tap weights, which is the resource being rationed. |

## 3. Schedule (option B)

Loop order per layer:

```
for each output-channel group g        (OC / vl groups; OC padded up to a multiple of vl)
  for each chunk c of the taps          (C taps; the last chunk may be shorter)
    preload the C weight vectors of (g, c) into the tap registers
    for each output pixel p
      convoys of <= 3 taps:  input loads | MACs  (as today)
      first convoy of chunk c > 0:  + load of the partial sum of (p, g) into the accumulator
                                     (tap 0 of the chunk is a MAC, not a MUL)
      last convoy:  + store of the accumulator to the output location of (p, g)
      last chunk only: + bias (as the "partial sum" of chunk 0), + fused ReLU
```

Chunk capacity:

- **vl=8:** C = 15. That is 16 tap registers rounded down to a multiple of 3, so every chunk is made of full 3-tap convoys.
- **vl=16:** C = 9, the ReLU-path register limit. Non-final chunks could use 11; the model does not, to keep a single register map.

### Compliance with the four scheduling rules (inherited-core hazards)

| Rule | How the chunked schedule meets it |
|---|---|
| 1. No load directly before its reader | The partial-sum load takes slot 0 of the chunk's first convoy. The input loads move to slots 1–3 and the MACs to slots 4–6. Each MAC reads its input load 3 slots back. The first MAC reads the partial sum 4 slots back through the register file, the same path as the measured 4-tap convoy (`convoy_4tap_tb.v`). |
| 2. No store in slot 7 | The store stays in the chunk's LAST convoy, after its MACs (slot <= 6). It never shares a convoy with the partial-sum load: chunks are built with >= 2 convoys, and with C = 15 or 9 that always holds except for a 1–3 tap remainder chunk. A remainder chunk at vl=16 costs one extra convoy in the model. |
| 3. Unit-stride loads only | The partial-sum load is an ordinary unit-stride vector load of the output location. Inputs stay replicated vl times in memory, as today. |
| 4. Every slot occupied at vl > 8 | Unchanged: all 8 slots are issued in every vl=16 convoy. The partial-sum load uses slot 0, which a 3-tap vl=16 convoy leaves as a running no-op today. |

Bank collisions: the partial-sum load and the store address the same
OC-innermost vector the store already writes. That vector is aligned to bank 0
like every other access in the convoy. The stagger argument of the existing
schedule (slot j on bank (c − j) mod 8) is unchanged.

## 4. Cycle model

All constants are measured counts of the existing controllers:

| Item | Constant |
|---|---|
| Init + output-size divider, per layer | 19 cycles (3 + 16) |
| vl=8 compute convoy, n taps | 2n + 9 cycles |
| vl=8 store | +1 |
| vl=8 partial-sum or bias load | +1 |
| vl=8 fused ReLU | +3 (3,619 − 3,403 = 72 × 3) |
| vl=8 weight-preload convoy, n loads | n + 9 cycles |
| vl=16 compute convoy | 23 cycles |
| vl=16 store convoy | +1 |
| vl=16 partial-sum load | 0 (free slot 0) |
| vl=16 fused ReLU | +3 (73 vs 70 measured) |
| vl=16 weight-preload convoy (3 loads) | 20 cycles |

Total cycles:

```
19 + sum over groups g, chunks c of [ preload(c) + P x pixel(c) ]
```

where P is the number of output pixels.

**Check against recorded results.** The model reproduces exactly:

| Run | Model | Recorded |
|---|---|---|
| vl=8, conv8_3 | 3,403 | 3,403 |
| vl=8, CONV2D 3x3 64x64 | 353,739 | 353,739 |
| vl=8, MNIST conv1 with ReLU | 66,339 | 66,339 |
| vl=16, conv8_3 | 2,599 | 2,599 |
| vl=16, CONV2D 3x3 64x64 | 269,159 | 269,159 |
| vl=16, MNIST conv1 with ReLU | 49,427 | 49,427 |

These are all single-chunk cases. The multi-chunk terms (partial-sum load, the
remainder-chunk convoy at vl=16) are design assumptions, not measurements.

## 5. Projected cycles and memory fit (512 KB = 131,072 words)

**Memory model, in words:**

```
input values x vl   (replication)
+ taps x OCpad      (weights)
+ P x OCpad         (outputs, which double as partial sums)
```

| Workload | P | Taps | OC | vl=8 cycles | vl=8 words | vl=8 fit | vl=16 cycles | vl=16 words | vl=16 fit |
|---|---|---|---|---|---|---|---|---|---|
| CONV2D 5x5 8x8, 1 in-ch, 32 filters (as conv32_5) | 16 | 25 | 32 | 9,019 | 1,824 | fits | 7,099 | 2,336 | fits |
| CONV2D 5x5 16x16, 32 filters | 144 | 25 | 32 | 77,627 | 7,456 | fits | 60,859 | 9,504 | fits |
| CONV2D 5x5 32x32, 32 filters | 784 | 25 | 32 | 420,667 | 34,080 | fits | 329,659 | 42,272 | fits |
| CONV2D 5x5 64x64, 32 filters | 3,600 | 25 | 32 | 1,930,043 | 148,768 | DOES NOT FIT | 1,512,379 | 181,536 | DOES NOT FIT |
| CONV2D 5x5 8x8, 16 filters | 16 | 25 | 16 | 4,519 | 1,168 | fits | 3,559 | 1,680 | fits |
| CONV2D 5x5 16x16, 16 filters | 144 | 25 | 16 | 38,823 | 4,752 | fits | 30,439 | 6,800 | fits |
| CONV2D 5x5 32x32, 16 filters | 784 | 25 | 16 | 210,343 | 21,136 | fits | 164,839 | 29,328 | fits |
| CONV2D 5x5 64x64, 16 filters | 3,600 | 25 | 16 | 965,031 | 90,768 | fits | 756,199 | 123,536 | fits |
| MATMUL 8x8 as 1x1 conv | 8 | 8 | 8 | 406 | 640 | fits | 639 | 1,280 | fits |
| MATMUL 16x16 | 16 | 16 | 16 | 3,007 | 2,560 | fits | 2,379 | 4,608 | fits |
| MATMUL 32x32 | 32 | 32 | 32 | 22,047 | 10,240 | fits | 16,907 | 18,432 | fits |
| MATMUL 64x64 | 64 | 64 | 64 | 173,635 | 40,960 | fits | 139,251 | 73,728 | fits |
| MLP layer 1: 784 -> 32, bias, ReLU | 1 | 784 | 32 | 28,727 | 31,392 | fits | 22,779 | 37,664 | fits |
| MLP layer 2: 32 -> 16, bias, ReLU | 1 | 32 | 16 | 625 | 784 | fits | 499 | 1,040 | fits |
| MLP layer 3: 16 -> 10 (OC padded to 16), bias | 1 | 16 | 10 | 339 | 400 | fits | 279 | 528 | fits |
| cnn_demo layer 1: 28x28, 3x3, 16 filters, bias, ReLU (26x26 conv, before pooling) | 676 | 9 | 16 | 67,691 | 17,232 | fits | 49,427 | 23,504 | fits |
| cnn_demo layer 2: 13x13x16 -> 32, 144 taps, bias, ReLU (11x11 conv) | 121 | 144 | 32 | 361,935 | 30,112 | fits | 273,705 | 51,744 | fits |
| cnn_demo layer 2, only the 10x10 outputs the pooling reads | 100 | 144 | 32 | 299,523 | 29,440 | fits | 226,539 | 51,072 | fits |
| cnn_demo FC 800 -> 10 (OC padded to 16), bias, ReLU | 1 | 800 | 10 | 14,653 | 19,216 | fits | 11,592 | 25,616 | fits |

Reading the table:

- **CONV2D 5x5 at 64x64 with 32 filters does not fit** in 512 KB at either vl, mainly because of the 3,600 x 32 outputs. With 16 filters it fits. The paper does not state the filter count of its 5x5 benchmark; their repo's conv32_5 has 32.
- **Matrix-vector layers (MLP, FC, P = 1) do not reuse weights across pixels,** so the preload is pure overhead. Per tap and channel group, the model gives about 9 cycles at vl=8 (4 preload + 5 compute). The measured Step-5 streaming schedule costs about 19 cycles per tap: 12,387 / 648 convoys on conv8_3. So chunking is still the better of the two, but neither uses the hardware well for P = 1.
- **MATMUL 8x8 at vl=16** pads 8 output channels to 16, so half of every vector is wasted.
- **Layer totals do not include data relayout between layers** (section 6, item 7).
- The measured IISc values these projections will be compared with are recorded in RESULTS.md ("Paper benchmark rows, measured on their design"). No ratio is computed from a projection.

## 6. What else the full cnn_demo needs

LUT figures are ESTIMATES by analogy with the existing controller (vl=16
controller 822 LUT / 347 FF / 18 DSP post-route on the stand-in; RESULTS.md
"vl=16 controller"). They are not synthesis results.

| # | Feature | What it takes | Cycle estimate | LUT estimate |
|---|---|---|---|---|
| 1 | Chunk loop (this note) | Chunk counter; weight base + c·C·OCpad; partial-sum load slot. | as in section 5 | 60–120 |
| 2 | Bias | Bias base-address config register (+32 FF). The bias vector is loaded as the chunk-0 partial sum. | vl=8 +1 per pixel-group; vl=16 0 (free slot 0) | 30–60 |
| 3 | Q-format | Already present: `q_format` config field -> `vec_quant` -> the core's `vcsr_quant` (Q32.0 / Q24.8 / Q16.16 / Q8.24). Never exercised: every recorded run used Q32.0. cnn_demo runs in Q8.24 (their CSR reset value; their code never changes it). | 0 | 0 (exists) |
| 4 | 2x2 max-pool | Sweep pixels in 2x2 tiles; keep 4 accumulators; signed max (ALU funct 101, the op ReLU already uses) x3; one ReLU and one store per pooled pixel. ReLU and max commute. vl=8 has the registers (v7–v15 free). At vl=16, 4 accumulators take 8 registers, which forces C below 9 (about 6) or spills. | per pooled pixel: −3 stores, +3 max slots, −3 ReLU slots, about −3 to +3 vs four unpooled pixels; needs an isolated test | 150–250 |
| 5 | FC 800 -> 10 | No new hardware beyond item 1 (1x1 conv, P = 1). Weights stored with OC padded to 16 (zeros). | 14,653 (vl=8) / 11,592 (vl=16), section 5 | 0 beyond item 1 |
| 6 | Argmax | The inherited core's `vminmax` unit returns the signed-max INDEX (the paper's custom instruction; their layer3 uses it). Issue one vl=10 argmax instruction; capture its scalar result from the X-register write path into a status register. | about vl + 9 ≈ 20 | 40–80 (+32 FF) |
| 7 | Layer chaining / relayout | Our input layout replicates every input value vl times. A layer's output is written OC-innermost, NOT replicated, so the next layer cannot read it directly. Options: (a) host/testbench copy between layers (no hardware, not counted in cycles); (b) write the output replicated, using vl strided stores per output vector (stride vl words, offsets +4k). Untested; strided stores put all elements in one bank, so collisions with other slots must be scheduled. | (b): about +vl store slots per output vector, about +8 (vl=8) / +16 (vl=16) cycles per output vector | (b) 80–150 |
| 8 | Layer sequencer | Today the testbench writes the config registers per layer. A descriptor table (3 layers) would make the network run unattended. | about 20 per layer | 100–200 |

Total, very rough: +460 to +860 LUT over the 1,219-LUT control logic, about
1.4x–1.7x. This remains far below IISc's 39,468-LUT control logic (RESULTS.md
"Provenance audit"). It is an estimate, not a measurement.

**Not covered:** UART input of the image (cnn_demo receives it over UART; Coreless-V
has no CPU, so the image would be preloaded as in every other Coreless-V run).

## 7. What would have to be measured before any number here is quoted as a result

1. An isolated convoy test of a chunk boundary, at vl=8 and vl=16: the partial-sum load in slot 0 and the first MAC reading it 4 slots back.
2. A remainder chunk of 1–3 taps at vl=16.
3. Bias as the chunk-0 partial sum.
4. A 2x2 pooled tile.
5. One full layer with more than 16 taps: CONV2D 5x5 32x32, 32 filters, against their conv32_5 expected outputs, which the Python reference reproduces 25,088/25,088 (RESULTS.md, "Paper benchmark rows").
6. Q8.24 end to end (cnn_demo layer 1 against the Python reference of `scripts/iisc_bench_prep.py`).

Status 2026-11-16: item 1 is DONE (section 9). Items 2–6 are open.

## 8. Layer 2 without spilling partial sums — alternatives (added 2026-11-16)

Still a design note: projections only, no RTL. Model `scripts/chunked_taps_alt_model.py`, output `docs/chunked_taps_alt_model_output.txt`.

**Cost rule used from here on ("slot rule").** A convoy costs (last occupied slot + 10) cycles at vl=8, or (last occupied slot + 18) at vl=16, where all 8 slots are issued and the early clear comes 16 cycles after the last real slot.
- It is the controller protocol itself, and it is MEASURED: it equals the FSM count in all runs of the stage-1 test (section 9). It reproduces the six recorded counts of section 4.
- It replaces the flat constants of section 4. Two of those were wrong in multi-chunk cases:
  - a 1-tap vl=8 convoy needs a gap slot before its MAC (rule 1), so it costs 1 more than 2n+9;
  - a vl=16 convoy costs 18–25 cycles depending on its layout, not a flat 23. A partial-sum convoy, whose MACs move to slots 4–6, costs 24, not 23 + 0.
- Section 5 recomputed with this rule changes by −3.5% to +1.4%. Both columns are in the output file.

### 8.1 How IISc runs layer 2 (their `cnn_demo/app/asm/layer2.S`, measured 175,674 cycles)

- vl = 32 (`m4`): all 32 filters in one vector.
- **4 accumulators** (v16, v20, v24, v28) = one 2x2 pooling window, **resident for all 144 taps**: nothing is spilled.
- Weights are **streamed**: 3 loads per kernel row, each reused by the 4 accumulators, so 12 `vmacc` per 3 loads.
- The **input pixel is a scalar operand** (`vmacc.vx vd, s, v`), read by the scalar core with `lw`. There is no input replication and no vector load per input value.
- ReLU, then max over the 4 accumulators, then one store per pooled pixel.

### 8.2 Options

| Option | Idea | Register budget (vl=8 / vl=16, of 31) | Scheduling rules touched |
|---|---|---|---|
| B (section 3) | Chunks of preloaded weights; partial sums spilled in place | 15 taps + acc + 3 X + zero = 20 / 2 × (9 + 1 + 3 + 1) = 28 | 1: PSUM in slot 0, first MAC 4 slots later (measured, section 9). 2: store ≤ slot 6, so a single-convoy chunk needs an extra store convoy. 3: unit-stride PSUM. 4: no-ops at vl=16 |
| B9 = "input-channel-outer" | B with chunk = the 9 taps of one input channel | 9 + 1 + 3 + 1 | as B. It still spills; at vl=16 it is identical to B (C = 9 already) |
| C | Accumulators of a Q-pixel tile stay resident across chunks; the chunk's weights are re-preloaded per tile | C + Q + 3 X + 1 (Q=12, C=15: 31 at vl=8; vl=16 does not fit beyond Q=2) | as B minus the PSUM load |
| D | No preload. Accumulators of a Q-pixel tile resident for ALL taps; one weight vector streamed per tap per tile and reused by the Q MACs (IISc's structure, but with replicated vector inputs) | Q acc + 2 W (double-buffered) + Q X + zero: Q=7 → 17, Q=11 → 25 / Q=6 → 30 | 1: W in slot 0, read 4–6 slots later through the register file; X 3 slots back; 4-pair convoys = the measured 4-tap shape. 2: stores only at the tile end, slots ≤ 5. 4. NEW, untested: write-after-read on W between early-cleared consecutive convoys (hence 2 W buffers) |
| F | D, but the pixel is a scalar operand of the MAC (`.vx`, as their layer 2): per tap `W | gap | MAC × q` | Q acc + 2 W + zero: 9 / 18 | 1: gap after the W load. Needs a NEW datapath: a controller-side input buffer that supplies each MAC slot's `I_RS1` (assumed cost-free in the model). The `.vx` MAC form has never been exercised by Coreless-V |

Rule 5, new (2026-11-16, from the cnn_demo check A.2): vl must be a multiple of 8. Otherwise slot j's writes to elements ≥ 8g are dropped unless j ≤ vl − 8g. Every option above runs at vl = 8 or 16 and meets it.

### 8.3 Projected layer-2 cycles against IISc's measured 175,674 (which includes the max-pool; ours do not)

| Option | vl | Q | P = 121 (11x11 conv) | P = 100 (10x10 the pooling reads) | P=100 / IISc |
|---|---|---|---|---|---|
| B | 8 | — | 361,935 | 299,523 | 1.705 |
| B | 16 | — | 277,577 | 229,739 | 1.308 |
| B9 | 8 | — | 367,743 | 304,323 | 1.732 |
| C | 8 | 12 | 376,263 | 310,755 | 1.769 |
| D | 8 | 11 | 320,647 | 269,923 | 1.536 |
| D | 16 | 6 | 279,621 | 231,601 | 1.318 |
| D, one W buffer, ReLU against scalar zero (2 untested assumptions) | 16 | 7 | 249,365 | 206,495 | 1.175 |
| F (new datapath) | 8 | 6 | 206,455 | 168,367 | 0.958 |
| F (new datapath) | 16 | 6 | 152,613 | 124,177 | 0.707 |

Reading:
- **Avoiding the spill is not the lever.** At vl=16 the spill costs about 2 cycles per pixel per chunk out of 71. C (no spill) is slower than B because it re-preloads per tile. D (no spill, no preload) matches B at the register-safe Q=6.
- **The lever is input replication.** Every MAC needs its own vector load of a replicated pixel value, so half the slots of a compute convoy are loads. Only F removes that, and only F projects below IISc's layer 2.
- **Pooling is not included in ours.** A pooled tile (Q = 4 = one window) costs more in D (319,969 at vl=16) because the per-tap convoys are short.

### 8.4 Recommendation

**Keep B for the chunked-tap RTL.**
- Stage 1 has now verified its only new mechanism (section 9).
- It needs no new datapath.
- Among the options without new hardware, it is within 1% of the best register-safe alternative (D, vl=16, Q=6: 231,601 vs 229,739).
- D is better only with two untested assumptions, and is still 1.18x IISc.

**Propose F as a separate design study, if the goal is to beat IISc's layer 2.** It needs its own approval: a controller-side input buffer feeding the MACs' scalar operand, the `.vx` MAC path tested on Coreless-V, and a cycle cost for the operand supply that the model sets to zero.

## 9. Stage 1 result: chunk-boundary convoy test (2026-11-16, MEASURED)

`testbench/convoy_chunk_tb.v`, `scripts/run_convoy_chunk.ps1`; `v_wrapper` alone, no RTL change.

**Test:**
- conv8_3's 9 taps are split into chunk 0 (taps 0–3) and chunk 1 (taps 4–8), for 3 pixels, run chunk-outer / pixel-inner, with weight-register reuse across the boundary.
- Every register is poisoned between the chunks, and the output rows before chunk 0.
- Runs at vl = 8 (both OC groups) and vl = 16, on both hex sets.

**Results** (RESULTS.md, "cnn_demo verification, layer-2 alternatives, chunk-boundary test (2026-11-16)", part D):
- 192/192 elements exact on each set, 0 stall cycles.
- With the partial-sum load removed: 0/72.
- Cycles equal the slot rule in every run: vl=8 106 / 113, vl=16 170 / 177. The section-4 constants gave 103 / 113 and 181 / 181.

## 10. Scalar-operand study ("F"), full cnn_demo (added 2026-11-17, task F)

Status: DESIGN NOTE ONLY. No RTL, nothing simulated. Every cycle count is a
PROJECTION from `scripts/cnn_schedule_model.py` (output
`docs/cnn_schedule_model_output.txt`), which costs explicit convoy lists with
the measured slot rule. Section 8 introduced F for layer 2 only; this section
works it out for the whole network and sets it next to schedule B, the one
task G builds.

### 10.1 What the core already offers

- **The scalar-operand MAC exists in the inherited ALU path.** With `ALUSrc = "01"`, operand 1 of a slot is that slot's own `RS1` (`exe_unit.vhd`, the `op1` case at lines 1488, 1506, 1541, 1579). `RS1` is part of the slot's instruction record, so one value is used for all vl elements. That is exactly `vmacc.vx`, the form their conv2d / layer2 / layer3 use.
- **The arithmetic is the same ALU** (`alu.vhd`: Q8.24 product `prod(55 downto 24)`, MAC = `op3 + prod_h`, kept to 32 bits). Which operand is the scalar does not change the product.
- **Coreless-V has never exercised it.** Every Coreless-V convoy so far uses `ALUSrc = "00"` (both operands from the VRF).

### 10.2 The missing piece: where the scalar comes from

The controller must know each pixel value when it issues the MAC.

| Source | Verdict |
|---|---|
| DMEM through the host port (`proc_*`) | Only while the vector unit is idle: `exe_unit.vhd:652` gives the host the DMEM ports only when `DONE_int = '1'`. Not usable during convoys. |
| A vector register via `Xout` / `vminmax` | Returns a reduction (max, min or index), not an arbitrary element. Not usable. |
| **A controller-side input buffer (IBUF)** | **Chosen.** A small block RAM in the controller holding the current layer's input, NOT replicated. It needs one read per issued MAC slot, i.e. at most one per cycle. The schedule is fixed, so the address of slot s+1 is known one cycle early, which hides the 1-cycle BRAM latency. |

IBUF size: the largest layer input is layer 2's, 13 × 13 × 16 = 2,704 words. That is 3 RAMB36 at 1K × 36.

How each layer's input reaches the IBUF:
- **Layer 1:** the host writes the 784-word image directly into the IBUF, instead of 12,544 replicated words in DMEM.
- **Layers 2 and 3:** each pooled output vector is stored ONCE, unit-stride, to DMEM. After the layer, the controller copies the result into the IBUF through the host port while the vector unit is idle: 2,704 and 800 words, about 1 word per cycle.
- **Rejected alternative:** snooping the vector unit's DMEM write bus would avoid the copy, but it needs a port out of `v_wrapper`, i.e. a vector-unit RTL change.

### 10.3 Schedule F (vl = 16)

Register map, two registers per vector, v0 never written:
- accumulators of one 2×2 window: v1/2, v3/4, v5/6, v7/8
- zero pair: v9/10
- the 9 weights of a chunk: v13–v30
- total 28 of 31; v11/12 spare.

Loop: per OC group, per chunk of 9 taps, preload the chunk's 9 weight vectors (3 convoys), then sweep the 2×2 windows. Per window and chunk, the instruction stream is:

```
L L L L                     bias (chunk 0) or partial sum into acc0..acc3   (slots 0-3)
M x (4 x taps)              vmacc.vx acc_j += RS1(pixel j, tap) * W(tap), acc order 0,1,2,3,0,1,...
non-final chunk:  S S S S   partial sums spilled in place
final chunk:      X X X X S max(a0,a1), max(a2,a3), max(a0,a2), max(a0,zero) = ReLU, store
```

This is packed 8 slots per convoy, with a store never in slot 7. A 9-tap window chunk is 44–45 slots, so 6 convoys of about 146 cycles.

- **FC (P = 1, no weight reuse):** weights are streamed, 4 per convoy (W in slots 0–3, MACs in slots 4–7, each 4 slots after its W); the accumulator stays resident for all 800 taps; ReLU + store in one extra convoy.
- **Argmax:** as in B.

### 10.4 Scheduling rules touched

| Rule | F |
|---|---|
| 1. No load directly before its reader | The four acc loads sit in slots 0–3; the first MAC on acc j is 4 slots later (register-file path, measured in the stage-1 test, section 9). The weights are resident (loaded in earlier convoys). FC: each MAC is 4 slots after its W load. |
| 2. No store in slot 7 | Enforced by the packing (a store that would fall in slot 7 moves to the next convoy). |
| 3. Unit-stride only | Yes. There is no replication at all, so there are no strided or broadcast accesses. |
| 4. Every slot occupied at vl > 8 | Unchanged (running no-ops). |
| 5. vl a multiple of 8 | vl = 16. |

**Untested assumptions** (each needs an isolated test before any RTL):
- **F-A1.** A MAC that reads its accumulator from the MAC 4 slots earlier (acc order 0,1,2,3,0,…) gets it through the register file. Only a LOAD result 4 slots back has been measured.
- **F-A2.** The `ALUSrc = "01"` MAC path, never run by Coreless-V.
- **F-A3.** IBUF prefetch at one value per issue cycle, including the slot-7 re-drive while waiting (slot 7's `RS1` must be re-driven unchanged).
- **F-A4.** The DMEM → IBUF copy through the host port at about 1 word per cycle (the read latency is 2 cycles, pipelined).

### 10.5 Projection (PROJECTED; convoy cycles from the slot rule; IISc MEASURED, RESULTS.md part B)

| Layer | IISc measured | B (built in G), model | F, model | F / IISc |
|---|---|---|---|---|
| Layer 1: conv 3×3, 16 filters, bias, ReLU, pool | 56,052 | 59,379 | 24,903 | 0.444 |
| Layer 2: conv 3×3×16, 32 filters, bias, ReLU, pool | 175,674 | 232,470 | 118,770 | 0.676 |
| Layer 3: FC 800 → 10 (padded to 16), bias, ReLU | 9,883 (incl. argmax) | 11,658 | 5,040 | 0.510 |
| Copies DMEM → IBUF | — | — | 3,504 (estimate) | |
| Total | 241,689 (incl. 80 overhead) | 303,507 | 152,217 | 0.630 |

B and F both exclude fixed per-layer overheads (descriptor fetch, initialisation, argmax read-back). For B these are measured in G.

Where F's gain comes from:
- **Layer 1:** B spends 3 convoys per pixel, half their slots on input loads, plus 3 replication convoys per pooled pixel (11,323 cycles). F has neither.
- **Layer 2:** the same input-load saving. Also, the 4 window accumulators share each preloaded weight.
- **FC:** B pays a 3-convoy weight preload per 9 taps for a single pixel. F streams 4 weights per convoy.

Memory: B keeps every layer input replicated 16x in DMEM (12,544 + 43,264 + 12,800 words). F keeps 784 / 2,704 / 800 words in the IBUF.

### 10.6 Cost estimate (ESTIMATE, not synthesis)

- **IBUF:** 3 RAMB36.
- **Controller logic:**
  - IBUF address generation: the pixel index of each MAC slot, ((oh + kh)·W + ow + kw)·IC + ic, kept as incremental counters;
  - the `RS1` path;
  - the copy engine;
  - the 4-accumulator window sequencing.
- It replaces B's strided-replication convoys and the replicated input address arithmetic.
- Rough figure: +150 to +300 LUT over the B controller G builds. That is small against IISc's 39,425-LUT control logic on Virtex-7 (RESULTS.md "Control logic, same subtraction method").

### 10.7 Recommendation

**F is the only schedule here that projects below IISc on every layer:** 0.44 / 0.68 / 0.51, 0.63 overall. Recommendation: make it the next build, after G is finished on schedule B, as the user's instruction requires (no switch mid-build).

Steps, each gated:
1. Isolated convoy tests on `v_wrapper` (new testbench): the `.vx` MAC at vl = 16 with poisoned registers (F-A2); the 4-accumulator window convoy with the 4-slot MAC→MAC dependency (F-A1).
2. IBUF + prefetch in a copy of the G controller; layer 1 against the same G1 gate (F-A3).
3. Copy engine (F-A4), then layers 2–3 against the G2 / G3 gates.
4. Re-measure, and compare with G's measured B numbers and IISc.
