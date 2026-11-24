`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: hbm_lite_controller_cnn
// NEW controller (2026-11-17, task G). Runs a whole CNN (cnn_demo: conv+pool,
// conv+pool, FC + argmax) from ONE start, at vl = 16, on the replicated-input +
// chunked-tap schedule ("B", docs/chunked_taps_design.md sections 3, 8, 9).
// hbm_lite_controller.v, hbm_lite_controller_vl16.v and the vector-unit RTL
// are NOT modified.
//
// ---- Layer descriptors (read from DMEM through the host port, 13 words per
// layer at desc_base + 64*layer; desc_base = cfg INPUT_BASE register, number
// of layers = cfg INPUT_C register, see atee_top_cnn.v):
//   w0 H   w1 W   w2 IC   w3 K (square kernel, stride 1, no padding)
//   w4 OC (multiple of 16)
//   w5 flags: [0] ReLU  [1] 2x2 max-pool  [2] pooled output written REPLICATED
//             16x (input layout of the next layer)  [3] argmax  [5:4] Q format
//   w6 input base  w7 weight base  w8 bias base  w9 partial-sum base
//   w10 output base  w11 argmax length  w12 class address
//
// ---- Memory layouts (byte addresses; DMEM bank = addr[4:2]):
//   input  : pixel-major, channel-minor, each value REPLICATED 16x:
//            in + (((ih*W + iw)*IC + ic) << 6)
//   weight : tap-major (tap = (kh*K + kw)*IC + ic), OC innermost:
//            wt + ((tap*OC + oc) << 2)
//   bias   : bias + (oc << 2)
//   psum   : psum + ((pix*OC + oc) << 2), pix = sequential pixel index
//   output : pool + replicate: out + ((((pp*OC + oc) << 4) + k) << 2), k = 0..15
//            (= the next layer's input layout, pp = pooled pixel index)
//            otherwise        : out + ((pix*OC + oc) << 2)
//
// ---- Register map (two registers per vl=16 vector, v0 never written):
//   X0..X2 v1/2 v3/4 v5/6 | acc v7/8 | zero v9/10 (never written)
//   pool v11/12 | tap t of the chunk: v(13+2t)/(14+2t), t = 0..8
//
// ---- Schedule: per OC group (16 channels), per chunk of <= 9 taps:
//   PRELOAD convoys: up to 3 weight loads (slots 0..2)
//   per pixel (pool: 2x2-window order), convoys of <= 3 taps:
//     first convoy of the chunk: slot 0 loads the bias (chunk 0) or the
//       partial sum into acc; X loads in slots 1..n; MACs in slots 4..3+n
//     other convoys: X loads 0..n-1; MACs 3..2+n
//     last convoy of the chunk, after the MACs:
//       non-final chunk : store acc -> psum
//       final, pool     : max(acc, window-first ? zero : pool) -> pool
//                         (first pixel: max with zero = ReLU; ReLU commutes
//                          with max, so pool = max(0, max of the 4 accs))
//       final, no pool  : [ReLU] + store acc -> output
//   after the 4th pixel of a window (final chunk): REPLICATE convoys: 16
//     strided stores (RS2 = 16 words) of pool, k = 0..6 | 7..13 | 14..15
//     (slot j of a convoy writes copy k, all to DMEM bank k mod 8: the slots
//     of one convoy are on distinct banks, no collision)
//   argmax (flag): the controller reads the first n outputs back through the
//     host port and keeps the FIRST maximum (strict >); writes the index to
//     the class address and to cnn_class.
//
// ---- Scheduling rules of the inherited core:
//   1. No load directly before its reader: MAC j reads X_j 3 slots back; the
//      first MAC of a chunk reads acc loaded in slot 0, 4 slots back (the
//      chunk-boundary shape measured by convoy_chunk_tb.v).
//   2. No store in slot 7: a convoy takes at most cap taps so that its store
//      lands in slot <= 6; replicate convoys use slots 0..6.
//   3. Loads are unit-stride. The only strided accesses are the replicate
//      STORES (one bank per slot, distinct within a convoy).
//   4. Every slot occupied at vl > 8: all 8 slots issued, running no-ops,
//      slot 7 re-driven while waiting.
//   5. vl = 16 (multiple of 8).
// Early clear 16 cycles after the last real slot (slot rule: last + 18).
//////////////////////////////////////////////////////////////////////////////////

module hbm_lite_controller_cnn (
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
    input  wire [31:0] proc_dout
);

    localparam [3:0]
        S_IDLE   = 4'd0,  S_DWAIT  = 4'd1,  S_DESC   = 4'd2,  S_INIT   = 4'd3,
        S_INIT2  = 4'd4,  S_ISSUE  = 4'd5,  S_WAIT   = 4'd6,  S_NEXT   = 4'd7,
        S_AWAIT  = 4'd8,  S_AMAX   = 4'd9,  S_AWRITE = 4'd10, S_LDONE  = 4'd11,
        S_DONE   = 4'd12;
    reg [3:0] state;

    localparam [1:0] PH_PRELOAD = 2'd0, PH_PIXEL = 2'd1, PH_OUT = 2'd2;
    reg [1:0] phase;

    localparam [15:0] CHUNK = 16'd9;
    localparam [4:0]  R_X0 = 5'd1, R_ACC = 5'd7, R_ZERO = 5'd9, R_POOL = 5'd11, R_W0 = 5'd13;

    // ---- descriptor
    reg [31:0] d_h, d_w, d_ic, d_k, d_oc, d_flags, d_in, d_wt, d_bias, d_psum, d_out, d_amn, d_cls;
    wire f_relu = d_flags[0];
    wire f_pool = d_flags[1];
    wire f_rep  = d_flags[2];
    wire f_amax = d_flags[3];

    // ---- derived per layer
    reg [15:0] oh_n, ow_n, ph_n, pw_n, taps;

    // ---- loop counters
    reg [15:0] g_cnt, chunk_start, chunk_end;
    reg [15:0] kh0, kw0, ic0, kh, kw, ic;
    reg [15:0] conv_tap, pre_tap, pre_base;
    reg [15:0] pr, pc, pix_seq;
    reg        wa, wb;
    reg [1:0]  rep_k;
    reg [2:0]  issue_cnt;
    reg [4:0]  wait_cnt;
    reg [3:0]  idle_cnt;
    reg [4:0]  dcnt;
    reg [15:0] acnt;
    reg signed [31:0] best_v;
    reg [15:0] best_i;

    // ---- addresses
    wire [15:0] oh = f_pool ? {pr[14:0], wa} : pr;
    wire [15:0] ow = f_pool ? {pc[14:0], wb} : pc;
    wire [31:0] in_pix   = (oh + kh) * d_w[15:0] + (ow + kw);
    wire [31:0] in_idx   = in_pix * d_ic[15:0] + ic;
    wire [31:0] a_input  = d_in   + (in_idx << 6);
    wire [31:0] a_weight = d_wt   + ((pre_tap * d_oc[15:0] + g_cnt) << 2);
    wire [31:0] a_bias   = d_bias + (g_cnt << 2);
    wire [31:0] a_psum   = d_psum + ((pix_seq * d_oc[15:0] + g_cnt) << 2);
    wire [31:0] a_outpix = d_out  + ((pix_seq * d_oc[15:0] + g_cnt) << 2);
    wire [31:0] pool_idx = pr * pw_n + pc;
    wire [31:0] pool_vec = pool_idx * d_oc[15:0] + g_cnt;
    wire [31:0] a_rep0   = d_out  + (pool_vec << 6);        // copy k at + (k << 2)
    wire [31:0] a_pool   = d_out  + (pool_vec << 2);        // plain pooled store

    // ---- convoy shape (PIXEL phase), from the convoy-start tap conv_tap
    wire        final_c  = (chunk_end == taps);
    wire        first    = (conv_tap == chunk_start);
    wire [15:0] tl       = chunk_end - conv_tap;
    wire        post_st  = !final_c || !f_pool;                       // post ops end in a store
    wire [2:0]  npost    = !final_c ? 3'd1 : f_pool ? 3'd1 : (f_relu ? 3'd2 : 3'd1);
    wire [3:0]  mb       = first ? 4'd4 : 4'd3;
    wire [3:0]  lb       = first ? 4'd1 : 4'd0;
    wire [3:0]  cap_raw  = (post_st ? 4'd7 : 4'd8) - mb - {1'b0, npost};
    wire [3:0]  cap      = (cap_raw > 4'd3) ? 4'd3 : cap_raw;
    wire        last_c   = (tl <= {12'd0, cap});
    wire [2:0]  n_taps   = last_c ? tl[2:0] : ((tl - 16'd1) < 16'd3 ? tl[2:0] - 3'd1 : 3'd3);
    wire [3:0]  mac_end  = mb + {1'b0, n_taps};                       // first slot after the MACs
    wire        win_first = f_pool ? (!wa && !wb) : 1'b1;
    wire        win_last  = f_pool ? (wa && wb) : 1'b1;

    // ---- PRELOAD shape
    wire [15:0] pre_left = chunk_end - pre_base;
    wire [2:0]  n_pre    = (pre_left >= 16'd3) ? 3'd3 : pre_left[2:0];

    // last REAL slot of the current convoy
    wire [3:0]  real_last = (phase == PH_PRELOAD) ? {1'b0, n_pre} - 4'd1 :
                            (phase == PH_OUT)     ? (!f_rep ? 4'd0 : (rep_k == 2'd2) ? 4'd1 : 4'd6) :
                            last_c ? mac_end + {1'b0, npost} - 4'd1 : mac_end - 4'd1;
    wire [4:0]  clr_at    = 5'd8 + {1'b0, real_last};

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
        if (ic < d_ic[15:0] - 16'd1) begin
            ic <= ic + 16'd1;
        end else begin
            ic <= 16'd0;
            if (kw < d_k[15:0] - 16'd1) begin
                kw <= kw + 16'd1;
            end else begin
                kw <= 16'd0;
                kh <= kh + 16'd1;
            end
        end
    end
    endtask

    // Drive convoy slot s; default = running no-op (start = 1, no writes).
    task drive_slot(input [2:0] s);
    begin
        vec_id    <= s;
        vec_start <= 1'b1;
        if (phase == PH_PRELOAD) begin
            if (s < n_pre) begin
                vec_vd      <= R_W0 + {pre_tap[3:0] - chunk_start[3:0], 1'b0};
                vec_RS1     <= a_weight;
                vec_dmr     <= 1'b1;
                vec_reg_we  <= 1'b1;
                vec_mem_reg <= 1'b1;
                pre_tap     <= pre_tap + 16'd1;
            end
        end else if (phase == PH_OUT) begin
            if (!f_rep) begin
                if (s == 3'd0) begin                                  // plain pooled store
                    vec_vd  <= R_POOL;
                    vec_RS1 <= a_pool;
                    vec_dmw <= 1'b1;
                end
            end else if ((rep_k != 2'd2 && s <= 3'd6) || (rep_k == 2'd2 && s <= 3'd1)) begin
                vec_vd       <= R_POOL;                               // copy k = 7*rep_k + s
                vec_RS1      <= a_rep0 + ({27'd0, rep_k, 3'd0} - {29'd0, rep_k} + {29'd0, s} ) * 32'd4;
                vec_RS2      <= 32'd16;
                vec_mode_lsu <= 2'b10;
                vec_dmw      <= 1'b1;
            end
        end else begin
            if (first && s == 3'd0) begin                             // bias / partial sum -> acc
                vec_vd      <= R_ACC;
                vec_RS1     <= (chunk_start == 16'd0) ? a_bias : a_psum;
                vec_dmr     <= 1'b1;
                vec_reg_we  <= 1'b1;
                vec_mem_reg <= 1'b1;
            end else if ({1'b0, s} >= lb && {1'b0, s} < lb + {1'b0, n_taps}) begin   // X load
                vec_vd      <= R_X0 + {({1'b0, s} - lb), 1'b0};
                vec_RS1     <= a_input;
                vec_dmr     <= 1'b1;
                vec_reg_we  <= 1'b1;
                vec_mem_reg <= 1'b1;
                advance_tap;
            end else if ({1'b0, s} >= mb && {1'b0, s} < mac_end) begin               // MAC
                vec_vs1    <= R_X0 + {({1'b0, s} - mb), 1'b0};
                vec_vs2    <= R_W0 + {(conv_tap[3:0] - chunk_start[3:0]) + ({1'b0, s} - mb), 1'b0};
                vec_vd     <= R_ACC;
                vec_funct  <= 8'b00000011;
                vec_reg_we <= 1'b1;
            end else if (last_c && {1'b0, s} == mac_end) begin                       // post op 0
                if (!final_c) begin                                   // spill partial sum
                    vec_vd  <= R_ACC;
                    vec_RS1 <= a_psum;
                    vec_dmw <= 1'b1;
                end else if (f_pool) begin                            // max into pool
                    vec_vs1    <= R_ACC;
                    vec_vs2    <= win_first ? (f_relu ? R_ZERO : R_ACC) : R_POOL;
                    vec_vd     <= R_POOL;
                    vec_funct  <= 8'b00000101;
                    vec_reg_we <= 1'b1;
                end else if (f_relu) begin                            // ReLU
                    vec_vs1    <= R_ACC;
                    vec_vs2    <= R_ZERO;
                    vec_vd     <= R_ACC;
                    vec_funct  <= 8'b00000101;
                    vec_reg_we <= 1'b1;
                end else begin                                        // store
                    vec_vd  <= R_ACC;
                    vec_RS1 <= a_outpix;
                    vec_dmw <= 1'b1;
                end
            end else if (last_c && final_c && !f_pool && f_relu && {1'b0, s} == mac_end + 4'd1) begin
                vec_vd  <= R_ACC;                                     // store after ReLU
                vec_RS1 <= a_outpix;
                vec_dmw <= 1'b1;
            end
        end
    end
    endtask

    // pixel finished: next pixel of the chunk, or next chunk / group / layer
    task next_pixel;
    begin
        kh <= kh0;  kw <= kw0;  ic <= ic0;
        conv_tap <= chunk_start;
        pix_seq  <= pix_seq + 16'd1;
        phase    <= PH_PIXEL;
        if (f_pool && !wb) begin
            wb <= 1'b1;
        end else if (f_pool && !wa) begin
            wa <= 1'b1;  wb <= 1'b0;
        end else begin
            wa <= 1'b0;  wb <= 1'b0;
            if (pc < pw_n - 16'd1) begin
                pc <= pc + 16'd1;
            end else begin
                pc <= 16'd0;
                if (pr < ph_n - 16'd1) begin
                    pr <= pr + 16'd1;
                end else begin                                         // chunk done
                    pr <= 16'd0;
                    pix_seq <= 16'd0;
                    phase   <= PH_PRELOAD;
                    if (final_c) begin
                        chunk_start <= 16'd0;
                        chunk_end   <= (taps < CHUNK) ? taps : CHUNK;
                        pre_tap <= 16'd0;  pre_base <= 16'd0;
                        kh0 <= 16'd0;  kw0 <= 16'd0;  ic0 <= 16'd0;
                        g_cnt <= g_cnt + 16'd16;
                        if (g_cnt + 16'd16 >= d_oc[15:0])
                            state <= f_amax ? S_AWAIT : S_LDONE;
                    end else begin
                        chunk_start <= chunk_end;
                        chunk_end   <= (taps - chunk_end < CHUNK) ? taps : chunk_end + CHUNK;
                        pre_tap <= chunk_end;  pre_base <= chunk_end;
                        kh0 <= kh;  kw0 <= kw;  ic0 <= ic;             // = tap chunk_end
                    end
                end
            end
        end
    end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;  phase <= PH_PRELOAD;
            layer_busy <= 1'b0;  layer_done <= 1'b0;  cfg_error <= 1'b0;
            cur_layer <= 4'd0;  cnn_class <= 4'd0;
            d_h <= 0; d_w <= 0; d_ic <= 0; d_k <= 0; d_oc <= 0; d_flags <= 0; d_in <= 0;
            d_wt <= 0; d_bias <= 0; d_psum <= 0; d_out <= 0; d_amn <= 0; d_cls <= 0;
            oh_n <= 0; ow_n <= 0; ph_n <= 0; pw_n <= 0; taps <= 0;
            g_cnt <= 0; chunk_start <= 0; chunk_end <= 0;
            kh0 <= 0; kw0 <= 0; ic0 <= 0; kh <= 0; kw <= 0; ic <= 0;
            conv_tap <= 0; pre_tap <= 0; pre_base <= 0;
            pr <= 0; pc <= 0; pix_seq <= 0; wa <= 0; wb <= 0; rep_k <= 0;
            issue_cnt <= 0; wait_cnt <= 0; idle_cnt <= 0; dcnt <= 0; acnt <= 0;
            best_v <= 0; best_i <= 0;
            vec_vl <= 9'd16;  vec_quant <= 2'b00;
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
                        cur_layer  <= 4'd0;
                        idle_cnt   <= 4'd0;
                        state      <= S_DWAIT;
                    end
                end

                // vector unit idle for 4 cycles before the host port is used
                S_DWAIT: begin
                    idle_cnt <= vec_done ? idle_cnt + 4'd1 : 4'd0;
                    if (vec_done && idle_cnt == 4'd3) begin
                        dcnt  <= 5'd0;
                        state <= S_DESC;
                    end
                end

                // 13 descriptor words; read data arrives 2 cycles after the address
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
                    oh_n <= d_h[15:0] - d_k[15:0] + 16'd1;
                    ow_n <= d_w[15:0] - d_k[15:0] + 16'd1;
                    taps <= d_k[15:0] * d_k[15:0] * d_ic[15:0];
                    vec_quant <= d_flags[5:4];
                    vec_vl    <= 9'd16;
                    vec_clear <= 1'b1;
                    state     <= S_INIT2;
                end

                S_INIT2: begin
                    ph_n <= f_pool ? {1'b0, oh_n[15:1]} : oh_n;
                    pw_n <= f_pool ? {1'b0, ow_n[15:1]} : ow_n;
                    g_cnt <= 16'd0;  chunk_start <= 16'd0;
                    chunk_end <= (taps < CHUNK) ? taps : CHUNK;
                    kh0 <= 16'd0; kw0 <= 16'd0; ic0 <= 16'd0;
                    kh  <= 16'd0; kw  <= 16'd0; ic  <= 16'd0;
                    conv_tap <= 16'd0;  pre_tap <= 16'd0;  pre_base <= 16'd0;
                    pr <= 16'd0;  pc <= 16'd0;  wa <= 1'b0;  wb <= 1'b0;  pix_seq <= 16'd0;
                    rep_k <= 2'd0;  issue_cnt <= 3'd0;
                    phase <= PH_PRELOAD;
                    if (d_oc[15:0] == 16'd0 || d_oc[3:0] != 4'd0 || d_k[15:0] == 16'd0 ||
                        d_ic[15:0] == 16'd0 || d_h[15:0] < d_k[15:0] || d_w[15:0] < d_k[15:0] ||
                        (f_pool && (oh_n < 16'd2 || ow_n < 16'd2)) ||
                        (f_amax && (d_amn[15:0] == 16'd0 || d_amn[15:0] > d_oc[15:0]))) begin
                        cfg_error <= 1'b1;
                        state     <= S_DONE;
                    end else
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
                    drive_slot(3'd7);
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
                                phase <= PH_PIXEL;
                                kh <= kh0;  kw <= kw0;  ic <= ic0;
                                conv_tap <= chunk_start;
                                pr <= 16'd0;  pc <= 16'd0;  wa <= 1'b0;  wb <= 1'b0;  pix_seq <= 16'd0;
                            end
                        end
                        PH_PIXEL: begin
                            if (!last_c)
                                conv_tap <= conv_tap + {13'd0, n_taps};
                            else if (final_c && f_pool && win_last) begin
                                phase <= PH_OUT;
                                rep_k <= 2'd0;
                            end else
                                next_pixel;
                        end
                        default: begin                                 // PH_OUT
                            if (f_rep && rep_k != 2'd2)
                                rep_k <= rep_k + 2'd1;
                            else
                                next_pixel;
                        end
                    endcase
                end

                // argmax over the first d_amn outputs (group 0), first maximum wins
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
