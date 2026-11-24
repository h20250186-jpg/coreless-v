`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_scalar_tb   (NEW, 2026-11-17; step 1 of the scalar-operand
//                             build, docs/chunked_taps_design.md section 10.7)
//
// Isolated tests on v_wrapper alone (no atee_top, no DMA, vector-unit RTL
// unchanged), vl = 16, driven by the same mini controller as
// convoy_chunk_tb.v (F_ISSUE / F_WAIT / F_NEXT, registered outputs, all 8
// slots issued, unused slots = running no-ops, slot 7 re-driven UNCHANGED
// (incl. its RS1) while waiting, early clear 16 cycles after the last real slot).
//
// New instruction kind K_MACX = vmacc.vx: ALUSrc = "01", operand 1 = the slot's
// own RS1 (a scalar, here a pixel value), operand 2 = vs2 (weight vector),
// accumulator = vd.  Untested assumptions of the design note checked here:
//   F-A2  the ALUSrc = "01" MAC path at vl = 16 (never run by Coreless-V before)
//   F-A1  a MAC that reads its accumulator from the MAC 4 slots earlier
//         (4 accumulators, acc order 0,1,2,3,0,...) and across convoys
//   F-A3  (part) slot 7 holding a scalar MAC, re-driven while waiting
// Tests (all data random, mixed sign, 16 distinct values per vector,
// registers poisoned before every test, output rows poisoned):
//   T1  [L acc | - - - | MACX s0 | MACX s1 | S acc | -]            (F-A2)
//   T2  F window, one 9-tap chunk, the exact op stream of schedule F
//       (L x4, MACX x36 in acc order 0..3, then a post sequence), packed 8
//       slots per convoy with a store never in slot 7:
//       T2a final chunk, pool + ReLU : X X X X S   (16 values)
//       T2b non-final chunk          : S S S S     (64 values)
//       T2c final chunk, no pool, ReLU: X X X X S S S S (64 values)
//   T3  FC stream shape: [L acc | W W W | M M M | -], [W x4 | M x4] x 2,
//       [W W | - - | M M], [ReLU | S]   (16 values)
//   each at vcsr_quant = 0 (Q32.0) and 3 (Q8.24)
//   NEG T2a with ALUSrc = "00" in every MACX (operand 1 = a vector register)
//       -> must FAIL
//////////////////////////////////////////////////////////////////////////////////

module convoy_scalar_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;
    localparam W_BASE    = DMEM_BASE + 32'h0_1000;   // 16 weight vectors, 64 B each
    localparam PS_BASE   = DMEM_BASE + 32'h0_2000;   // 4 accumulator start vectors
    localparam OUT_BASE  = DMEM_BASE + 32'h0_4000;

    localparam [3:0] K_EMPTY = 4'd0, K_LOAD = 4'd1, K_MACX = 4'd2, K_STORE = 4'd3,
                     K_MAX = 4'd4, K_MACV = 4'd5, K_RUNNOP = 4'd6;

    reg clk, reset;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg  [8:0]  vl;
    reg  [1:0]  vcsr_quant;
    reg         I_clear;
    reg  [2:0]  I_id;
    wire        ALU_mon, stall_out, DONE_out;
    reg  [31:0] proc_addr, proc_din;
    wire [31:0] proc_dout;
    reg         proc_we;
    wire [4:0]  XRF_ADDR;
    wire [31:0] XRF_DATAWR;
    wire        XRF_WE;
    reg         I_start;
    reg  [4:0]  I_vs1, I_vs2, I_vd;
    reg  [31:0] I_RS1, I_RS2;
    reg  [4:0]  I_uimm5;
    reg  [7:0]  I_funct;
    reg  [1:0]  I_permute;
    reg         I_mask_en;
    reg  [1:0]  I_ALUSrc;
    reg         I_dmr, I_dmw, I_reg_we, I_mem_reg, I_Xout;
    reg  [1:0]  I_mode_lsu;

    v_wrapper #(.ENABLE_DIV(0)) dut (
        .clk(clk), .reset(reset), .vl(vl), .vcsr_quant(vcsr_quant),
        .I_clear(I_clear), .I_id(I_id), .ALU_mon(ALU_mon), .stall(stall_out),
        .DONE(DONE_out), .proc_addr(proc_addr), .proc_din(proc_din),
        .proc_dout(proc_dout), .proc_we(proc_we), .XRF_ADDR(XRF_ADDR),
        .XRF_DATAWR(XRF_DATAWR), .XRF_WE(XRF_WE), .I_start(I_start),
        .I_vs1(I_vs1), .I_vs2(I_vs2), .I_vd(I_vd), .I_RS1(I_RS1), .I_RS2(I_RS2),
        .I_uimm5(I_uimm5), .I_funct(I_funct), .I_permute(I_permute),
        .I_mask_en(I_mask_en), .I_ALUSrc(I_ALUSrc), .I_dmr(I_dmr), .I_dmw(I_dmw),
        .I_reg_we(I_reg_we), .I_mem_reg(I_mem_reg), .I_Xout(I_Xout),
        .I_mode_lsu(I_mode_lsu)
    );

    // ---------------------------------------------------------------------
    // Convoy programme: up to 32 convoys of 8 slots, index = convoy*8 + slot
    // ---------------------------------------------------------------------
    reg  [3:0]  p_kind [0:255];
    reg  [4:0]  p_vd   [0:255];
    reg  [4:0]  p_vs1  [0:255];
    reg  [4:0]  p_vs2  [0:255];
    reg  [31:0] p_addr [0:255];      // memory address, or the scalar for K_MACX
    reg  [2:0]  c_last [0:31];
    reg  [4:0]  c_clr  [0:31];
    integer     n_conv;
    reg         go;
    reg         neg_vv;              // NEG: K_MACX issued with ALUSrc = 00

    localparam [1:0] F_IDLE = 2'd0, F_ISSUE = 2'd1, F_WAIT = 2'd2, F_NEXT = 2'd3;
    reg [1:0] st;
    reg [4:0] conv;
    reg [2:0] issue_cnt;
    reg [4:0] wait_cnt;
    reg       fsm_done;
    integer   fsm_cycles, stall_cycles;

    task set_idle;
    begin
        I_clear <= 1'b0;
        I_start <= 1'b0;  I_id <= 3'd7;
        I_vs1 <= 5'd0;    I_vs2 <= 5'd0;   I_vd <= 5'd0;
        I_RS1 <= 32'd0;   I_RS2 <= 32'd0;  I_uimm5 <= 5'd0;
        I_funct <= 8'd0;  I_permute <= 2'd0; I_mask_en <= 1'b0;
        I_ALUSrc <= 2'b00; I_dmr <= 1'b0;  I_dmw <= 1'b0;
        I_reg_we <= 1'b0; I_mem_reg <= 1'b0; I_Xout <= 1'b0;
        I_mode_lsu <= 2'b00;
    end
    endtask

    task drive(input [4:0] c, input [2:0] s);
        reg [7:0] k;
    begin
        k = {c, s};
        I_id <= s;
        case (p_kind[k])
            K_LOAD: begin
                I_start <= 1'b1;  I_vd <= p_vd[k];  I_RS1 <= p_addr[k];
                I_dmr <= 1'b1;    I_reg_we <= 1'b1; I_mem_reg <= 1'b1;
            end
            K_MACX: begin
                I_start <= 1'b1;  I_vs1 <= p_vs1[k];  I_vs2 <= p_vs2[k];
                I_vd <= p_vd[k];  I_reg_we <= 1'b1;  I_funct <= 8'b00000011;
                I_RS1 <= p_addr[k];
                I_ALUSrc <= neg_vv ? 2'b00 : 2'b01;
            end
            K_MACV: begin
                I_start <= 1'b1;  I_vs1 <= p_vs1[k];  I_vs2 <= p_vs2[k];
                I_vd <= p_vd[k];  I_reg_we <= 1'b1;  I_funct <= 8'b00000011;
            end
            K_MAX: begin
                I_start <= 1'b1;  I_vs1 <= p_vs1[k];  I_vs2 <= p_vs2[k];
                I_vd <= p_vd[k];  I_reg_we <= 1'b1;  I_funct <= 8'b00000101;
            end
            K_STORE: begin
                I_start <= 1'b1;  I_vd <= p_vd[k];  I_RS1 <= p_addr[k];
                I_dmw <= 1'b1;
            end
            K_RUNNOP: I_start <= 1'b1;
            default: ;
        endcase
    end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            st <= F_IDLE;  conv <= 5'd0;  issue_cnt <= 3'd0;  wait_cnt <= 5'd0;
            fsm_done <= 1'b0;  fsm_cycles = 0;  stall_cycles = 0;
            set_idle;
        end else begin
            set_idle;
            fsm_done <= 1'b0;
            if (st != F_IDLE) begin
                fsm_cycles = fsm_cycles + 1;
                if (stall_out) stall_cycles = stall_cycles + 1;
            end
            case (st)
                F_IDLE: if (go) begin
                    conv <= 5'd0;  issue_cnt <= 3'd0;
                    fsm_cycles = 0;  stall_cycles = 0;
                    st <= F_ISSUE;
                end
                F_ISSUE: begin
                    drive(conv, issue_cnt);
                    wait_cnt <= 5'd0;
                    if (issue_cnt == 3'd7) st <= F_WAIT;
                    else issue_cnt <= issue_cnt + 3'd1;
                end
                F_WAIT: begin
                    drive(conv, 3'd7);                       // slot 7 re-driven unchanged
                    wait_cnt <= wait_cnt + 5'd1;
                    if (wait_cnt == c_clr[conv]) begin
                        I_clear <= 1'b1;
                        st <= F_NEXT;
                    end
                end
                F_NEXT: begin
                    issue_cnt <= 3'd0;
                    if (conv + 1 == n_conv) begin
                        st <= F_IDLE;  fsm_done <= 1'b1;
                    end else begin
                        conv <= conv + 5'd1;  st <= F_ISSUE;
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // proc interface helpers (only used while the unit is idle)
    // ---------------------------------------------------------------------
    integer i, j, e, t;
    reg [31:0] rd;

    task proc_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        proc_addr <= addr;  proc_din <= data;  proc_we <= 1'b1;
        @(posedge clk);
        proc_we <= 1'b0;    proc_addr <= 32'd0;
    end
    endtask

    task proc_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk);
        proc_addr <= addr;  proc_we <= 1'b0;
        @(posedge clk);
        @(negedge clk);
        data = proc_dout;
        proc_addr <= 32'd0;
    end
    endtask

    task poison_regs;
    begin
        for (j = 1; j < 32; j = j + 1)
            for (e = 0; e < 8; e = e + 1)
                proc_write(VREG_BASE + (j << 5) + (e << 2), 32'h0BAD_0000 + (j << 8) + e);
    end
    endtask

    // ---------------------------------------------------------------------
    // data and reference
    // ---------------------------------------------------------------------
    reg signed [31:0] Wv  [0:15][0:15];   // weight vector t, element e
    reg signed [31:0] PSv [0:3][0:15];    // accumulator start vector j
    reg signed [31:0] pix [0:3][0:15];    // scalar for accumulator j, tap t
    reg signed [31:0] accr [0:3][0:15];   // reference accumulators
    reg signed [31:0] expv [0:63];
    integer nexp;
    integer seed;
    integer total_good, total_checked, neg_good, neg_checked;
    reg     in_neg;

    function signed [31:0] qmul(input signed [31:0] a, input signed [31:0] b);
        reg signed [63:0] p;
    begin
        p = a * b;
        case (vcsr_quant)
            2'b00:   qmul = p[31:0];
            2'b01:   qmul = p[39:8];
            2'b10:   qmul = p[47:16];
            default: qmul = p[55:24];
        endcase
    end
    endfunction

    function signed [31:0] smax(input signed [31:0] a, input signed [31:0] b);
        smax = (a > b) ? a : b;
    endfunction

    // random value: Q32.0 small ints (products stay meaningful), Q8.24 full range-ish
    function signed [31:0] rnd(input integer kind);
        reg signed [31:0] r;
    begin
        r = $random(seed);
        if (vcsr_quant == 2'b00) rnd = (kind == 0) ? (r % 2000) : (r % 300);
        else                     rnd = (kind == 0) ? (r >>> 6) : (r >>> 4);   // ~ +-32 / +-128 in Q8.24
    end
    endfunction

    task gen_data;
    begin
        for (t = 0; t < 16; t = t + 1) for (e = 0; e < 16; e = e + 1) Wv[t][e] = rnd(1);
        for (j = 0; j < 4; j = j + 1) for (e = 0; e < 16; e = e + 1) PSv[j][e] = rnd(0);
        for (j = 0; j < 4; j = j + 1) for (t = 0; t < 16; t = t + 1) pix[j][t] = rnd(1);
        for (t = 0; t < 16; t = t + 1) for (e = 0; e < 16; e = e + 1) proc_write(W_BASE + (t << 6) + (e << 2), Wv[t][e]);
        for (j = 0; j < 4; j = j + 1) for (e = 0; e < 16; e = e + 1) proc_write(PS_BASE + (j << 6) + (e << 2), PSv[j][e]);
        for (i = 0; i < 64; i = i + 1) proc_write(OUT_BASE + (i << 2), 32'h0DEA_D000 + i);
    end
    endtask

    // The controllers never write the zero pair (v9/v10), so it holds 0 from
    // reset. poison_regs overwrites it; this restores 0 with one load convoy
    // from an all-zero DMEM row (setup only, not part of any measured run).
    localparam ZMEM = DMEM_BASE + 32'h0_6000;
    task zero_reg;
    begin
        for (e = 0; e < 16; e = e + 1) proc_write(ZMEM + (e << 2), 32'd0);
        clear_convoy(0);
        put(0, 0, K_LOAD, 5'd9, 0, 0, ZMEM);
        close_convoy_q(0, 0);
        n_conv = 1;
        run_fsm;
    end
    endtask
    task close_convoy_q(input integer c, input integer last);
    begin
        for (j = 0; j < 8; j = j + 1) if (p_kind[c * 8 + j] == K_EMPTY) p_kind[c * 8 + j] = K_RUNNOP;
        c_last[c] = 3'd7;
        c_clr[c]  = 16 - 1 - (7 - last);
    end
    endtask

    // ---------------------------------------------------------------------
    // programme building: a linear op list packed into convoys
    // ---------------------------------------------------------------------
    reg  [3:0]  o_kind [0:63];
    reg  [4:0]  o_vd   [0:63];
    reg  [4:0]  o_vs1  [0:63];
    reg  [4:0]  o_vs2  [0:63];
    reg  [31:0] o_addr [0:63];
    integer     n_ops;
    integer     slot_model;

    task op(input [3:0] kind, input [4:0] vd, input [4:0] vs1, input [4:0] vs2, input [31:0] addr);
    begin
        o_kind[n_ops] = kind;  o_vd[n_ops] = vd;  o_vs1[n_ops] = vs1;
        o_vs2[n_ops] = vs2;    o_addr[n_ops] = addr;
        n_ops = n_ops + 1;
    end
    endtask

    task close_convoy(inout integer c, input integer last);
    begin
        for (j = 0; j < 8; j = j + 1) if (p_kind[c * 8 + j] == K_EMPTY) p_kind[c * 8 + j] = K_RUNNOP;
        c_last[c] = 3'd7;
        c_clr[c]  = 16 - 1 - (7 - last);
        slot_model = slot_model + last + 18;
        c = c + 1;
    end
    endtask

    task clear_convoy(input integer c);
    begin
        for (j = 0; j < 8; j = j + 1) begin
            p_kind[c * 8 + j] = K_EMPTY;  p_vd[c * 8 + j] = 0;  p_vs1[c * 8 + j] = 0;
            p_vs2[c * 8 + j] = 0;         p_addr[c * 8 + j] = 0;
        end
    end
    endtask

    // greedy packing as scripts/cnn_schedule_model.py pack(): 8 slots, a store
    // never in slot 7 (it moves to the next convoy)
    task pack_ops(inout integer c);
        integer k, s;
    begin
        s = 0;  clear_convoy(c);
        for (k = 0; k < n_ops; k = k + 1) begin
            if (s == 8 || (o_kind[k] == K_STORE && s == 7)) begin
                close_convoy(c, (s == 8) ? 7 : 6);
                clear_convoy(c);  s = 0;
            end
            p_kind[c * 8 + s] = o_kind[k];  p_vd[c * 8 + s] = o_vd[k];  p_vs1[c * 8 + s] = o_vs1[k];
            p_vs2[c * 8 + s] = o_vs2[k];    p_addr[c * 8 + s] = o_addr[k];
            s = s + 1;
        end
        close_convoy(c, s - 1);
    end
    endtask

    // explicit convoy: slots given one by one (slot index fixed)
    task put(input integer c, input integer s, input [3:0] kind, input [4:0] vd, input [4:0] vs1,
             input [4:0] vs2, input [31:0] addr);
    begin
        if (kind == K_STORE && s == 7) $display("ERROR: store placed in slot 7 (rule 2)");
        p_kind[c * 8 + s] = kind;  p_vd[c * 8 + s] = vd;  p_vs1[c * 8 + s] = vs1;
        p_vs2[c * 8 + s] = vs2;    p_addr[c * 8 + s] = addr;
    end
    endtask

    task run_fsm;
    begin
        @(posedge clk);  go <= 1'b1;
        @(posedge clk);  go <= 1'b0;
        @(posedge fsm_done);
        @(negedge clk);
        while (!DONE_out) @(negedge clk);
        repeat (4) @(posedge clk);
    end
    endtask

    task check(input [8*40:1] what);
        integer good, b;
        reg signed [31:0] gotv;
    begin
        good = 0;
        for (b = 0; b < nexp; b = b + 1) begin
            proc_read(OUT_BASE + (b << 2), rd);
            gotv = rd;
            if (gotv === expv[b]) good = good + 1;
            else if (good + 4 > b) $display("      mismatch word %0d: exp %0d got %0d", b, expv[b], gotv);
        end
        if (in_neg) begin neg_good = neg_good + good; neg_checked = neg_checked + nexp; end
        else begin total_good = total_good + good; total_checked = total_checked + nexp; end
        $display("    %s: %0d/%0d -> %s ; FSM cycles %0d (slot rule %0d), stall cycles %0d", what, good, nexp,
                 (good == nexp) ? "PASS" : "FAIL", fsm_cycles, slot_model, stall_cycles);
    end
    endtask

    // register plan of schedule F: acc j = v(1+2j), zero v9/10, weight t = v(13+2t)
    function [4:0] ACC(input integer jj); ACC = 5'd1 + 2 * jj; endfunction
    function [4:0] WR(input integer tt);  WR  = 5'd13 + 2 * tt; endfunction
    localparam [4:0] ZERO = 5'd9;

    // weight preload: 9 vectors, 3 per convoy (slots 0..2)
    task preload9(inout integer c);
        integer k;
    begin
        for (k = 0; k < 9; k = k + 3) begin
            clear_convoy(c);
            for (j = 0; j < 3; j = j + 1) put(c, j, K_LOAD, WR(k + j), 0, 0, W_BASE + ((k + j) << 6));
            close_convoy(c, 2);
        end
    end
    endtask

    // ---- T1
    task test1;
        integer c;
    begin
        $display("");
        $display("=== T1 (F-A2): [L acc | - - - | MACX s0 | MACX s1 | S acc | -], vl=16, quant %0d ===", vcsr_quant);
        gen_data;  poison_regs;  zero_reg;
        c = 0;  slot_model = 0;
        clear_convoy(c);  put(c, 0, K_LOAD, WR(0), 0, 0, W_BASE);  close_convoy(c, 0);
        clear_convoy(c);
        put(c, 0, K_LOAD, ACC(0), 0, 0, PS_BASE);
        put(c, 4, K_MACX, ACC(0), 5'd0, WR(0), pix[0][0]);
        put(c, 5, K_MACX, ACC(0), 5'd0, WR(0), pix[0][1]);
        put(c, 6, K_STORE, ACC(0), 0, 0, OUT_BASE);
        close_convoy(c, 6);
        n_conv = c;
        run_fsm;
        nexp = 16;
        for (e = 0; e < 16; e = e + 1) expv[e] = PSv[0][e] + qmul(pix[0][0], Wv[0][e]) + qmul(pix[0][1], Wv[0][e]);
        check("T1 psum + s0*W + s1*W");
    end
    endtask

    // ---- T2: the F window op stream, 9 taps
    task test2(input integer variant);   // 0 = final pool+ReLU, 1 = non-final, 2 = final no-pool ReLU
        integer c, k;
    begin
        $display("");
        $display("=== T2%s: F window, 9 taps, 4 accumulators, quant %0d%s ===",
                 (variant == 0) ? "a (final, pool + ReLU: X X X X S)" :
                 (variant == 1) ? "b (non-final: S S S S)" : "c (final, no pool, ReLU: X X X X S S S S)",
                 vcsr_quant, neg_vv ? ", NEG: MACX with ALUSrc = 00" : "");
        gen_data;  poison_regs;  zero_reg;
        c = 0;  slot_model = 0;
        preload9(c);
        n_ops = 0;
        for (k = 0; k < 4; k = k + 1) op(K_LOAD, ACC(k), 0, 0, PS_BASE + (k << 6));
        for (t = 0; t < 9; t = t + 1)
            for (k = 0; k < 4; k = k + 1) op(K_MACX, ACC(k), 5'd0, WR(t), pix[k][t]);
        if (variant == 0) begin
            op(K_MAX, ACC(0), ACC(0), ACC(1), 0);
            op(K_MAX, ACC(2), ACC(2), ACC(3), 0);
            op(K_MAX, ACC(0), ACC(0), ACC(2), 0);
            op(K_MAX, ACC(0), ACC(0), ZERO, 0);
            op(K_STORE, ACC(0), 0, 0, OUT_BASE);
        end else if (variant == 1) begin
            for (k = 0; k < 4; k = k + 1) op(K_STORE, ACC(k), 0, 0, OUT_BASE + (k << 6));
        end else begin
            for (k = 0; k < 4; k = k + 1) op(K_MAX, ACC(k), ACC(k), ZERO, 0);
            for (k = 0; k < 4; k = k + 1) op(K_STORE, ACC(k), 0, 0, OUT_BASE + (k << 6));
        end
        pack_ops(c);
        n_conv = c;
        run_fsm;
        for (k = 0; k < 4; k = k + 1)
            for (e = 0; e < 16; e = e + 1) begin
                accr[k][e] = PSv[k][e];
                for (t = 0; t < 9; t = t + 1) accr[k][e] = accr[k][e] + qmul(pix[k][t], Wv[t][e]);
            end
        if (variant == 0) begin
            nexp = 16;
            for (e = 0; e < 16; e = e + 1)
                expv[e] = smax(smax(smax(accr[0][e], accr[1][e]), smax(accr[2][e], accr[3][e])), 0);
        end else begin
            nexp = 64;
            for (k = 0; k < 4; k = k + 1)
                for (e = 0; e < 16; e = e + 1)
                    expv[k * 16 + e] = (variant == 2) ? smax(accr[k][e], 0) : accr[k][e];
        end
        check(neg_vv ? "NEG T2a, must FAIL" : (variant == 0) ? "T2a pooled + ReLU" :
              (variant == 1) ? "T2b 4 partial sums" : "T2c 4 outputs ReLU");
    end
    endtask

    // ---- T3: FC stream shape, 13 taps
    task test3;
        integer c, k, tt;
    begin
        $display("");
        $display("=== T3: FC stream, 13 taps: [L | W W W | M M M | -] [W x4 | M x4] x2 [W W | - - | M M] [ReLU | S], quant %0d ===", vcsr_quant);
        gen_data;  poison_regs;  zero_reg;
        c = 0;  slot_model = 0;  tt = 0;
        clear_convoy(c);
        put(c, 0, K_LOAD, ACC(0), 0, 0, PS_BASE);
        for (k = 0; k < 3; k = k + 1) begin
            put(c, 1 + k, K_LOAD, WR(k), 0, 0, W_BASE + ((tt + k) << 6));
            put(c, 4 + k, K_MACX, ACC(0), 5'd0, WR(k), pix[(tt + k) % 4][(tt + k) / 4]);
        end
        close_convoy(c, 6);  tt = 3;
        while (tt < 13) begin
            clear_convoy(c);
            for (k = 0; k < 4 && tt + k < 13; k = k + 1) begin
                put(c, k, K_LOAD, WR(k), 0, 0, W_BASE + ((tt + k) << 6));
                put(c, 4 + k, K_MACX, ACC(0), 5'd0, WR(k), pix[(tt + k) % 4][(tt + k) / 4]);
            end
            close_convoy(c, 3 + k);  tt = tt + k;
        end
        clear_convoy(c);
        put(c, 0, K_MAX, ACC(0), ACC(0), ZERO, 0);
        put(c, 1, K_STORE, ACC(0), 0, 0, OUT_BASE);
        close_convoy(c, 1);
        n_conv = c;
        run_fsm;
        nexp = 16;
        for (e = 0; e < 16; e = e + 1) begin
            expv[e] = PSv[0][e];
            for (k = 0; k < 13; k = k + 1) expv[e] = expv[e] + qmul(pix[k % 4][k / 4], Wv[k][e]);
            expv[e] = smax(expv[e], 0);
        end
        check("T3 FC stream + ReLU");
    end
    endtask

    integer qi;
    initial begin
        vl = 9'd16;  vcsr_quant = 2'b00;  go = 1'b0;  n_conv = 0;  neg_vv = 1'b0;  seed = 20261117;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        total_good = 0;  total_checked = 0;  neg_good = 0;  neg_checked = 0;  in_neg = 1'b0;
        for (i = 0; i < 256; i = i + 1) p_kind[i] = K_EMPTY;
        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);
        for (qi = 0; qi < 2; qi = qi + 1) begin
            vcsr_quant = (qi == 0) ? 2'b00 : 2'b11;
            test1;
            test2(0);
            test2(1);
            test2(2);
            test3;
        end
        $display("");
        $display("SUMMARY: %0d of %0d compared elements correct -> %s", total_good, total_checked,
                 (total_good == total_checked) ? "ALL PASS" : "FAILURES");
        in_neg = 1'b1;  neg_vv = 1'b1;  vcsr_quant = 2'b11;
        test2(0);
        $display("");
        $display("NEG SUMMARY (MACX with ALUSrc = 00): %0d of %0d elements correct (expected: far fewer than %0d)",
                 neg_good, neg_checked, neg_checked);
        $finish;
    end

endmodule
