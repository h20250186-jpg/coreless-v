`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_vl16_tb
//
// Isolated vl=16 tests on v_wrapper alone (no atee_top, no DMA).
//
// The unit is driven by a small FSM (F_ISSUE / F_WAIT / F_NEXT) that mirrors
// the LIVE hbm_lite_controller convention exactly:
//   * outputs are registered, one convoy slot driven per cycle;
//   * every other cycle writes an idle instruction (start=0) into slot 7,
//     unless the convoy's last issued slot IS slot 7, in which case slot 7's
//     own instruction is re-driven while waiting;
//   * early clear: I_clear is driven when the wait counter reaches a fixed
//     value, followed by one F_NEXT cycle, then slot 0 of the next convoy.
// CAL runs a vl=8 pixel through this FSM to show it reproduces the live
// controller's cycles per pixel.
//
// With vl=16 a vector is 16 elements: 0..7 in register vd, 8..15 in vd+1, both
// passes going through DMEM/VRF banks 0..7.
//
// SYN  : synthetic, 16 DISTINCT mixed-sign values per vector, registers and
//        output rows poisoned, run twice on different rows (stale first-pass
//        or previous-run data cannot give the expected result).
// WL   : weight preload convoy (3 unit-stride vl=16 loads) from DMEM.
// PIX  : real conv data, 3 pixels back to back, all 16 output channels of a
//        pixel in one pass; 3+3+3 (no ReLU) and 4+4+1 fused (ReLU).
// NEG  : PIX with the unused slots left truly EMPTY instead of holding a
//        running no-op.
//////////////////////////////////////////////////////////////////////////////////

module convoy_vl16_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;
    localparam IN16_BASE = DMEM_BASE;                 // pixel p: 16 words at p<<6
    localparam IN8_BASE  = DMEM_BASE + 32'h1_0000;    // pixel p:  8 words at p<<5
    localparam W_BASE    = DMEM_BASE + 32'h2_0000;    // weights, word = tap*16 + oc
    localparam SYN_BASE  = DMEM_BASE + 32'h4_0000;    // synthetic rows, 16 words each
    localparam OUT_BASE  = DMEM_BASE + 32'h6_0000;

    localparam [3:0] K_EMPTY = 4'd0, K_LOAD = 4'd1, K_MAC = 4'd2, K_STORE = 4'd3,
                     K_RELU = 4'd4, K_MUL = 4'd5, K_RUNNOP = 4'd6;

    // vl=16 register plan (two registers per vector)
    localparam [4:0] X0 = 5'd1,     // input vectors  v1/2, v3/4, v5/6, v7/8
                     ACC = 5'd9,    // accumulator    v9/10
                     ZERO = 5'd11,  // zero pair      v11/12 (never written)
                     W0 = 5'd13;    // tap t weights  v(13+2t)/(14+2t), t = 0..8 -> v13..v30

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

    v_wrapper dut (
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

    // Read by convoy_vl16_trace.tcl
    reg       trace_print;
    reg       sim_done;
    reg [7:0] trace_slots;

    // ---------------------------------------------------------------------
    // Convoy programme: up to 16 convoys of 8 slots, index = convoy*8 + slot
    // ---------------------------------------------------------------------
    reg  [3:0]  p_kind [0:127];
    reg  [4:0]  p_vd   [0:127];
    reg  [4:0]  p_vs1  [0:127];
    reg  [4:0]  p_vs2  [0:127];
    reg  [31:0] p_addr [0:127];
    reg  [2:0]  c_last [0:15];     // last slot issued for this convoy
    reg  [4:0]  c_clr  [0:15];     // early clear when wait_cnt reaches this
    integer     n_conv;
    reg         early;
    reg         go;

    // ---------------------------------------------------------------------
    // Mini controller: same structure as hbm_lite_controller S_ISSUE/S_WAIT/S_NEXT
    // ---------------------------------------------------------------------
    localparam [1:0] F_IDLE = 2'd0, F_ISSUE = 2'd1, F_WAIT = 2'd2, F_NEXT = 2'd3;
    reg [1:0] st;
    reg [3:0] conv;
    reg [2:0] issue_cnt;
    reg [4:0] wait_cnt;
    reg       seen_busy;
    reg       fsm_done;
    integer   fsm_cycles;

    task set_idle;     // exactly the controller's set_vec_idle: idle write to slot 7
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

    task drive(input [3:0] c, input [2:0] s);
        reg [6:0] k;
    begin
        k = {c[3:0], s};
        I_id <= s;
        case (p_kind[k])
            K_LOAD: begin
                I_start <= 1'b1;  I_vd <= p_vd[k];  I_RS1 <= p_addr[k];
                I_dmr <= 1'b1;    I_reg_we <= 1'b1; I_mem_reg <= 1'b1;
            end
            K_MAC, K_MUL: begin
                I_start <= 1'b1;  I_vs1 <= p_vs1[k];  I_vs2 <= p_vs2[k];
                I_vd <= p_vd[k];  I_reg_we <= 1'b1;
                I_funct <= (p_kind[k] == K_MUL) ? 8'b00000010 : 8'b00000011;
            end
            K_RELU: begin
                I_start <= 1'b1;  I_vs1 <= p_vd[k];  I_vs2 <= p_vs2[k];
                I_vd <= p_vd[k];  I_funct <= 8'b00000101;  I_reg_we <= 1'b1;
            end
            K_STORE: begin
                I_start <= 1'b1;  I_vd <= p_vd[k];  I_RS1 <= p_addr[k];
                I_dmw <= 1'b1;
            end
            K_RUNNOP: I_start <= 1'b1;   // running no-op: counter runs, no side effect
            default: ;                   // K_EMPTY: start=0
        endcase
    end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            st <= F_IDLE;  conv <= 4'd0;  issue_cnt <= 3'd0;  wait_cnt <= 5'd0;
            seen_busy <= 1'b0;  fsm_done <= 1'b0;  fsm_cycles = 0;
            set_idle;
        end else begin
            set_idle;
            fsm_done <= 1'b0;
            if (st != F_IDLE) fsm_cycles = fsm_cycles + 1;
            case (st)
                F_IDLE: if (go) begin
                    conv <= 4'd0;  issue_cnt <= 3'd0;  seen_busy <= 1'b0;
                    fsm_cycles = 0;
                    st <= F_ISSUE;
                end
                F_ISSUE: begin
                    drive(conv, issue_cnt);
                    wait_cnt <= 5'd0;
                    if (!DONE_out) seen_busy <= 1'b1;
                    if (issue_cnt == c_last[conv]) st <= F_WAIT;
                    else issue_cnt <= issue_cnt + 3'd1;
                end
                F_WAIT: begin
                    if (c_last[conv] == 3'd7) drive(conv, 3'd7);
                    wait_cnt <= wait_cnt + 5'd1;
                    if (!DONE_out) seen_busy <= 1'b1;
                    if (early ? (wait_cnt == c_clr[conv]) : (seen_busy && DONE_out)) begin
                        I_clear <= 1'b1;
                        st <= F_NEXT;
                    end
                end
                F_NEXT: begin
                    issue_cnt <= 3'd0;  seen_busy <= 1'b0;
                    if (conv + 1 == n_conv) begin
                        st <= F_IDLE;  fsm_done <= 1'b1;
                    end else begin
                        conv <= conv + 4'd1;  st <= F_ISSUE;
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // proc interface helpers (only used while the unit is idle)
    // ---------------------------------------------------------------------
    integer i, j, b, t, e, p;
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

    // element e of the vector starting at register vreg (e/8 selects the register)
    task write_vec(input [4:0] vreg, input integer el, input [31:0] data);
    begin
        proc_write(VREG_BASE + ((vreg + el / 8) << 5) + ((el % 8) << 2), data);
    end
    endtask

    reg signed [31:0] got [0:15];
    reg signed [31:0] exp [0:15];
    integer nvals;
    integer total_good, total_checked;

    task read_vec(input [4:0] vreg);
    begin
        for (b = 0; b < nvals; b = b + 1) begin
            proc_read(VREG_BASE + ((vreg + b / 8) << 5) + ((b % 8) << 2), rd);
            got[b] = rd;
        end
    end
    endtask

    task read_mem(input [31:0] addr);
    begin
        for (b = 0; b < nvals; b = b + 1) begin
            proc_read(addr + (b << 2), rd);
            got[b] = rd;
        end
    end
    endtask

    task compare(input [8*10:1] what);
        integer good, lo, hi;
    begin
        good = 0;  lo = 0;  hi = 0;
        for (b = 0; b < nvals; b = b + 1)
            if (got[b] === exp[b]) begin
                good = good + 1;
                if (b < 8) lo = lo + 1; else hi = hi + 1;
            end
        total_good = total_good + good;  total_checked = total_checked + nvals;
        $display("    exp  [0..7]  = %0d %0d %0d %0d %0d %0d %0d %0d",
                 exp[0], exp[1], exp[2], exp[3], exp[4], exp[5], exp[6], exp[7]);
        $display("    got  [0..7]  = %0d %0d %0d %0d %0d %0d %0d %0d",
                 got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7]);
        if (nvals > 8) begin
            $display("    exp  [8..15] = %0d %0d %0d %0d %0d %0d %0d %0d",
                     exp[8], exp[9], exp[10], exp[11], exp[12], exp[13], exp[14], exp[15]);
            $display("    got  [8..15] = %0d %0d %0d %0d %0d %0d %0d %0d",
                     got[8], got[9], got[10], got[11], got[12], got[13], got[14], got[15]);
            $display("    %s: first pass (elements 0-7) %0d/8, second pass (elements 8-15) %0d/8 -> %s",
                     what, lo, hi, (good == nvals) ? "PASS" : "FAIL");
        end else
            $display("    %s: %0d/8 -> %s", what, good, (good == nvals) ? "PASS" : "FAIL");
    end
    endtask

    // ---------------------------------------------------------------------
    // Programme helpers
    // ---------------------------------------------------------------------
    task set_slot(input integer c, input integer s, input [3:0] kind,
                  input [4:0] vd, input [4:0] vs1, input [4:0] vs2, input [31:0] addr);
    begin
        p_kind[c * 8 + s] = kind;  p_vd[c * 8 + s] = vd;  p_vs1[c * 8 + s] = vs1;
        p_vs2[c * 8 + s] = vs2;    p_addr[c * 8 + s] = addr;
    end
    endtask

    // fill all 8 slots of convoy c with `filler`, issue all 8, clear vl cycles
    // after the last REAL slot (real_last)
    task init_convoy(input integer c, input [3:0] filler, input integer real_last, input integer veclen);
    begin
        for (j = 0; j < 8; j = j + 1) set_slot(c, j, filler, 5'd0, 5'd0, 5'd0, 32'd0);
        c_last[c] = 3'd7;
        c_clr[c]  = veclen - 1 - (7 - real_last);
    end
    endtask

    task run_fsm;
    begin
        @(posedge clk);  go <= 1'b1;
        @(posedge clk);  go <= 1'b0;
        @(posedge fsm_done);
        // let the pipeline drain before using the proc interface
        @(negedge clk);
        while (!DONE_out) @(negedge clk);
        repeat (4) @(posedge clk);
    end
    endtask

    // ---------------------------------------------------------------------
    // Data
    // ---------------------------------------------------------------------
    reg [31:0] input_mem  [0:511];
    reg [31:0] weight_mem [0:143];
    reg [31:0] golden     [0:575];

    function signed [31:0] relu(input signed [31:0] v);
        relu = (v < 0) ? 0 : v;
    endfunction
    function signed [31:0] xs(input integer r, input integer el);   // synthetic row r
        xs = (((r + el) % 2) ? -1 : 1) * (5 * r + el + 1);
    endfunction
    function signed [31:0] ws(input integer k, input integer el);   // synthetic weight k
        ws = (((k + 2 * el) % 3 == 0) ? -1 : 1) * (k + 2) * (el + 1);
    endfunction
    function signed [31:0] acc_init(input integer el);
        acc_init = ((el % 2) ? 1 : -1) * 50 * (el + 1);
    endfunction
    function [31:0] in16(input integer oh, input integer ow, input integer tap);
        in16 = IN16_BASE + ((((oh + tap / 3) * 8) + ow + (tap % 3)) << 6);
    endfunction
    function [31:0] in8(input integer oh, input integer ow, input integer tap);
        in8 = IN8_BASE + ((((oh + tap / 3) * 8) + ow + (tap % 3)) << 5);
    endfunction

    integer px_oh [0:2];
    integer px_ow [0:2];

    task poison_vl16_regs;
    begin
        for (j = 0; j < 8; j = j + 1)                 // input vectors v1..v8
            for (e = 0; e < 8; e = e + 1)
                proc_write(VREG_BASE + ((X0 + j) << 5) + (e << 2), 32'h0000_7777);
        for (e = 0; e < 16; e = e + 1) write_vec(ACC, e, 32'h0BAD_0000 + e);
    end
    endtask

    // 3 pixels, all 16 output channels at once
    task run_pix16(input relu_on, input early_i, input [3:0] filler, input integer run_idx);
        integer c, base, n;
        reg [31:0] oaddr;
    begin
        $display("");
        $display("=== PIX%0d: vl=16, %s, %s, unused slots = %s; pixels (%0d,%0d) (%0d,%0d) (%0d,%0d) ===", run_idx,
                 relu_on ? "4+4+1 fused ReLU (store in slot 5)" : "3+3+3 no ReLU (store in slot 6)",
                 early_i ? "early clear" : "wait for DONE",
                 (filler == K_RUNNOP) ? "running no-op" : "EMPTY (start=0)",
                 px_oh[0], px_ow[0], px_oh[1], px_ow[1], px_oh[2], px_ow[2]);
        vl = 9'd16;  early = early_i;
        for (t = 0; t < 9; t = t + 1)
            for (e = 0; e < 16; e = e + 1) write_vec(W0 + 2 * t, e, weight_mem[t * 16 + e]);
        poison_vl16_regs;
        for (p = 0; p < 3; p = p + 1)
            for (e = 0; e < 16; e = e + 1)
                proc_write(OUT_BASE + (run_idx << 12) + (p << 6) + (e << 2), 32'h0DEA_D000 + e);

        c = 0;
        for (p = 0; p < 3; p = p + 1) begin
            oaddr = OUT_BASE + (run_idx << 12) + (p << 6);
            if (relu_on) begin
                for (base = 0; base < 8; base = base + 4) begin
                    init_convoy(c, filler, 7, 16);
                    for (j = 0; j < 4; j = j + 1) begin
                        set_slot(c, j, K_LOAD, X0 + 2 * j, 5'd0, 5'd0, in16(px_oh[p], px_ow[p], base + j));
                        set_slot(c, 4 + j, (base + j == 0) ? K_MUL : K_MAC, ACC,
                                 X0 + 2 * j, W0 + 2 * (base + j), 32'd0);
                    end
                    c = c + 1;
                end
                init_convoy(c, filler, 5, 16);
                set_slot(c, 0, K_LOAD,  X0,  5'd0, 5'd0, in16(px_oh[p], px_ow[p], 8));
                set_slot(c, 3, K_MAC,   ACC, X0,   W0 + 16, 32'd0);
                set_slot(c, 4, K_RELU,  ACC, 5'd0, ZERO, 32'd0);
                set_slot(c, 5, K_STORE, ACC, 5'd0, 5'd0, oaddr);
                c = c + 1;
            end else begin
                for (base = 0; base < 9; base = base + 3) begin
                    init_convoy(c, filler, (base == 6) ? 6 : 5, 16);
                    for (j = 0; j < 3; j = j + 1) begin
                        set_slot(c, j, K_LOAD, X0 + 2 * j, 5'd0, 5'd0, in16(px_oh[p], px_ow[p], base + j));
                        set_slot(c, 3 + j, (base + j == 0) ? K_MUL : K_MAC, ACC,
                                 X0 + 2 * j, W0 + 2 * (base + j), 32'd0);
                    end
                    if (base == 6) set_slot(c, 6, K_STORE, ACC, 5'd0, 5'd0, oaddr);
                    c = c + 1;
                end
            end
        end
        n_conv = c;
        trace_slots = relu_on ? 8'b1111_0000 : 8'b0111_1000;
        trace_print = (run_idx == 2) || (run_idx == 5);
        fork
            run_fsm;
            begin   // print only the first pixel's convoys
                wait (conv == 4'd3);
                trace_print = 1'b0;
            end
        join
        trace_print = 1'b0;
        $display("    FSM cycles for 3 pixels (16 channels each) = %0d -> %0d per pixel", fsm_cycles, fsm_cycles / 3);
        nvals = 16;
        for (p = 0; p < 3; p = p + 1) begin
            for (b = 0; b < 16; b = b + 1) begin
                exp[b] = golden[(px_oh[p] * 6 + px_ow[p]) * 16 + b];
                if (relu_on) exp[b] = relu(exp[b]);
            end
            read_mem(OUT_BASE + (run_idx << 12) + (p << 6));
            compare("OUT (mem) ");
        end
    end
    endtask

    initial begin
        $readmemh("test1_input.hex",   input_mem);
        $readmemh("test1_weights.hex", weight_mem);
        $readmemh("test1_golden.hex",  golden);

        vl = 9'd8;  vcsr_quant = 2'b00;  go = 1'b0;  early = 1'b1;  n_conv = 0;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        trace_print = 1'b0;  sim_done = 1'b0;  trace_slots = 8'd0;
        total_good = 0;  total_checked = 0;

        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);

        // DMEM: input in both replications (pixel value = input_mem[p*8]), weights, synthetic rows
        for (p = 0; p < 64; p = p + 1) begin
            for (e = 0; e < 16; e = e + 1) proc_write(IN16_BASE + (p << 6) + (e << 2), input_mem[p * 8]);
            for (e = 0; e < 8;  e = e + 1) proc_write(IN8_BASE  + (p << 5) + (e << 2), input_mem[p * 8]);
        end
        for (i = 0; i < 144; i = i + 1) proc_write(W_BASE + (i << 2), weight_mem[i]);
        for (j = 0; j < 6; j = j + 1)
            for (e = 0; e < 16; e = e + 1) proc_write(SYN_BASE + (j << 6) + (e << 2), xs(j, e));

        px_oh[0] = 0;  px_ow[0] = 0;
        px_oh[1] = 2;  px_ow[1] = 5;
        px_oh[2] = 5;  px_ow[2] = 5;

        // ================= CAL: vl=8, live controller layout =================
        $display("");
        $display("=== CAL: vl=8, live-controller layout (3+3+3, store in slot 6, idle on slot 7, clear 8 after last slot), OC group 0, 3 pixels ===");
        vl = 9'd8;  early = 1'b1;
        for (t = 0; t < 9; t = t + 1)
            for (e = 0; e < 8; e = e + 1)
                proc_write(VREG_BASE + ((5'd16 + t) << 5) + (e << 2), weight_mem[t * 16 + e]);
        i = 0;
        for (p = 0; p < 3; p = p + 1)
            for (t = 0; t < 9; t = t + 3) begin
                for (j = 0; j < 8; j = j + 1) set_slot(i, j, K_EMPTY, 5'd0, 5'd0, 5'd0, 32'd0);
                for (j = 0; j < 3; j = j + 1) begin
                    set_slot(i, j, K_LOAD, 5'd1 + j, 5'd0, 5'd0, in8(px_oh[p], px_ow[p], t + j));
                    set_slot(i, 3 + j, (t + j == 0) ? K_MUL : K_MAC, 5'd8, 5'd1 + j, 5'd16 + t + j, 32'd0);
                end
                if (t == 6) set_slot(i, 6, K_STORE, 5'd8, 5'd0, 5'd0, OUT_BASE + (p << 5));
                c_last[i] = (t == 6) ? 3'd6 : 3'd5;
                c_clr[i]  = 5'd7;                       // controller: wait_cnt == 7
                i = i + 1;
            end
        n_conv = i;
        run_fsm;
        $display("    FSM cycles for 3 pixels (8 channels each) = %0d -> %0d per pixel (live controller: 46)", fsm_cycles, fsm_cycles / 3);
        nvals = 8;
        for (p = 0; p < 3; p = p + 1) begin
            for (b = 0; b < 8; b = b + 1) exp[b] = golden[(px_oh[p] * 6 + px_ow[p]) * 16 + b];
            read_mem(OUT_BASE + (p << 5));
            compare("OUT (mem) ");
        end

        // ================= SYN: synthetic vl=16, distinct mixed-sign =================
        vl = 9'd16;  early = 1'b1;  nvals = 16;
        for (j = 0; j < 3; j = j + 1)
            for (e = 0; e < 16; e = e + 1) write_vec(W0 + 2 * j, e, ws(j, e));
        for (e = 0; e < 16; e = e + 1) write_vec(ACC, e, acc_init(e));
        for (j = 0; j < 8; j = j + 1)
            for (e = 0; e < 8; e = e + 1)
                proc_write(VREG_BASE + ((X0 + j) << 5) + (e << 2), 32'h0000_7777);
        for (i = 0; i < 2; i = i + 1) begin
            $display("");
            $display("=== SYN%0d: vl=16, load v1/2 | load v3/4 | load v5/6 <- rows %0d..%0d | MAC x3 into v9/10 | store | no-op; early clear ===",
                     i + 1, 3 * i, 3 * i + 2);
            for (e = 0; e < 16; e = e + 1)
                proc_write(OUT_BASE + 32'hF000 + (i << 6) + (e << 2), 32'h0DEA_D000 + e);
            init_convoy(0, K_RUNNOP, 6, 16);
            for (j = 0; j < 3; j = j + 1) begin
                set_slot(0, j, K_LOAD, X0 + 2 * j, 5'd0, 5'd0, SYN_BASE + ((3 * i + j) << 6));
                set_slot(0, 3 + j, K_MAC, ACC, X0 + 2 * j, W0 + 2 * j, 32'd0);
            end
            set_slot(0, 6, K_STORE, ACC, 5'd0, 5'd0, OUT_BASE + 32'hF000 + (i << 6));
            n_conv = 1;
            trace_slots = 8'b0111_0000;  trace_print = 1'b1;
            run_fsm;
            trace_print = 1'b0;
            $display("    FSM cycles = %0d", fsm_cycles);
            for (b = 0; b < 16; b = b + 1) begin
                if (i == 0) exp[b] = acc_init(b);
                for (j = 0; j < 3; j = j + 1) exp[b] = exp[b] + xs(3 * i + j, b) * ws(j, b);
            end
            read_mem(OUT_BASE + 32'hF000 + (i << 6));  compare("OUT (mem) ");
            read_vec(ACC);                              compare("acc (vrf) ");
        end

        // ================= WL: weight preload convoy =================
        $display("");
        $display("=== WL: vl=16, load taps 0,1,2 (16 weights each) from DMEM into v13/14, v15/16, v17/18 | 5 no-ops; early clear ===");
        for (j = 13; j <= 18; j = j + 1)
            for (e = 0; e < 8; e = e + 1) proc_write(VREG_BASE + (j << 5) + (e << 2), 32'h0000_7777);
        init_convoy(0, K_RUNNOP, 2, 16);
        for (j = 0; j < 3; j = j + 1)
            set_slot(0, j, K_LOAD, W0 + 2 * j, 5'd0, 5'd0, W_BASE + ((j * 16) << 2));
        n_conv = 1;
        run_fsm;
        $display("    FSM cycles = %0d", fsm_cycles);
        for (j = 0; j < 3; j = j + 1) begin
            for (b = 0; b < 16; b = b + 1) exp[b] = weight_mem[j * 16 + b];
            read_vec(W0 + 2 * j);
            compare("tap (vrf) ");
        end

        // ================= PIX: real conv data =================
        run_pix16(1'b0, 1'b0, K_RUNNOP, 1);   // 3+3+3, wait for DONE
        run_pix16(1'b0, 1'b1, K_RUNNOP, 2);   // 3+3+3, early clear        (traced)
        run_pix16(1'b1, 1'b0, K_RUNNOP, 3);   // 4+4+1 ReLU, wait for DONE
        run_pix16(1'b1, 1'b1, K_RUNNOP, 4);   // 4+4+1 ReLU, early clear
        $display("");
        $display("SUBTOTAL before NEG: %0d of %0d compared elements correct -> %s", total_good, total_checked,
                 (total_good == total_checked) ? "ALL PASS" : "FAILURES");

        // ================= NEG: unused slots truly empty =================
        run_pix16(1'b0, 1'b1, K_EMPTY, 5);    // expected to FAIL on the second pass (traced)

        sim_done = 1'b1;
        repeat (2) @(posedge clk);
        $finish;
    end

endmodule
