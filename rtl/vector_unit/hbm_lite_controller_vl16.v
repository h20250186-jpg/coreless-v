`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: hbm_lite_controller_vl16
// NEW controller (2026-11-11). A copy of hbm_lite_controller.v (the live vl=8
// controller, unchanged) re-scheduled for vl = 16: ALL 16 output channels of a
// pixel are computed in one pass. It implements the schedule measured in
// isolation by testbench/convoy_vl16_tb.v (PIX / WL tests). The vector-unit RTL
// is not modified.
//
// vl = 16 on this core: a 16-element vector occupies TWO registers, elements
// 0..7 in vd and 8..15 in vd+1; both passes go through VRF / DMEM banks 0..7.
//
// Register map (two registers per vector, never v0):
//   activation[0] = 1 (ReLU path): inputs v1/2, v3/4, v5/6, v7/8; accumulator
//       v9/10; zero pair v11/12 (never written); tap t weights v(13+2t)/(14+2t)
//       -> at most 9 taps (v29/30).
//   activation[0] = 0: inputs v1/2, v3/4, v5/6; accumulator v7/8; tap t
//       weights v(9+2t)/(10+2t) -> at most 11 taps (v29/30).
//
// LIMITS, enforced: INPUT_C*KERNEL_H*KERNEL_W <= 9 with ReLU, <= 11 without;
// OUTPUT_C a non-zero multiple of 16. A layer outside these limits is not run:
// cfg_error is set and the layer finishes immediately (layer_done pulses).
//
// Memory layout (DMEM bank = addr[4:2], row = addr[18:5]; bases 32-byte aligned):
//   input  : each pixel REPLICATED 16 times (one 16-word vector = two DMEM
//            rows); addr = input_base + ((ic*H*W + ih*W + iw) << 6)
//   weight : OC-innermost   addr = weight_base + ((tap*OUTPUT_C + oc) << 2)
//   output : OC-innermost   addr = output_base + (((oh*OW + ow)*OUTPUT_C + oc) << 2)
//
// Convoys (EVERY one of the 8 slots is issued in every convoy; a slot with no
// real work holds a RUNNING NO-OP: start=1, no register / memory write):
//   WEIGHT : slot 0..n-1 load tap weights (n <= 3), rest no-ops
//   PIXEL, no ReLU, n = min(3, taps left):
//            slot 0..n-1 load v_x(j) | slot 3..3+n-1 MUL/MAC | slot 3+n store
//            (last convoy of the pixel only) | rest no-ops
//   PIXEL, ReLU: 4 taps per convoy (loads 0..3, MACs 4..7); the pixel's last
//            convoy takes 1 or 2 taps: loads, MACs from slot 3, ReLU, store
//            (9 taps -> 4 + 4 + 1, store in slot 5).
// Early clear (EARLY_CLEAR = 1): the bank is cleared 16 cycles after the last
// REAL slot was driven (vl = 16 elements), as in convoy_vl16_tb.v.
//
// SCHEDULING RULES of the inherited core and how this schedule obeys them:
//   1. No load directly before its reader: every MAC reads a load 3 slots
//      ahead (4 in the 4-tap convoy); the slot directly before a MAC is never
//      a load (it is a MAC, or a running no-op, which has dmr = 0).
//   2. No store from slot 7: the store sits in slot 3+n <= 6 (no ReLU) or
//      4+n <= 6 (ReLU, n <= 2 in the last convoy). Slot 7 always holds a MAC
//      (4-tap convoy) or a running no-op. Both have dmw = 0, so the crossbar's
//      unconditional slot-7 branch never drives a write enable. Rule 4 is
//      therefore met WITHOUT ever placing a store in slot 7.
//   3. Unit-stride loads only (mode_lsu = 00): no broadcast load.
//   4. Every slot occupied at vl > 8: all 8 slots are issued in every convoy,
//      and while waiting the controller re-drives slot 7's own instruction
//      instead of writing an idle (start=0) instruction into it.
//////////////////////////////////////////////////////////////////////////////////

module hbm_lite_controller_vl16 #(
    // 0: clear the instruction bank when the vector unit reports DONE.
    // 1: clear a fixed 16 cycles after the convoy's last REAL slot was driven.
    parameter EARLY_CLEAR = 1
) (
    input  wire        clk,
    input  wire        reset,

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

    input  wire        layer_start,
    output reg         layer_busy,
    output reg         layer_done,
    output reg         cfg_error,      // layer refused: outside the vl=16 limits

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

    input  wire        vec_stall,
    input  wire        vec_done,

    output reg  [31:0] proc_addr,
    output reg  [31:0] proc_din,
    output reg         proc_we,
    input  wire [31:0] proc_dout
);

    localparam [2:0]
        S_IDLE       = 3'd0,
        S_INIT       = 3'd1,
        S_INIT2      = 3'd2,
        S_ISSUE      = 3'd3,
        S_WAIT       = 3'd4,
        S_NEXT       = 3'd5,
        S_LAYER_DONE = 3'd6,
        S_DIV        = 3'd7;

    reg [2:0] state;

    localparam [1:0]
        PH_WEIGHT = 2'd0,
        PH_PIXEL  = 2'd1;

    reg [1:0] phase;

    localparam [8:0]  VEC_LEN = 9'd16;   // elements per instruction = OC group size
    localparam [15:0] OC_STEP = 16'd16;

    reg [15:0] oc_cnt, oh_cnt, ow_cnt, ic_cnt, kh_cnt, kw_cnt;
    reg [15:0] tap_idx, chunk_base;

    reg [15:0] output_h, output_w;
    reg [31:0] input_plane_size, kernel_size;
    reg [15:0] taps_total;

    // ---- register map (depends on activation, see header)
    wire       act    = activation[0];
    wire [4:0] r_x0   = 5'd1;
    wire [4:0] r_acc  = act ? 5'd9  : 5'd7;
    wire [4:0] r_zero = 5'd11;
    wire [4:0] r_w0   = act ? 5'd13 : 5'd9;
    wire [15:0] max_taps = act ? 16'd9 : 16'd11;

    // ---- addresses (combinational)
    wire [31:0] comb_input_addr  = input_base
                                   + ((ic_cnt * input_plane_size
                                       + (oh_cnt * stride[15:0] + kh_cnt) * input_w
                                       + (ow_cnt * stride[15:0] + kw_cnt)) << 6);   // 16-word replication
    wire [31:0] comb_weight_addr = weight_base + ((tap_idx * output_c[15:0] + oc_cnt) << 2);
    wire [31:0] comb_output_addr = output_base
                                   + (((oh_cnt * output_w + ow_cnt) * output_c[15:0] + oc_cnt) << 2);

    // ---- taps of the current convoy (same chunking as the vl=8 controller)
    wire        fuse       = act && (phase == PH_PIXEL);
    wire [15:0] taps_left  = taps_total - chunk_base;
    wire [2:0]  n_taps     = !fuse ? ((taps_left >= 16'd3) ? 3'd3 : taps_left[2:0]) :
                             (taps_left <= 16'd2) ? taps_left[2:0] :
                             (taps_left == 16'd3) ? 3'd2 :
                             (taps_left == 16'd4) ? 3'd3 : 3'd4;
    wire        last_chunk = (chunk_base + n_taps == taps_total);

    wire last_pixel = (ow_cnt == output_w - 16'd1) && (oh_cnt == output_h - 16'd1);
    wire last_group = (oc_cnt + OC_STEP >= output_c[15:0]);

    wire [2:0] mac_base   = (n_taps == 3'd4) ? 3'd4 : 3'd3;
    wire [3:0] mac_end    = {1'b0, mac_base} + {1'b0, n_taps};
    wire [3:0] relu_slot  = mac_end;
    wire [3:0] store_slot = act ? mac_end + 4'd1 : mac_end;            // <= 6
    // last slot doing REAL work (everything after it is a running no-op)
    wire [3:0] real_last  = (phase == PH_WEIGHT) ? {1'b0, n_taps} - 4'd1 :
                            last_chunk           ? store_slot :
                                                   mac_end - 4'd1;
    // clear 16 cycles after the last real slot: slot 7 is issued (7 - real_last)
    // cycles after it, S_WAIT starts the cycle after slot 7, so wait_cnt == 8 + real_last
    wire [4:0] clr_at     = 5'd8 + {1'b0, real_last};

    // ---- limit check, evaluated in S_INIT2 (kernel_size has settled)
    wire [15:0] taps_now  = input_c[15:0] * kernel_size[15:0];
    wire        bad_cfg   = (taps_now == 16'd0) || (taps_now > max_taps) ||
                            (output_c[15:0] == 16'd0) || (output_c[3:0] != 4'd0);

    reg [2:0] issue_cnt;
    reg       seen_busy;
    reg [4:0] wait_cnt;

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

    // Idle write (outside convoys): start=0 into slot 7, as in the vl=8 controller.
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

    // Drive convoy slot s. Every slot is occupied: the default is a running
    // no-op (start=1, no register or memory write).
    task drive_slot(input [2:0] s);
    begin
        vec_id    <= s;
        vec_start <= 1'b1;
        if (phase == PH_WEIGHT) begin
            if (s < n_taps) begin                       // tap weights -> its register pair
                vec_vd      <= r_w0 + {tap_idx[3:0], 1'b0};
                vec_RS1     <= comb_weight_addr;
                vec_dmr     <= 1'b1;
                vec_reg_we  <= 1'b1;
                vec_mem_reg <= 1'b1;
                advance_tap;
            end
        end else if (s < n_taps) begin                  // input vector of the tap
            vec_vd      <= r_x0 + {1'b0, s, 1'b0};
            vec_RS1     <= comb_input_addr;
            vec_dmr     <= 1'b1;
            vec_reg_we  <= 1'b1;
            vec_mem_reg <= 1'b1;
            advance_tap;
        end else if (s >= mac_base && {1'b0, s} < mac_end) begin        // MUL (tap 0) / MAC
            vec_vs1    <= r_x0 + {1'b0, s - mac_base, 1'b0};
            vec_vs2    <= r_w0 + {chunk_base[3:0] + {1'b0, s - mac_base}, 1'b0};
            vec_vd     <= r_acc;
            vec_funct  <= (chunk_base == 16'd0 && s == mac_base) ? 8'b00000010 : 8'b00000011;
            vec_reg_we <= 1'b1;
        end else if (last_chunk && act && {1'b0, s} == relu_slot) begin   // ReLU
            vec_vs1    <= r_acc;
            vec_vs2    <= r_zero;
            vec_vd     <= r_acc;
            vec_funct  <= 8'b00000101;
            vec_reg_we <= 1'b1;
        end else if (last_chunk && {1'b0, s} == store_slot) begin         // store
            vec_vd     <= r_acc;
            vec_RS1    <= comb_output_addr;
            vec_dmw    <= 1'b1;
        end
        // otherwise: running no-op
    end
    endtask

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
            oc_cnt <= oc_cnt + OC_STEP;
            phase  <= PH_WEIGHT;
            if (last_group)
                state <= S_LAYER_DONE;
        end
    end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            phase            <= PH_WEIGHT;
            layer_busy       <= 1'b0;
            layer_done       <= 1'b0;
            cfg_error        <= 1'b0;
            oc_cnt           <= 16'd0;
            oh_cnt           <= 16'd0;
            ow_cnt           <= 16'd0;
            ic_cnt           <= 16'd0;
            kh_cnt           <= 16'd0;
            kw_cnt           <= 16'd0;
            tap_idx          <= 16'd0;
            chunk_base       <= 16'd0;
            output_h         <= 16'd0;
            output_w         <= 16'd0;
            input_plane_size <= 32'd0;
            kernel_size      <= 32'd0;
            taps_total       <= 16'd0;
            issue_cnt        <= 3'd0;
            seen_busy        <= 1'b0;
            wait_cnt         <= 5'd0;
            vec_vl           <= VEC_LEN;
            vec_quant        <= 2'b00;
            set_vec_idle;
        end else begin
            set_vec_idle;
            layer_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    layer_busy <= 1'b0;
                    if (layer_start) begin
                        layer_busy <= 1'b1;
                        cfg_error  <= 1'b0;
                        state      <= S_INIT;
                    end
                end

                S_INIT: begin
                    input_plane_size <= input_h * input_w;
                    kernel_size      <= kernel_h * kernel_w;
                    oc_cnt <= 16'd0;
                    oh_cnt <= 16'd0;
                    ow_cnt <= 16'd0;
                    restart_taps;
                    vec_quant <= q_format;
                    vec_vl    <= VEC_LEN;
                    vec_clear <= 1'b1;
                    phase     <= PH_WEIGHT;
                    state     <= S_DIV;
                end

                S_DIV: begin
                    if (div_last)
                        state <= S_INIT2;
                end

                S_INIT2: begin
                    output_h   <= div_out_h;
                    output_w   <= div_out_w;
                    taps_total <= taps_now;
                    issue_cnt  <= 3'd0;
                    seen_busy  <= 1'b0;
                    if (bad_cfg) begin
                        cfg_error <= 1'b1;            // outside the vl=16 limits: not run
                        state     <= S_LAYER_DONE;
                    end else
                        state     <= S_ISSUE;
                end

                // all 8 slots, one per cycle
                S_ISSUE: begin
                    drive_slot(issue_cnt);
                    wait_cnt <= 5'd0;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                    if (issue_cnt == 3'd7)
                        state <= S_WAIT;
                    else
                        issue_cnt <= issue_cnt + 3'd1;
                end

                // slot 7 stays occupied: re-drive its own instruction
                S_WAIT: begin
                    drive_slot(3'd7);
                    wait_cnt <= wait_cnt + 5'd1;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                    if (EARLY_CLEAR ? (wait_cnt == clr_at) : (seen_busy && vec_done)) begin
                        vec_clear <= 1'b1;            // same cycle as slot 7's re-drive, as in convoy_vl16_tb
                        state     <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    issue_cnt <= 3'd0;
                    seen_busy <= 1'b0;
                    state     <= S_ISSUE;
                    if (phase == PH_WEIGHT) begin
                        chunk_base <= tap_idx;
                        if (last_chunk) begin
                            restart_taps;
                            phase <= PH_PIXEL;
                        end
                    end else begin
                        if (!last_chunk)
                            chunk_base <= tap_idx;
                        else
                            advance_pixel;
                    end
                end

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
