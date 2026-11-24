`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: hbm_lite_controller
// Description: Autonomous convolution FSM for ATEE. Reads CNN layer parameters
//              from tensor_config_regs, generates all loop addresses, and drives
//              the v_wrapper (vector execution unit) control signals directly —
//              eliminating instruction decode overhead.
//
// The vector unit is a convoy machine: 8 instruction slots, each sweeping vl
// elements one per cycle, slot j issued j cycles after slot 0. This controller
// vectorizes over OUTPUT CHANNEL with vl=8: one vector = 8 consecutive output
// channels (OUTPUT_C must be a multiple of 8).
//
// MULTI-MAC version: up to three kernel taps are accumulated per convoy.
// (The one-tap-per-convoy version is frozen in
//  archive/step5_output_stationary/hbm_lite_controller_os.v.)
//
// Execution flow:
//   IDLE → INIT → INIT2 → ISSUE (one slot per cycle) → WAIT → NEXT →
//   ISSUE → ... → LAYER_DONE
//
// Per OC group (8 output channels):
//   WEIGHT phase: every tap's 8 weights are loaded into its own register
//     v16+tap, three loads per convoy (slots 0,1,2). They stay there for all
//     output pixels of the group. Limit: INPUT_C*KERNEL_H*KERNEL_W <= 16.
//   PIXEL phase without activation, taps taken n = up to 3 at a time:
//     slot 0..n-1    load  v(1+j)  <- input row of tap j   (unit-stride)
//     slot n..2      (empty when n < 3)
//     slot 3..3+n-1  MAC   v_acc += v(1+j) * v(16+tap)     (MUL on tap 0)
//     slot 3+n       store v_acc -> output   (last convoy of the pixel only)
//   PIXEL phase with activation[0] (ReLU): taps taken 4 at a time,
//     slot 0..3      load  v1..v4
//     slot 4..7      MAC   (each reads the load 4 slots ahead, register file)
//   leaving 1 or 2 taps for the pixel's last convoy, which is fused:
//     slot 0..n-1    load
//     slot 3..3+n-1  MAC
//     slot 3+n       ReLU  v_acc = max(v_acc, 0)
//     slot 4+n       store v_acc -> output
//   (9 taps -> 4 + 4 + 1, store in slot 5: verified. A 2-tap fused convoy,
//    store in slot 6, and the chunkings other tap counts produce are NOT
//    exercised by conv8_3.)
//
// Scheduling rules this layout obeys (both are limitations of the inherited
// exe_unit.vhd / dmem_addr_xbar.vhd core, see CLAUDE.md):
//   1. No load sits directly ahead of the instruction that reads it: every
//      MAC reads the load 3 or 4 slots ahead.
//   2. No store in slot 7: the store is in slot 6 at most.
//
// Convolution loop order (output-stationary, 8 output channels at a time):
//   for (ocg = 0; ocg < OUTPUT_C; ocg += 8)
//     for (oh = 0; oh < OUTPUT_H; oh++)
//       for (ow = 0; ow < OUTPUT_W; ow++)
//         for (ic = 0; ic < INPUT_C; ic++)
//           for (kh = 0; kh < KERNEL_H; kh++)
//             for (kw = 0; kw < KERNEL_W; kw++)
//               acc[0..7] += input[ic][oh*S+kh][ow*S+kw] * weight[ic][kh][kw][ocg+0..7]
//
// Memory layout (DMEM bank = addr[4:2], row = addr[18:5]; all bases must be
// 32-byte aligned so element e of every vector lands in bank e):
//   input  : each pixel REPLICATED across the 8 banks of its own row
//            addr = input_base  + ((ic*H*W + ih*W + iw) << 5)
//   weight : OC-innermost   addr = weight_base + ((tap*OUTPUT_C + oc) << 2)
//            tap = (ic*KH + kh)*KW + kw
//   output : OC-innermost   addr = output_base + (((oh*OW + ow)*OUTPUT_C + oc) << 2)
//
// Address generation is COMBINATIONAL (wire) to avoid 1-cycle stale bugs.
// S_INIT is split into 2 cycles so output_h/w are settled before use.
//////////////////////////////////////////////////////////////////////////////////

module hbm_lite_controller #(
    // 0: clear the instruction bank when the vector unit reports DONE.
    // 1: clear a fixed 8 cycles after the convoy's last slot was driven (the
    //    last slot has then issued all 8 elements; the pipeline drains while
    //    the next convoy is already being issued).
    parameter EARLY_CLEAR = 1
) (
    input  wire        clk,
    input  wire        reset,

    // Configuration inputs (from tensor_config_regs)
    input  wire [31:0] input_h,
    input  wire [31:0] input_w,
    input  wire [31:0] input_c,
    input  wire [31:0] kernel_h,
    input  wire [31:0] kernel_w,
    input  wire [31:0] output_c,
    input  wire [31:0] stride,
    input  wire [31:0] padding,
    input  wire [31:0] pool_size,
    input  wire [1:0]  q_format,
    input  wire [31:0] activation,
    input  wire [31:0] input_base,
    input  wire [31:0] weight_base,
    input  wire [31:0] output_base,

    // Layer control
    input  wire        layer_start,
    output reg         layer_busy,
    output reg         layer_done,

    // v_wrapper control signals (active during autonomous execution)
    output reg         vec_start,
    output reg  [2:0]  vec_id,
    output reg  [8:0]  vec_vl,
    output reg  [1:0]  vec_quant,
    output reg         vec_clear,
    output reg  [4:0]  vec_vs1,
    output reg  [4:0]  vec_vs2,
    output reg  [4:0]  vec_vd,
    output reg  [31:0] vec_RS1,
    output reg  [31:0] vec_RS2,
    output reg  [4:0]  vec_uimm5,
    output reg  [7:0]  vec_funct,
    output reg  [1:0]  vec_permute,
    output reg         vec_mask_en,
    output reg  [1:0]  vec_ALUSrc,
    output reg         vec_dmr,
    output reg         vec_dmw,
    output reg         vec_reg_we,
    output reg         vec_mem_reg,
    output reg         vec_Xout,
    output reg  [1:0]  vec_mode_lsu,

    // v_wrapper status inputs
    input  wire        vec_stall,
    input  wire        vec_done,

    // Processor memory interface (for loading/storing data to DMEM)
    output reg  [31:0] proc_addr,
    output reg  [31:0] proc_din,
    output reg         proc_we,
    input  wire [31:0] proc_dout
);

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [2:0]
        S_IDLE       = 3'd0,
        S_INIT       = 3'd1,
        S_INIT2      = 3'd2,    // 2nd init cycle: compute derived dimensions
        S_ISSUE      = 3'd3,    // drive convoy slot issue_cnt, one slot per cycle
        S_WAIT       = 3'd4,    // let the convoy finish, then clear the bank
        S_NEXT       = 3'd5,    // advance loop counters (vec_clear is on the wires)
        S_LAYER_DONE = 3'd6,
        S_DIV        = 3'd7;    // 16 cycles: sequential (.. / stride) for output_h and output_w

    reg [2:0] state;

    // Convoy kind
    localparam [1:0]
        PH_WEIGHT = 2'd0,       // preload tap weights into v16+tap
        PH_PIXEL  = 2'd1;       // input loads + MACs (+ ReLU) (+ store)

    reg [1:0] phase;

    localparam [8:0] VEC_LEN = 9'd8;   // elements per instruction = OC group size

    // =========================================================================
    // Loop counters
    // =========================================================================
    reg [15:0] oc_cnt;   // First output channel of the current group (steps by 8)
    reg [15:0] oh_cnt;   // Output height counter
    reg [15:0] ow_cnt;   // Output width counter
    reg [15:0] ic_cnt;   // Input channel of the next tap to issue
    reg [15:0] kh_cnt;   // Kernel row of the next tap to issue
    reg [15:0] kw_cnt;   // Kernel column of the next tap to issue
    reg [15:0] tap_idx;     // Index of the next tap to issue: (ic*KH + kh)*KW + kw
    reg [15:0] chunk_base;  // tap_idx of slot 0 of the current convoy

    // =========================================================================
    // Derived dimensions (computed during INIT/INIT2, stable afterwards)
    // =========================================================================
    reg [15:0] output_h;          // computed in S_INIT
    reg [15:0] output_w;          // computed in S_INIT
    reg [31:0] input_plane_size;  // computed in S_INIT
    reg [31:0] kernel_size;       // computed in S_INIT
    reg [15:0] taps_total;        // computed in S_INIT2: INPUT_C * KH * KW

    // =========================================================================
    // COMBINATIONAL address computation
    // These wires are valid in the same cycle they're used by vec_RS1.
    // =========================================================================
    wire [31:0] comb_input_addr;
    wire [31:0] comb_weight_addr;
    wire [31:0] comb_output_addr;

    // Input: <<5 because each pixel owns a full 8-word row (replicated).
    assign comb_input_addr = input_base
                             + ((ic_cnt * input_plane_size
                                 + (oh_cnt * stride[15:0] + kh_cnt) * input_w
                                 + (ow_cnt * stride[15:0] + kw_cnt)) << 5);

    // Weights / outputs: natural word addressing, OC is the fastest index.
    assign comb_weight_addr = weight_base
                              + ((tap_idx * output_c[15:0] + oc_cnt) << 2);

    assign comb_output_addr = output_base
                              + (((oh_cnt * output_w + ow_cnt) * output_c[15:0]
                                  + oc_cnt) << 2);

    // Taps handled by the current convoy.
    //   Weight phase, and pixel phase without activation: n = min(3, left).
    //   Pixel phase WITH activation: 4 at a time, but the pixel's last convoy
    //   must keep room for ReLU + store below slot 7, so it takes at most 2
    //   taps (left = 4 -> 3 now, 1 later; left = 3 -> 2 now, 1 later).
    wire        act        = activation[0];
    wire        fuse       = act && (phase == PH_PIXEL);
    wire [15:0] taps_left  = taps_total - chunk_base;
    wire [2:0]  n_taps     = !fuse ? ((taps_left >= 16'd3) ? 3'd3 : taps_left[2:0]) :
                             (taps_left <= 16'd2) ? taps_left[2:0] :
                             (taps_left == 16'd3) ? 3'd2 :
                             (taps_left == 16'd4) ? 3'd3 : 3'd4;
    wire        last_chunk = (chunk_base + n_taps == taps_total);

    wire last_pixel = (ow_cnt == output_w - 16'd1) &&
                      (oh_cnt == output_h - 16'd1);
    wire last_group = (oc_cnt + 16'd8 >= output_c[15:0]);

    // MACs start at slot 3 (each reads the load 3 slots ahead, by forwarding)
    // or, for a 4-tap convoy, at slot 4 (4 slots ahead, via the register file).
    // mac_end is 4 bits: a 4-tap convoy has MACs in slots 4..7, so the slot
    // after the last MAC is 8 and does not fit in a 3-bit slot number.
    wire [2:0] mac_base   = (n_taps == 3'd4) ? 3'd4 : 3'd3;
    wire [3:0] mac_end    = {1'b0, mac_base} + {1'b0, n_taps};    // first slot after the MACs
    wire [3:0] relu_slot  = mac_end;                      // last convoy, activation only
    wire [3:0] store_slot = act ? mac_end + 4'd1 : mac_end;       // last convoy: <= 6, never 7
    wire [3:0] last_slot4 = (phase == PH_WEIGHT) ? {1'b0, n_taps} - 4'd1 :
                            last_chunk           ? store_slot :
                                                   mac_end - 4'd1;
    wire [2:0] last_slot  = last_slot4[2:0];

    reg [2:0] issue_cnt;   // Slot being issued this cycle
    reg       seen_busy;   // Set when vec_done goes low (convoy started)
    reg [2:0] wait_cnt;    // Cycles spent in S_WAIT (EARLY_CLEAR only)

    // Output size = (input + 2*padding - kernel) / stride + 1, computed once
    // per layer by a 16-cycle shift-subtract divider (started in S_INIT).
    wire [15:0] div_out_h, div_out_w;
    wire        div_busy, div_last;
    outsize_div u_outsize (
        .clk      (clk),
        .reset    (reset),
        .start    (state == S_INIT),
        .input_h  (input_h[15:0]),
        .input_w  (input_w[15:0]),
        .padding  (padding[14:0]),
        .kernel_h (kernel_h[15:0]),
        .kernel_w (kernel_w[15:0]),
        .stride   (stride[15:0]),
        .out_h    (div_out_h),
        .out_w    (div_out_w),
        .busy     (div_busy),
        .last     (div_last)
    );

    // VRF register allocation. Never v0: forwarding is disabled for vd=0.
    localparam [4:0] VR_X0    = 5'd1;    // v1..v3: input rows of the convoy's taps
    localparam [4:0] VR_ACCUM = 5'd8;
    localparam [4:0] VR_ZERO  = 5'd12;   // never written: zero for ReLU max(0,x)
    localparam [4:0] VR_W0    = 5'd16;   // v16+tap: weights of each tap

    // =========================================================================
    // Default all v_wrapper outputs to inactive.
    // The instruction bank has no write enable: the slot selected by vec_id is
    // overwritten EVERY cycle. Idle cycles therefore point at slot 7, which is
    // empty in every convoy except the 4-tap one; S_WAIT handles that case by
    // re-driving slot 7's own instruction instead of idling.
    // =========================================================================
    task set_vec_idle;
    begin
        vec_start    <= 1'b0;
        vec_id       <= 3'd7;
        vec_clear    <= 1'b0;
        vec_vs1      <= 5'd0;
        vec_vs2      <= 5'd0;
        vec_vd       <= 5'd0;
        vec_RS1      <= 32'd0;
        vec_RS2      <= 32'd0;
        vec_uimm5    <= 5'd0;
        vec_funct    <= 8'd0;
        vec_permute  <= 2'd0;
        vec_mask_en  <= 1'b0;
        vec_ALUSrc   <= 2'b00;
        vec_dmr      <= 1'b0;
        vec_dmw      <= 1'b0;
        vec_reg_we   <= 1'b0;
        vec_mem_reg  <= 1'b0;
        vec_Xout     <= 1'b0;
        vec_mode_lsu <= 2'b00;
        proc_addr    <= 32'd0;
        proc_din     <= 32'd0;
        proc_we      <= 1'b0;
    end
    endtask

    // Step the tap counters kw → kh → ic and the flat tap index
    task advance_tap;
    begin
        tap_idx <= tap_idx + 16'd1;
        if (kw_cnt < kernel_w[15:0] - 16'd1) begin
            kw_cnt <= kw_cnt + 16'd1;
        end else begin
            kw_cnt <= 16'd0;
            if (kh_cnt < kernel_h[15:0] - 16'd1) begin
                kh_cnt <= kh_cnt + 16'd1;
            end else begin
                kh_cnt <= 16'd0;
                ic_cnt <= ic_cnt + 16'd1;
            end
        end
    end
    endtask

    task restart_taps;
    begin
        tap_idx    <= 16'd0;
        chunk_base <= 16'd0;
        ic_cnt     <= 16'd0;
        kh_cnt     <= 16'd0;
        kw_cnt     <= 16'd0;
    end
    endtask

    // =========================================================================
    // Drive the instruction for convoy slot s (call after set_vec_idle)
    // =========================================================================
    task drive_slot(input [2:0] s);
    begin
        vec_id <= s;
        if (phase == PH_WEIGHT) begin
            // load the 8 weights of tap tap_idx into its register
            vec_start    <= 1'b1;
            vec_vd       <= VR_W0 + tap_idx[4:0];
            vec_RS1      <= comb_weight_addr;
            vec_dmr      <= 1'b1;
            vec_reg_we   <= 1'b1;
            vec_mem_reg  <= 1'b1;
            advance_tap;
        end else if (s < n_taps) begin          // load input row of tap tap_idx
            vec_start    <= 1'b1;
            vec_vd       <= VR_X0 + {2'b00, s};
            vec_RS1      <= comb_input_addr;
            vec_dmr      <= 1'b1;
            vec_reg_we   <= 1'b1;
            vec_mem_reg  <= 1'b1;
            advance_tap;
        end else if (s >= mac_base && {1'b0, s} < mac_end) begin   // MUL (tap 0) / MAC
            vec_start    <= 1'b1;
            vec_vs1      <= VR_X0 + {2'b00, s - mac_base};
            vec_vs2      <= VR_W0 + chunk_base[4:0] + {2'b00, s - mac_base};
            vec_vd       <= VR_ACCUM;
            vec_funct    <= (chunk_base == 16'd0 && s == mac_base) ? 8'b00000010 : 8'b00000011;
            vec_reg_we   <= 1'b1;
        end else if (last_chunk && act && {1'b0, s} == relu_slot) begin   // ReLU, fused
            vec_start    <= 1'b1;
            vec_vs1      <= VR_ACCUM;
            vec_vs2      <= VR_ZERO;
            vec_vd       <= VR_ACCUM;
            vec_funct    <= 8'b00000101;
            vec_reg_we   <= 1'b1;
        end else if (last_chunk && {1'b0, s} == store_slot) begin         // store accumulator
            vec_start    <= 1'b1;
            vec_vd       <= VR_ACCUM;
            vec_RS1      <= comb_output_addr;
            vec_dmw      <= 1'b1;
        end
        // otherwise: slot left empty (start=0)
    end
    endtask

    // Output pixel finished: next pixel, next OC group, or done
    task advance_pixel;
    begin
        restart_taps;
        phase <= PH_PIXEL;
        if (!last_pixel) begin
            if (ow_cnt < output_w - 16'd1) begin
                ow_cnt <= ow_cnt + 16'd1;
            end else begin
                ow_cnt <= 16'd0;
                oh_cnt <= oh_cnt + 16'd1;
            end
        end else begin
            ow_cnt <= 16'd0;
            oh_cnt <= 16'd0;
            oc_cnt <= oc_cnt + 16'd8;
            phase  <= PH_WEIGHT;
            if (last_group)
                state <= S_LAYER_DONE;
        end
    end
    endtask

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk) begin
        if (reset) begin
            state             <= S_IDLE;
            phase             <= PH_WEIGHT;
            layer_busy        <= 1'b0;
            layer_done        <= 1'b0;
            oc_cnt            <= 16'd0;
            oh_cnt            <= 16'd0;
            ow_cnt            <= 16'd0;
            ic_cnt            <= 16'd0;
            kh_cnt            <= 16'd0;
            kw_cnt            <= 16'd0;
            tap_idx           <= 16'd0;
            chunk_base        <= 16'd0;
            output_h          <= 16'd0;
            output_w          <= 16'd0;
            input_plane_size  <= 32'd0;
            kernel_size       <= 32'd0;
            taps_total        <= 16'd0;
            issue_cnt         <= 3'd0;
            seen_busy         <= 1'b0;
            wait_cnt          <= 3'd0;
            vec_vl            <= VEC_LEN;
            vec_quant         <= 2'b00;
            set_vec_idle;
        end else begin
            // Defaults each cycle
            set_vec_idle;
            layer_done <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    layer_busy <= 1'b0;
                    if (layer_start) begin
                        layer_busy <= 1'b1;
                        state      <= S_INIT;
                    end
                end

                // ---------------------------------------------------------
                // INIT cycle 1: compute output dimensions + base sizes
                S_INIT: begin
                    // output_h / output_w: u_outsize starts on this cycle
                    input_plane_size <= input_h * input_w;
                    kernel_size      <= kernel_h * kernel_w;

                    oc_cnt <= 16'd0;
                    oh_cnt <= 16'd0;
                    ow_cnt <= 16'd0;
                    restart_taps;

                    vec_quant  <= q_format;
                    vec_vl     <= VEC_LEN;
                    vec_clear  <= 1'b1;
                    phase      <= PH_WEIGHT;
                    state      <= S_DIV;
                end

                // ---------------------------------------------------------
                // 16 cycles while u_outsize divides by stride
                S_DIV: begin
                    if (div_last)
                        state <= S_INIT2;
                end

                // ---------------------------------------------------------
                // INIT cycle 2: kernel_size has settled
                S_INIT2: begin
                    output_h   <= div_out_h;
                    output_w   <= div_out_w;
                    taps_total <= input_c[15:0] * kernel_size[15:0];
                    issue_cnt  <= 3'd0;
                    seen_busy  <= 1'b0;
                    state      <= S_ISSUE;
                end

                // ---------------------------------------------------------
                // Issue one convoy slot per cycle
                S_ISSUE: begin
                    drive_slot(issue_cnt);
                    wait_cnt <= 3'd0;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                    if (issue_cnt == last_slot)
                        state <= S_WAIT;
                    else
                        issue_cnt <= issue_cnt + 3'd1;
                end

                // ---------------------------------------------------------
                // Convoy is running (outputs idle on slot 7). Clear the
                // instruction bank when it has finished.
                S_WAIT: begin
                    // A 4-tap convoy has a MAC in slot 7, so the idle write
                    // must not land there: keep re-driving that same MAC
                    // (its fields do not depend on the advancing tap counters).
                    if (last_slot == 3'd7)
                        drive_slot(3'd7);
                    wait_cnt <= wait_cnt + 3'd1;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                    if (EARLY_CLEAR ? (wait_cnt == 3'd7) : (seen_busy && vec_done)) begin
                        vec_clear <= 1'b1;
                        state     <= S_NEXT;
                    end
                end

                // ---------------------------------------------------------
                // Advance: next chunk of taps, next phase, next pixel
                S_NEXT: begin
                    issue_cnt <= 3'd0;
                    seen_busy <= 1'b0;
                    state     <= S_ISSUE;

                    if (phase == PH_WEIGHT) begin
                        chunk_base <= tap_idx;
                        if (last_chunk) begin
                            // All tap weights are in v16.. : start the pixels
                            restart_taps;
                            phase <= PH_PIXEL;
                        end
                    end else begin
                        if (!last_chunk)
                            chunk_base <= tap_idx;
                        else
                            advance_pixel;       // [ReLU +] store rode in the last convoy
                    end
                end

                // ---------------------------------------------------------
                S_LAYER_DONE: begin
                    layer_busy <= 1'b0;
                    layer_done <= 1'b1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
