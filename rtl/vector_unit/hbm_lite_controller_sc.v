`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: hbm_lite_controller_sc
// NEW controller (2026-11-17, scalar-operand variant "F",
// docs/chunked_taps_design.md section 10). Runs single conv layers or a whole
// CNN (cnn_demo) from ONE start, at vl = 16, WITHOUT input replication: the
// input value is the MAC's SCALAR operand (vmacc.vx: ALUSrc = "01", operand 1 =
// the slot's RS1), read from a controller-side input buffer (IBUF, ibuf_ram.v).
// hbm_lite_controller_cnn.v (schedule B) and every other controller, and the
// vector-unit RTL, are NOT modified.
//
// ---- Layer descriptors: as hbm_lite_controller_cnn.v (13 words per layer at
// desc_base + 64*layer):
//   w0 H  w1 W  w2 IC  w3 K (square, stride 1, no padding)  w4 OC (mult. of 16)
//   w5 flags: [0] ReLU  [1] 2x2 max-pool  [3] argmax  [5:4] Q format
//             [6] COPY: before the layer, copy H*W*IC words from DMEM (w6) into
//                 the IBUF (the previous layer's output). Without it the IBUF
//                 already holds the input (written by the host).
//   w6 input base (DMEM, COPY only)  w7 weight base  w8 bias base
//   w9 partial-sum base  w10 output base  w11 argmax length  w12 class address
//
// ---- Layouts (byte addresses):
//   IBUF   : index ((ih*W + iw)*IC + ic), plain (no replication), <= 4,096 words
//   weight : wt + ((tap*OC + oc) << 2), tap = (kh*K + kw)*IC + ic
//   bias   : bias + (oc << 2)
//   psum   : psum + ((win*4 + j) << 6)       (16 words per accumulator)
//   output : pool    : out + ((win*OC + oc) << 2)   (win = pooled pixel)
//            no pool : out + ((pix*OC + oc) << 2)   (pix = output pixel)
//   (= the IBUF layout of the next layer)
//
// ---- Register map (two registers per vl=16 vector, v0 never written):
//   acc j = v(1+2j), j = 0..3 | zero v9/10 (never written) | weight of
//   chunk tap t = v(13+2t), t = 0..8
//
// ---- Schedule (window mode, any layer with more than one output pixel):
//   per OC group (16 channels), per chunk of <= 9 taps:
//     PRELOAD: the chunk's weight vectors, 3 per convoy (slots 0..2); the IBUF
//              offset of every tap ((kh*W + kw)*IC + ic) is recorded
//     per WINDOW of 4 output pixels (pool: the 2x2 window; no pool: 4
//     consecutive pixels in raster order), the op stream
//        L x4                 acc j <- bias (chunk 0) or its partial sum
//        MACX x 4*taps        acc j += RS1(pixel j, tap t) * W_t, acc order
//                             0,1,2,3 per tap (each MAC 4 slots after the
//                             previous one on the same acc)
//        non-final chunk : S x4 (partial sums)
//        final, pool     : max(a0,a1) max(a2,a3) max(a0,a2) [max(a0,0)] S
//        final, no pool  : [max(aj,0) x4] S x4
//     packed 8 slots per convoy, window-aligned, a store never in slot 7
//     (it moves to the next convoy) = scripts/cnn_schedule_model.py pack().
//   Stream mode (one output pixel, e.g. FC as a 1x1 conv): per OC group,
//     [L bias | W W W | MACX x3 | -], [W x n | MACX x n] (n <= 4, each MAC 4
//     slots after its W), [max(acc,0) | S] (no ReLU: [S]).
//   IBUF read: the pixel of the MAC in slot s is addressed while slot s-1 is
//     issued (S_NEXT for slot 0), so it is registered into RS1 on time.
//   Argmax: as hbm_lite_controller_cnn.v.
//
// ---- Scheduling rules of the inherited core:
//   1. No load directly before its reader: weight loads 3-4 slots before
//      their MAC (stream) or in earlier convoys; acc loads 4 slots before.
//   2. No store in slot 7 (packing rule).
//   3. Unit-stride only; no strided or broadcast access at all.
//   4. All 8 slots issued (running no-ops), slot 7 re-driven unchanged
//      (incl. RS1) while waiting.
//   5. vl = 16.
//   Measured on v_wrapper alone: testbench/convoy_scalar_tb.v.
// Early clear 16 cycles after the last real slot (slot rule: last + 18).
// Limits (cfg_error): OC a multiple of 16; H*W*IC <= 4,096 (IBUF); no pool:
// output pixels a multiple of 4 unless exactly 1 (stream).
//////////////////////////////////////////////////////////////////////////////////

module hbm_lite_controller_sc (
    input  wire        clk,
    input  wire        reset,

    input  wire [31:0] desc_base,
    input  wire [3:0]  n_layers,

    input  wire        layer_start,
    output reg         layer_busy,
    output reg         layer_done,
    output reg         cfg_error,
    output reg  [3:0]  cur_layer,
    output reg  [3:0]  cnn_class,

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
    input  wire [31:0] proc_dout,

    // IBUF
    output wire [11:0] ibuf_ra,
    input  wire [31:0] ibuf_q,
    output reg         ibuf_we,
    output reg  [11:0] ibuf_wa,
    output reg  [31:0] ibuf_wd
);

    localparam [3:0]
        S_IDLE   = 4'd0,  S_DWAIT  = 4'd1,  S_DESC   = 4'd2,  S_INIT   = 4'd3,
        S_INIT2  = 4'd4,  S_ISSUE  = 4'd5,  S_WAIT   = 4'd6,  S_NEXT   = 4'd7,
        S_AWAIT  = 4'd8,  S_AMAX   = 4'd9,  S_AWRITE = 4'd10, S_LDONE  = 4'd11,
        S_DONE   = 4'd12, S_COPY   = 4'd13, S_INIT3  = 4'd14;
    reg [3:0] state;

    localparam [1:0] PH_PRELOAD = 2'd0, PH_WIN = 2'd1, PH_STREAM = 2'd2;
    reg [1:0] phase;

    localparam [15:0] CHUNK = 16'd9;
    localparam [4:0]  R_ZERO = 5'd9, R_W0 = 5'd13;

    // ---- descriptor
    reg [31:0] d_h, d_w, d_ic, d_k, d_oc, d_flags, d_in, d_wt, d_bias, d_psum, d_out, d_amn, d_cls;
    wire f_relu = d_flags[0];
    wire f_pool = d_flags[1];
    wire f_amax = d_flags[3];
    wire f_copy = d_flags[6];

    // ---- derived per layer
    reg [15:0] oh_n, ow_n, ph_n, pw_n, taps, wic, kic, nwin;
    reg [31:0] ncopy, npix;
    reg        stream;

    // ---- loop state
    reg [15:0] g_cnt, chunk_start, chunk_end, pre_tap, pre_base;
    reg [15:0] kh, kw, ic, cur_off;
    reg [15:0] tap_off [0:8];
    reg [15:0] win;
    reg [5:0]  opi;
    reg [15:0] wb0, wb1, wb2, wb3, wow3;          // IBUF base of window pixel j; ow of pixel 3
    reg [15:0] pr, pc, prow;                      // pool window position, row base
    reg [1:0]  sk;                                // stream convoy kind: 0 first, 1 mid, 2 tail
    reg [15:0] st_tap;
    reg [2:0]  issue_cnt, real_last;
    reg [4:0]  wait_cnt;
    reg [3:0]  idle_cnt;
    reg [4:0]  dcnt;
    reg [15:0] acnt, ccnt;
    reg signed [31:0] best_v;
    reg [15:0] best_i;
    integer    ti;

    // ---- window op stream
    wire [3:0]  tcn     = chunk_end[3:0] - chunk_start[3:0];          // taps in chunk, 1..9
    wire [5:0]  nmac    = {tcn, 2'b00};
    wire        final_c = (chunk_end == taps);
    wire [3:0]  npost   = !final_c ? 4'd4 : f_pool ? (f_relu ? 4'd5 : 4'd4) : (f_relu ? 4'd8 : 4'd4);
    wire [5:0]  nops    = 6'd4 + nmac + {2'b00, npost};
    wire        op_L    = (opi < 6'd4);
    wire        op_M    = !op_L && (opi < 6'd4 + nmac);
    wire [5:0]  q       = opi - 6'd4 - nmac;                          // post index
    wire [5:0]  m_cur   = opi - 6'd4;                                 // MAC index: t = m[5:2], j = m[1:0]
    wire        post_st = !final_c ? 1'b1 :
                          f_pool   ? (q == (f_relu ? 6'd4 : 6'd3)) :
                                     (!f_relu || q >= 6'd4);
    wire        op_S    = !op_L && !op_M && post_st;

    // ---- IBUF read address (pixel of the NEXT slot's op)
    wire [5:0]  opn   = (state == S_ISSUE && opi < nops) ? opi + 6'd1 : opi;
    wire [5:0]  m_nx  = opn - 6'd4;
    reg  [15:0] wb_nx;
    always @(*) begin
        case (m_nx[1:0])
            2'd0: wb_nx = wb0;
            2'd1: wb_nx = wb1;
            2'd2: wb_nx = wb2;
            default: wb_nx = wb3;
        endcase
    end
    wire [15:0] toff_nx  = tap_off[m_nx[5:2] > 4'd8 ? 4'd8 : m_nx[5:2]];
    wire [15:0] win_ra   = wb_nx + toff_nx;
    wire [15:0] str_ra   = st_tap + {13'd0, issue_cnt} - 16'd3;
    assign ibuf_ra = (phase == PH_STREAM) ? str_ra[11:0] : win_ra[11:0];

    // ---- next-window IBUF bases
    // every operand is an argument: a continuous assignment re-evaluates a
    // function only when its arguments change
    function [31:0] step_px(input [15:0] owv, input [15:0] bv, input [15:0] own, input [15:0] icv, input [15:0] kicv);
        step_px = (owv + 16'd1 < own) ? {owv + 16'd1, bv + icv} : {16'd0, bv + kicv};
    endfunction
    wire        nw_reset = (phase == PH_PRELOAD);
    wire [31:0] s0 = nw_reset ? 32'd0 : step_px(wow3, wb3, ow_n, d_ic[15:0], kic);
    wire [31:0] s1 = step_px(s0[31:16], s0[15:0], ow_n, d_ic[15:0], kic);
    wire [31:0] s2 = step_px(s1[31:16], s1[15:0], ow_n, d_ic[15:0], kic);
    wire [31:0] s3 = step_px(s2[31:16], s2[15:0], ow_n, d_ic[15:0], kic);
    wire        pc_wrap = (pc + 16'd1 >= pw_n);
    wire [15:0] np_pc   = nw_reset ? 16'd0 : (pc_wrap ? 16'd0 : pc + 16'd1);
    wire [15:0] np_pr   = nw_reset ? 16'd0 : (pc_wrap ? pr + 16'd1 : pr);
    wire [15:0] np_prow = nw_reset ? 16'd0 : (pc_wrap ? prow + {wic[14:0], 1'b0} : prow);
    wire [15:0] np_base = nw_reset ? 16'd0 : (pc_wrap ? prow + {wic[14:0], 1'b0} : wb0 + {d_ic[14:0], 1'b0});

    // ---- addresses
    wire [31:0] a_weight = d_wt   + ((pre_tap * d_oc[15:0] + g_cnt) << 2);
    wire [31:0] a_bias   = d_bias + (g_cnt << 2);
    wire [17:0] accix    = {win, 2'b00};
    wire [31:0] a_psum0  = d_psum + ({14'd0, accix} << 6);
    wire [31:0] a_pool   = d_out  + ((win * d_oc[15:0] + g_cnt) << 2);

    // ---- stream mode
    wire [15:0] s_left   = taps - st_tap;
    wire [15:0] s_cap    = (sk == 2'd0) ? 16'd3 : 16'd4;
    wire [2:0]  s_n      = (s_left >= s_cap) ? s_cap[2:0] : s_left[2:0];

    // ---- PRELOAD shape
    wire [15:0] pre_left = chunk_end - pre_base;
    wire [2:0]  n_pre    = (pre_left >= 16'd3) ? 3'd3 : pre_left[2:0];
    wire [4:0]  clr_at   = 5'd8 + {2'b00, real_last};

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
        ibuf_we      <= 1'b0;
    end
    endtask

    task load_op(input [4:0] vd, input [31:0] addr);
    begin
        vec_vd <= vd;  vec_RS1 <= addr;  vec_dmr <= 1'b1;  vec_reg_we <= 1'b1;  vec_mem_reg <= 1'b1;
    end
    endtask
    task store_op(input [4:0] vd, input [31:0] addr);
    begin
        vec_vd <= vd;  vec_RS1 <= addr;  vec_dmw <= 1'b1;
    end
    endtask
    task max_op(input [4:0] vd, input [4:0] vs1, input [4:0] vs2);
    begin
        vec_vd <= vd;  vec_vs1 <= vs1;  vec_vs2 <= vs2;  vec_funct <= 8'b00000101;  vec_reg_we <= 1'b1;
    end
    endtask
    task macx_op(input [4:0] vd, input [4:0] wreg);
    begin
        vec_vd <= vd;  vec_vs1 <= 5'd0;  vec_vs2 <= wreg;  vec_RS1 <= ibuf_q;
        vec_ALUSrc <= 2'b01;  vec_funct <= 8'b00000011;  vec_reg_we <= 1'b1;
    end
    endtask

    // Drive convoy slot s; default = running no-op (start = 1, no writes).
    task drive_slot(input [2:0] s);
        reg [31:0] pix;
    begin
        vec_id    <= s;
        vec_start <= 1'b1;
        if (phase == PH_PRELOAD) begin
            if (s < n_pre) begin
                load_op(R_W0 + {pre_tap[3:0] - chunk_start[3:0], 1'b0}, a_weight);
                tap_off[pre_tap[3:0] - chunk_start[3:0]] <= cur_off;
                pre_tap   <= pre_tap + 16'd1;
                real_last <= s;
                if (ic < d_ic[15:0] - 16'd1) begin
                    ic <= ic + 16'd1;  cur_off <= cur_off + 16'd1;
                end else begin
                    ic <= 16'd0;
                    if (kw < d_k[15:0] - 16'd1) begin
                        kw <= kw + 16'd1;  cur_off <= cur_off + 16'd1;
                    end else begin
                        kw <= 16'd0;  kh <= kh + 16'd1;  cur_off <= cur_off + wic - kic + 16'd1;
                    end
                end
            end
        end else if (phase == PH_STREAM) begin
            if (sk == 2'd2) begin                                         // tail
                if (f_relu && s == 3'd0) begin
                    max_op(5'd1, 5'd1, R_ZERO);  real_last <= s;
                end else if (s == (f_relu ? 3'd1 : 3'd0)) begin
                    store_op(5'd1, d_out + (g_cnt << 2));  real_last <= s;
                end
            end else if (sk == 2'd0 && s == 3'd0) begin                   // bias
                load_op(5'd1, a_bias);  real_last <= s;
            end else if (s < 3'd4 && {1'b0, s} < ((sk == 2'd0) ? {1'b0, s_n} + 4'd1 : {1'b0, s_n})
                         && !(sk == 2'd0 && s == 3'd0)) begin            // weight load
                load_op(R_W0 + {(sk == 2'd0) ? s - 3'd1 : s, 1'b0},
                        d_wt + (((st_tap + ((sk == 2'd0) ? s - 3'd1 : s)) * d_oc[15:0] + g_cnt) << 2));
                real_last <= s;
            end else if (s >= 3'd4 && s - 3'd4 < s_n) begin               // MACX
                macx_op(5'd1, R_W0 + {s - 3'd4, 1'b0});
                real_last <= s;
            end
        end else begin                                                    // PH_WIN
            if (opi < nops && !(op_S && s == 3'd7)) begin
                opi       <= opi + 6'd1;
                real_last <= s;
                if (op_L) begin
                    load_op({2'b00, opi[1:0], 1'b1}, (chunk_start == 16'd0) ? a_bias : a_psum0 + {opi[1:0], 6'd0});
                end else if (op_M) begin
                    macx_op({2'b00, m_cur[1:0], 1'b1}, R_W0 + {m_cur[5:2], 1'b0});
                end else if (!final_c) begin
                    store_op({2'b00, q[1:0], 1'b1}, a_psum0 + {q[1:0], 6'd0});
                end else if (f_pool) begin
                    case (q[2:0])
                        3'd0: max_op(5'd1, 5'd1, 5'd3);
                        3'd1: max_op(5'd5, 5'd5, 5'd7);
                        3'd2: max_op(5'd1, 5'd1, 5'd5);
                        3'd3: if (f_relu) max_op(5'd1, 5'd1, R_ZERO); else store_op(5'd1, a_pool);
                        default: store_op(5'd1, a_pool);
                    endcase
                end else if (f_relu && q < 6'd4) begin
                    max_op({2'b00, q[1:0], 1'b1}, {2'b00, q[1:0], 1'b1}, R_ZERO);
                end else begin
                    store_op({2'b00, q[1:0], 1'b1},
                             d_out + (((accix + q[1:0]) * d_oc[15:0] + g_cnt) << 2));
                end
            end
        end
    end
    endtask

    task end_of_layer;
    begin
        state <= f_amax ? S_AWAIT : S_LDONE;
        idle_cnt <= 4'd0;
    end
    endtask

    task group_reset;
    begin
        chunk_start <= 16'd0;
        chunk_end   <= (taps < CHUNK) ? taps : CHUNK;
        pre_tap <= 16'd0;  pre_base <= 16'd0;
        kh <= 16'd0;  kw <= 16'd0;  ic <= 16'd0;  cur_off <= 16'd0;
        win <= 16'd0;  opi <= 6'd0;  sk <= 2'd0;  st_tap <= 16'd0;
        phase <= stream ? PH_STREAM : PH_PRELOAD;
    end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;  phase <= PH_PRELOAD;
            layer_busy <= 1'b0;  layer_done <= 1'b0;  cfg_error <= 1'b0;
            cur_layer <= 4'd0;  cnn_class <= 4'd0;
            d_h <= 0; d_w <= 0; d_ic <= 0; d_k <= 0; d_oc <= 0; d_flags <= 0; d_in <= 0;
            d_wt <= 0; d_bias <= 0; d_psum <= 0; d_out <= 0; d_amn <= 0; d_cls <= 0;
            oh_n <= 0; ow_n <= 0; ph_n <= 0; pw_n <= 0; taps <= 0; wic <= 0; kic <= 0; nwin <= 0;
            ncopy <= 0; npix <= 0; stream <= 1'b0;
            g_cnt <= 0; chunk_start <= 0; chunk_end <= 0; pre_tap <= 0; pre_base <= 0;
            kh <= 0; kw <= 0; ic <= 0; cur_off <= 0;
            for (ti = 0; ti < 9; ti = ti + 1) tap_off[ti] <= 16'd0;
            win <= 0; opi <= 0; wb0 <= 0; wb1 <= 0; wb2 <= 0; wb3 <= 0; wow3 <= 0;
            pr <= 0; pc <= 0; prow <= 0; sk <= 0; st_tap <= 0;
            issue_cnt <= 0; real_last <= 0; wait_cnt <= 0; idle_cnt <= 0; dcnt <= 0; acnt <= 0; ccnt <= 0;
            best_v <= 0; best_i <= 0;
            ibuf_wa <= 0; ibuf_wd <= 0;
            vec_vl <= 9'd16;  vec_quant <= 2'b00;
            set_vec_idle;
        end else begin
            // while waiting, every vec_* output keeps slot 7's instruction (re-drive)
            if (state != S_WAIT) set_vec_idle;
            else begin
                vec_clear <= 1'b0;
                ibuf_we   <= 1'b0;
            end
            layer_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    layer_busy <= 1'b0;
                    if (layer_start) begin
                        layer_busy <= 1'b1;
                        cfg_error  <= 1'b0;
                        cur_layer  <= 4'd0;
                        idle_cnt   <= 4'd0;
                        state      <= S_DWAIT;
                    end
                end

                S_DWAIT: begin
                    idle_cnt <= vec_done ? idle_cnt + 4'd1 : 4'd0;
                    if (vec_done && idle_cnt == 4'd3) begin
                        dcnt  <= 5'd0;
                        state <= S_DESC;
                    end
                end

                S_DESC: begin
                    if (dcnt < 5'd13)
                        proc_addr <= desc_base + {cur_layer, 6'd0} + {dcnt, 2'b00};
                    if (dcnt >= 5'd2) begin
                        case (dcnt - 5'd2)
                            5'd0:  d_h     <= proc_dout;
                            5'd1:  d_w     <= proc_dout;
                            5'd2:  d_ic    <= proc_dout;
                            5'd3:  d_k     <= proc_dout;
                            5'd4:  d_oc    <= proc_dout;
                            5'd5:  d_flags <= proc_dout;
                            5'd6:  d_in    <= proc_dout;
                            5'd7:  d_wt    <= proc_dout;
                            5'd8:  d_bias  <= proc_dout;
                            5'd9:  d_psum  <= proc_dout;
                            5'd10: d_out   <= proc_dout;
                            5'd11: d_amn   <= proc_dout;
                            5'd12: d_cls   <= proc_dout;
                            default: ;
                        endcase
                    end
                    dcnt <= dcnt + 5'd1;
                    if (dcnt == 5'd14)
                        state <= S_INIT;
                end

                S_INIT: begin
                    oh_n  <= d_h[15:0] - d_k[15:0] + 16'd1;
                    ow_n  <= d_w[15:0] - d_k[15:0] + 16'd1;
                    taps  <= d_k[15:0] * d_k[15:0] * d_ic[15:0];
                    wic   <= d_w[15:0] * d_ic[15:0];
                    kic   <= d_k[15:0] * d_ic[15:0];
                    ncopy <= d_h[15:0] * d_w[15:0] * d_ic[15:0];
                    vec_quant <= d_flags[5:4];
                    vec_vl    <= 9'd16;
                    vec_clear <= 1'b1;
                    state     <= S_INIT2;
                end

                S_INIT2: begin
                    ph_n   <= {1'b0, oh_n[15:1]};
                    pw_n   <= {1'b0, ow_n[15:1]};
                    npix   <= oh_n * ow_n;
                    stream <= (oh_n == 16'd1) && (ow_n == 16'd1) && !f_pool;
                    state  <= S_INIT3;
                end

                S_INIT3: begin
                    nwin  <= f_pool ? ph_n * pw_n : npix[17:2];
                    g_cnt <= 16'd0;
                    group_reset;
                    issue_cnt <= 3'd0;  ccnt <= 16'd0;
                    if (d_oc[15:0] == 16'd0 || d_oc[3:0] != 4'd0 || d_k[15:0] == 16'd0 ||
                        d_ic[15:0] == 16'd0 || d_h[15:0] < d_k[15:0] || d_w[15:0] < d_k[15:0] ||
                        ncopy > 32'd4096 ||
                        (f_pool && (oh_n < 16'd2 || ow_n < 16'd2)) ||
                        (!f_pool && !stream && npix[1:0] != 2'd0) ||
                        (f_amax && (d_amn[15:0] == 16'd0 || d_amn[15:0] > d_oc[15:0]))) begin
                        cfg_error <= 1'b1;
                        state     <= S_DONE;
                    end else
                        state <= f_copy ? S_COPY : S_ISSUE;
                end

                // previous layer's output DMEM -> IBUF through the host port
                // (vector unit idle); read data arrives 2 cycles after the address
                S_COPY: begin
                    if (ccnt < ncopy[15:0])
                        proc_addr <= d_in + {ccnt, 2'b00};
                    if (ccnt >= 16'd2) begin
                        ibuf_we <= 1'b1;
                        ibuf_wa <= ccnt[11:0] - 12'd2;
                        ibuf_wd <= proc_dout;
                    end
                    ccnt <= ccnt + 16'd1;
                    if (ccnt == ncopy[15:0] + 16'd1)
                        state <= S_ISSUE;
                end

                S_ISSUE: begin
                    drive_slot(issue_cnt);
                    wait_cnt <= 5'd0;
                    if (issue_cnt == 3'd7)
                        state <= S_WAIT;
                    else
                        issue_cnt <= issue_cnt + 3'd1;
                end

                S_WAIT: begin
                    wait_cnt <= wait_cnt + 5'd1;
                    if (wait_cnt == clr_at) begin
                        vec_clear <= 1'b1;
                        state     <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    issue_cnt <= 3'd0;
                    state     <= S_ISSUE;
                    case (phase)
                        PH_PRELOAD: begin
                            pre_base <= pre_tap;
                            if (pre_tap == chunk_end) begin
                                phase <= PH_WIN;
                                win <= 16'd0;  opi <= 6'd0;
                                pr <= np_pr;  pc <= np_pc;  prow <= np_prow;
                                if (f_pool) begin
                                    wb0 <= np_base;  wb1 <= np_base + d_ic[15:0];
                                    wb2 <= np_base + wic;  wb3 <= np_base + wic + d_ic[15:0];
                                end else begin
                                    wb0 <= s0[15:0];  wb1 <= s1[15:0];  wb2 <= s2[15:0];  wb3 <= s3[15:0];
                                    wow3 <= s3[31:16];
                                end
                            end
                        end
                        PH_WIN: begin
                            if (opi == nops) begin
                                opi <= 6'd0;
                                if (win + 16'd1 < nwin) begin
                                    win <= win + 16'd1;
                                    pr <= np_pr;  pc <= np_pc;  prow <= np_prow;
                                    if (f_pool) begin
                                        wb0 <= np_base;  wb1 <= np_base + d_ic[15:0];
                                        wb2 <= np_base + wic;  wb3 <= np_base + wic + d_ic[15:0];
                                    end else begin
                                        wb0 <= s0[15:0];  wb1 <= s1[15:0];  wb2 <= s2[15:0];  wb3 <= s3[15:0];
                                        wow3 <= s3[31:16];
                                    end
                                end else begin                         // chunk done
                                    phase <= PH_PRELOAD;
                                    win   <= 16'd0;
                                    if (final_c) begin
                                        g_cnt <= g_cnt + 16'd16;
                                        group_reset;
                                        if (g_cnt + 16'd16 >= d_oc[15:0])
                                            end_of_layer;
                                    end else begin
                                        chunk_start <= chunk_end;
                                        chunk_end   <= (taps - chunk_end < CHUNK) ? taps : chunk_end + CHUNK;
                                        pre_tap <= chunk_end;  pre_base <= chunk_end;
                                    end
                                end
                            end
                        end
                        default: begin                                 // PH_STREAM
                            if (sk == 2'd2) begin
                                g_cnt <= g_cnt + 16'd16;
                                group_reset;
                                if (g_cnt + 16'd16 >= d_oc[15:0])
                                    end_of_layer;
                            end else begin
                                st_tap <= st_tap + {13'd0, s_n};
                                sk     <= (st_tap + {13'd0, s_n} >= taps) ? 2'd2 : 2'd1;
                            end
                        end
                    endcase
                end

                S_AWAIT: begin
                    idle_cnt <= vec_done ? idle_cnt + 4'd1 : 4'd0;
                    if (vec_done && idle_cnt == 4'd3) begin
                        acnt   <= 16'd0;
                        best_i <= 16'd0;
                        best_v <= 32'sh80000000;
                        state  <= S_AMAX;
                    end
                end

                S_AMAX: begin
                    if (acnt < d_amn[15:0])
                        proc_addr <= d_out + {acnt, 2'b00};
                    if (acnt >= 16'd2) begin
                        if ($signed(proc_dout) > best_v) begin
                            best_v <= $signed(proc_dout);
                            best_i <= acnt - 16'd2;
                        end
                    end
                    acnt <= acnt + 16'd1;
                    if (acnt == d_amn[15:0] + 16'd1)
                        state <= S_AWRITE;
                end

                S_AWRITE: begin
                    proc_addr <= d_cls;
                    proc_din  <= {16'd0, best_i};
                    proc_we   <= 1'b1;
                    cnn_class <= best_i[3:0];
                    state     <= S_LDONE;
                end

                S_LDONE: begin
                    if (cur_layer + 4'd1 < n_layers) begin
                        cur_layer <= cur_layer + 4'd1;
                        idle_cnt  <= 4'd0;
                        state     <= S_DWAIT;
                    end else
                        state <= S_DONE;
                end

                S_DONE: begin
                    layer_busy <= 1'b0;
                    layer_done <= 1'b1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
