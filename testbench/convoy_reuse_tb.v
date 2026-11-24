`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_reuse_tb
//
// Isolated slot-reuse tests on v_wrapper alone (no atee_top, no DMA), vl=8:
// can a finished slot be re-issued WITHOUT clearing the whole instruction bank?
//
// The unit is driven from a per-cycle TIMELINE: entry w is what is on the
// instruction wires during cycle w (it lands in the bank at the end of cycle
// w, so the slot is live from cycle w+1). The instruction bank has no write
// enable, so a cycle with no entry writes idle (start=0) into slot 7, which no
// test uses -- the live controller's idle convention.
//
// Boundary tests (synthetic rows, every destination register poisoned first):
//   T1  overwrite a finished slot directly, no idle write
//   T2  idle write, then re-issue; slot 0 alone
//   T3  re-issue slot 1 at a slot-0 count NOT congruent mod 8, slot 0 running
//   T4  re-issue slot 1 mod-8 aligned, slot 0 left running past count 16
//   T5  re-issue slot 0 (single idle cycle, at count 16) and slot 1, aligned
//
// T6  three output pixels back to back on real conv data with NO clear at all:
//     16-cycle frames, slot j re-issued at frame offset j, slots 1..6 idled at
//     offset j+8, slot 0 idled for exactly one cycle at offset 15.
//       frame 1: L0 L1 L2 | MUL0 MAC1 MAC2 | L3
//       frame 2: L4 L5 | MAC3 MAC4 MAC5 | L6 L7
//       frame 3: L8 | MAC6 MAC7 MAC8 | store | (slots 5,6 stay idle)
//////////////////////////////////////////////////////////////////////////////////

module convoy_reuse_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;
    localparam IN_BASE   = DMEM_BASE;                 // real input, pixel p at p<<5
    localparam SYN_BASE  = DMEM_BASE + 32'h4_0000;    // synthetic rows, 8 words each
    localparam OUT_BASE  = DMEM_BASE + 32'h6_0000;

    localparam [3:0] K_IDLE = 4'd0, K_LOAD = 4'd1, K_MAC = 4'd2, K_STORE = 4'd3, K_MUL = 4'd5;
    localparam [4:0] V_ACC = 5'd8, V_W0 = 5'd16;

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

    // Read by convoy_reuse_trace.tcl
    reg       trace_print;
    reg       sim_done;
    reg [7:0] trace_slots;

    // ---------------------------------------------------------------------
    // Timeline
    // ---------------------------------------------------------------------
    localparam TL = 512;
    reg         t_valid [0:TL-1];
    reg  [2:0]  t_id    [0:TL-1];
    reg  [3:0]  t_kind  [0:TL-1];
    reg  [4:0]  t_vd    [0:TL-1];
    reg  [4:0]  t_vs1   [0:TL-1];
    reg  [4:0]  t_vs2   [0:TL-1];
    reg  [31:0] t_addr  [0:TL-1];
    integer     t_len;       // cycles to play; I_clear is driven on cycle t_len
    reg         go;
    reg         playing;
    reg         play_done;
    integer     w;           // current wire cycle
    integer     stall_cycles;

    task set_idle;           // idle write to slot 7
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

    always @(posedge clk) begin
        if (reset) begin
            playing <= 1'b0;  play_done <= 1'b0;  w = 0;  stall_cycles = 0;
            set_idle;
        end else begin
            set_idle;
            play_done <= 1'b0;
            if (!playing) begin
                if (go) begin
                    playing <= 1'b1;  w = 0;  stall_cycles = 0;
                end
            end else begin
                if (stall_out) stall_cycles = stall_cycles + 1;
                if (w == t_len) begin
                    I_clear <= 1'b1;
                    playing <= 1'b0;  play_done <= 1'b1;
                end else if (t_valid[w]) begin
                    I_id <= t_id[w];
                    case (t_kind[w])
                        K_LOAD: begin
                            I_start <= 1'b1;  I_vd <= t_vd[w];  I_RS1 <= t_addr[w];
                            I_dmr <= 1'b1;    I_reg_we <= 1'b1; I_mem_reg <= 1'b1;
                        end
                        K_MAC, K_MUL: begin
                            I_start <= 1'b1;  I_vs1 <= t_vs1[w];  I_vs2 <= t_vs2[w];
                            I_vd <= t_vd[w];  I_reg_we <= 1'b1;
                            I_funct <= (t_kind[w] == K_MUL) ? 8'b00000010 : 8'b00000011;
                        end
                        K_STORE: begin
                            I_start <= 1'b1;  I_vd <= t_vd[w];  I_RS1 <= t_addr[w];
                            I_dmw <= 1'b1;
                        end
                        default: ;   // K_IDLE: start=0 written into slot t_id
                    endcase
                end
                w = w + 1;
            end
        end
    end

    integer i, j, b, t, e, p;
    reg [31:0] rd;

    task tl_clear;
    begin
        for (i = 0; i < TL; i = i + 1) t_valid[i] = 1'b0;
    end
    endtask

    task at(input integer wc, input [2:0] id, input [3:0] kind,
            input [4:0] vd, input [4:0] vs1, input [4:0] vs2, input [31:0] addr);
    begin
        t_valid[wc] = 1'b1;  t_id[wc] = id;  t_kind[wc] = kind;
        t_vd[wc] = vd;  t_vs1[wc] = vs1;  t_vs2[wc] = vs2;  t_addr[wc] = addr;
    end
    endtask

    task play;
    begin
        @(posedge clk);  go <= 1'b1;
        @(posedge clk);  go <= 1'b0;
        @(posedge play_done);
        @(negedge clk);
        while (!DONE_out) @(negedge clk);
        repeat (4) @(posedge clk);
    end
    endtask

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

    localparam [31:0] POISON = 32'h0000_7777;

    task poison_reg(input [4:0] vreg);
    begin
        for (e = 0; e < 8; e = e + 1)
            proc_write(VREG_BASE + (vreg << 5) + (e << 2), POISON);
    end
    endtask

    reg signed [31:0] got [0:7];
    reg signed [31:0] exp [0:7];
    integer total_good, total_checked;

    task read_reg(input [4:0] vreg);
    begin
        for (b = 0; b < 8; b = b + 1) begin
            proc_read(VREG_BASE + (vreg << 5) + (b << 2), rd);
            got[b] = rd;
        end
    end
    endtask

    task read_mem(input [31:0] addr);
    begin
        for (b = 0; b < 8; b = b + 1) begin
            proc_read(addr + (b << 2), rd);
            got[b] = rd;
        end
    end
    endtask

    // show one register against an expected row; count==1 adds it to the totals
    task show(input [8*22:1] what, input count);
        integer good;
    begin
        good = 0;
        for (b = 0; b < 8; b = b + 1)
            if (got[b] === exp[b]) good = good + 1;
        if (count) begin
            total_good = total_good + good;  total_checked = total_checked + 8;
        end
        $display("    %s exp = %0d %0d %0d %0d %0d %0d %0d %0d", what,
                 exp[0], exp[1], exp[2], exp[3], exp[4], exp[5], exp[6], exp[7]);
        $display("    %s got = %0d %0d %0d %0d %0d %0d %0d %0d   -> %0d/8 %s", what,
                 got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7],
                 good, (good == 8) ? "correct" : "WRONG");
    end
    endtask

    // synthetic row r: distinct mixed-sign values, different for every row
    function signed [31:0] xs(input integer r, input integer el);
        xs = (((r + el) % 2) ? -1 : 1) * (100 * (r + 1) + el);
    endfunction
    function [31:0] row(input integer r);
        row = SYN_BASE + (r << 5);
    endfunction
    task expect_row(input integer r);
    begin
        for (b = 0; b < 8; b = b + 1) exp[b] = xs(r, b);
    end
    endtask
    task expect_poison;
    begin
        for (b = 0; b < 8; b = b + 1) exp[b] = POISON;
    end
    endtask

    // ---------------------------------------------------------------------
    // T6 data
    // ---------------------------------------------------------------------
    reg [31:0] input_mem  [0:511];
    reg [31:0] weight_mem [0:143];
    reg [31:0] golden     [0:575];

    function [31:0] in_addr(input integer oh, input integer ow, input integer tap);
        in_addr = IN_BASE + ((((oh + tap / 3) * 8) + ow + (tap % 3)) << 5);
    endfunction
    function [4:0] xreg(input integer tap);    // one register per tap: v1..v7, v10, v11
        xreg = (tap < 7) ? 5'd1 + tap : 5'd3 + tap;
    endfunction

    integer px_oh [0:2];
    integer px_ow [0:2];

    task ld(input integer f, input integer s, input integer pp, input integer tap);
    begin
        at(16 * f + s, s[2:0], K_LOAD, xreg(tap), 5'd0, 5'd0, in_addr(px_oh[pp], px_ow[pp], tap));
    end
    endtask
    task mc(input integer f, input integer s, input integer tap);
    begin
        at(16 * f + s, s[2:0], (tap == 0) ? K_MUL : K_MAC, V_ACC, xreg(tap), V_W0 + tap, 32'd0);
    end
    endtask

    task run_rolling(input integer g, input integer run_idx);
        integer f, frames;
    begin
        $display("");
        $display("=== T6.%0d: rolling re-issue, NO clear, OC group %0d, 3 pixels x 3 frames of 16 cycles; pixels (%0d,%0d) (%0d,%0d) (%0d,%0d) ===",
                 run_idx, g, px_oh[0], px_ow[0], px_oh[1], px_ow[1], px_oh[2], px_ow[2]);
        for (t = 0; t < 9; t = t + 1)
            for (e = 0; e < 8; e = e + 1)
                proc_write(VREG_BASE + ((V_W0 + t) << 5) + (e << 2), weight_mem[t * 16 + g * 8 + e]);
        for (t = 0; t < 9; t = t + 1) poison_reg(xreg(t));
        for (e = 0; e < 8; e = e + 1) proc_write(VREG_BASE + (V_ACC << 5) + (e << 2), 32'h0BAD_0000 + e);
        for (p = 0; p < 3; p = p + 1)
            for (e = 0; e < 8; e = e + 1)
                proc_write(OUT_BASE + (run_idx << 12) + (p << 5) + (e << 2), 32'h0DEA_D000 + e);

        tl_clear;
        frames = 9;
        for (p = 0; p < 3; p = p + 1) begin
            f = 3 * p;
            ld(f, 0, p, 0);  ld(f, 1, p, 1);  ld(f, 2, p, 2);
            mc(f, 3, 0);     mc(f, 4, 1);     mc(f, 5, 2);
            ld(f, 6, p, 3);
            ld(f + 1, 0, p, 4);  ld(f + 1, 1, p, 5);
            mc(f + 1, 2, 3);     mc(f + 1, 3, 4);     mc(f + 1, 4, 5);
            ld(f + 1, 5, p, 6);  ld(f + 1, 6, p, 7);
            ld(f + 2, 0, p, 8);
            mc(f + 2, 1, 6);     mc(f + 2, 2, 7);     mc(f + 2, 3, 8);
            at(16 * (f + 2) + 4, 3'd4, K_STORE, V_ACC, 5'd0, 5'd0, OUT_BASE + (run_idx << 12) + (p << 5));
        end
        // idle writes: slots 1..6 once they have issued 8 elements, slot 0 for
        // exactly one cycle before its next issue
        for (f = 0; f < frames; f = f + 1) begin
            for (j = 1; j <= 6; j = j + 1)
                at(16 * f + j + 8, j[2:0], K_IDLE, 5'd0, 5'd0, 5'd0, 32'd0);
            if (f < frames - 1)
                at(16 * f + 15, 3'd0, K_IDLE, 5'd0, 5'd0, 5'd0, 32'd0);
        end
        t_len = 16 * frames;
        trace_slots = 8'b0011_1000;
        trace_print = (run_idx == 1);
        fork
            play;
            begin
                wait (playing);          // w still holds the previous test's count until then
                wait (w >= 40);
                trace_print = 1'b0;
            end
        join
        trace_print = 1'b0;
        $display("    %0d cycles for 3 pixels -> %0d per pixel (live controller with clear: 46), stall cycles = %0d",
                 t_len, t_len / 3, stall_cycles);
        for (p = 0; p < 3; p = p + 1) begin
            for (b = 0; b < 8; b = b + 1) exp[b] = golden[(px_oh[p] * 6 + px_ow[p]) * 16 + g * 8 + b];
            read_mem(OUT_BASE + (run_idx << 12) + (p << 5));
            show("OUT (mem)", 1'b1);
        end
    end
    endtask

    initial begin
        $readmemh("test1_input.hex",   input_mem);
        $readmemh("test1_weights.hex", weight_mem);
        $readmemh("test1_golden.hex",  golden);

        vl = 9'd8;  vcsr_quant = 2'b00;  go = 1'b0;  t_len = 0;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        trace_print = 1'b0;  sim_done = 1'b0;  trace_slots = 8'd0;
        total_good = 0;  total_checked = 0;

        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);

        for (i = 0; i < 512; i = i + 1) proc_write(IN_BASE + (i << 2), input_mem[i]);
        for (j = 0; j < 8; j = j + 1)
            for (e = 0; e < 8; e = e + 1) proc_write(SYN_BASE + (j << 5) + (e << 2), xs(j, e));

        // ================= T1 =================
        $display("");
        $display("=== T1: slot 0 load row0->v1 at cycle 0; slot 0 OVERWRITTEN directly with load row1->v2 at cycle 10 (no idle write) ===");
        for (j = 1; j <= 5; j = j + 1) poison_reg(j);
        tl_clear;
        at(0,  3'd0, K_LOAD, 5'd1, 5'd0, 5'd0, row(0));
        at(10, 3'd0, K_LOAD, 5'd2, 5'd0, 5'd0, row(1));
        t_len = 30;  trace_slots = 8'd0;  trace_print = 1'b1;
        play;  trace_print = 1'b0;
        read_reg(5'd1);  expect_row(0);   show("v1 (first load)      ", 1'b0);
        read_reg(5'd2);  expect_row(1);   show("v2 (overwriting load)", 1'b0);

        // ================= T2 =================
        $display("");
        $display("=== T2: slot 0 load row0->v1 at cycle 0; IDLE into slot 0 at cycle 9; slot 0 load row1->v2 at cycle 10; slot 0 alone ===");
        for (j = 1; j <= 5; j = j + 1) poison_reg(j);
        tl_clear;
        at(0,  3'd0, K_LOAD, 5'd1, 5'd0, 5'd0, row(0));
        at(9,  3'd0, K_IDLE, 5'd0, 5'd0, 5'd0, 32'd0);
        at(10, 3'd0, K_LOAD, 5'd2, 5'd0, 5'd0, row(1));
        t_len = 30;  trace_print = 1'b1;
        play;  trace_print = 1'b0;
        read_reg(5'd1);  expect_row(0);   show("v1 (first load)      ", 1'b0);
        read_reg(5'd2);  expect_row(1);   show("v2 (re-issued load)  ", 1'b0);

        // ================= T3 =================
        $display("");
        $display("=== T3: slot 0 load row0->v1 (cycle 0, left running); slot 1 load row1->v2 (cycle 1); IDLE slot 1 at 10; slot 1 load row2->v3 at cycle 12 (NOT aligned mod 8) ===");
        for (j = 1; j <= 5; j = j + 1) poison_reg(j);
        tl_clear;
        at(0,  3'd0, K_LOAD, 5'd1, 5'd0, 5'd0, row(0));
        at(1,  3'd1, K_LOAD, 5'd2, 5'd0, 5'd0, row(1));
        at(10, 3'd1, K_IDLE, 5'd0, 5'd0, 5'd0, 32'd0);
        at(12, 3'd1, K_LOAD, 5'd3, 5'd0, 5'd0, row(2));
        t_len = 34;  trace_print = 1'b1;
        play;  trace_print = 1'b0;
        read_reg(5'd2);  expect_row(1);   show("v2 (slot 1, round 1) ", 1'b0);
        read_reg(5'd3);  expect_row(2);   show("v3 (slot 1, re-issue)", 1'b0);

        // ================= T4 =================
        $display("");
        $display("=== T4: as T3 but slot 1 re-issued at cycle 17 (aligned mod 8); slot 0 still holds its FIRST instruction, counter past 16 ===");
        for (j = 1; j <= 5; j = j + 1) poison_reg(j);
        tl_clear;
        at(0,  3'd0, K_LOAD, 5'd1, 5'd0, 5'd0, row(0));
        at(1,  3'd1, K_LOAD, 5'd2, 5'd0, 5'd0, row(1));
        at(10, 3'd1, K_IDLE, 5'd0, 5'd0, 5'd0, 32'd0);
        at(17, 3'd1, K_LOAD, 5'd3, 5'd0, 5'd0, row(2));
        t_len = 40;  trace_print = 1'b1;
        play;  trace_print = 1'b0;
        read_reg(5'd3);  expect_row(2);   show("v3 (slot 1, re-issue)", 1'b0);
        read_reg(5'd5);  expect_poison;   show("v5 (should be poison)", 1'b0);

        // ================= T5 =================
        $display("");
        $display("=== T5: slot 0 row0->v1 (0), slot 1 row1->v2 (1); IDLE slot 1 at 10; IDLE slot 0 at 15 (one cycle); slot 0 row3->v4 at 16; slot 1 row2->v3 at 17 ===");
        for (j = 1; j <= 5; j = j + 1) poison_reg(j);
        tl_clear;
        at(0,  3'd0, K_LOAD, 5'd1, 5'd0, 5'd0, row(0));
        at(1,  3'd1, K_LOAD, 5'd2, 5'd0, 5'd0, row(1));
        at(10, 3'd1, K_IDLE, 5'd0, 5'd0, 5'd0, 32'd0);
        at(15, 3'd0, K_IDLE, 5'd0, 5'd0, 5'd0, 32'd0);
        at(16, 3'd0, K_LOAD, 5'd4, 5'd0, 5'd0, row(3));
        at(17, 3'd1, K_LOAD, 5'd3, 5'd0, 5'd0, row(2));
        t_len = 40;  trace_print = 1'b1;
        play;  trace_print = 1'b0;
        read_reg(5'd1);  expect_row(0);   show("v1 (slot 0, round 1) ", 1'b1);
        read_reg(5'd2);  expect_row(1);   show("v2 (slot 1, round 1) ", 1'b1);
        read_reg(5'd4);  expect_row(3);   show("v4 (slot 0, re-issue)", 1'b1);
        read_reg(5'd3);  expect_row(2);   show("v3 (slot 1, re-issue)", 1'b1);
        read_reg(5'd5);  expect_poison;   show("v5 (should be poison)", 1'b1);

        // ================= T6 =================
        px_oh[0] = 0;  px_ow[0] = 0;
        px_oh[1] = 2;  px_ow[1] = 5;
        px_oh[2] = 5;  px_ow[2] = 5;
        run_rolling(0, 1);
        run_rolling(1, 2);

        $display("");
        $display("TOTAL (T5 + T6): %0d of %0d compared elements correct -> %s", total_good, total_checked,
                 (total_good == total_checked) ? "ALL PASS" : "FAILURES");
        sim_done = 1'b1;
        repeat (2) @(posedge clk);
        $finish;
    end

endmodule
