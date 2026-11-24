`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_chunk_tb   (NEW, 2026-11-16; RTL stage 1 of
//                            docs/chunked_taps_design.md section 7, item 1)
//
// Isolated chunk-boundary test on v_wrapper alone (no atee_top, no DMA,
// unchanged RTL). The unit is driven by the same mini controller as
// convoy_vl16_tb.v (F_ISSUE / F_WAIT / F_NEXT, registered outputs, idle write to
// slot 7 unless the convoy's last issued slot is 7, early clear on a fixed
// wait count).
//
// Real conv8_3 data (test1_*.hex), 3 pixels (0,0) (2,5) (5,5). The 9 taps are
// split into TWO chunks, run in the chunked loop order (chunk outer, pixel
// inner):
//   run A : preload chunk 0 (taps 0..3) into the tap registers, then per pixel
//           [X t0 t1 t2 | MUL MAC MAC] and [X t3 | - | MAC | STORE]
//           -> partial sums of taps 0..3 stored in the pixels' output rows
//   (between runs: accumulator, input and tap registers POISONED)
//   run B : preload chunk 1 (taps 4..8) into the SAME tap registers, then per
//           pixel [PSUM | X t4 t5 t6 | MAC MAC MAC] and [X t7 t8 | MAC MAC | STORE]
//           PSUM = unit-stride load of the pixel's own output row into the
//           accumulator in slot 0; the first MAC (slot 4) reads it 4 slots
//           later (register-file path, as the measured 4-tap convoy).
// Checked: the partial sums after run A (memory) against taps 0..3 computed
// here, the final outputs after run B (memory) against test1_golden.hex.
// Rules: no load directly before its reader, store never in slot 7, unit-stride
// loads only, at vl=16 every unused slot holds a running no-op.
// NEG: run B with the PSUM slot holding a running no-op (accumulator stays
// poisoned) -> must FAIL.
//////////////////////////////////////////////////////////////////////////////////

module convoy_chunk_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;
    localparam IN16_BASE = DMEM_BASE;                 // pixel p: 16 words at p<<6
    localparam IN8_BASE  = DMEM_BASE + 32'h1_0000;    // pixel p:  8 words at p<<5
    localparam W_BASE    = DMEM_BASE + 32'h2_0000;    // weights, word = tap*16 + oc
    localparam OUT_BASE  = DMEM_BASE + 32'h6_0000;

    localparam [3:0] K_EMPTY = 4'd0, K_LOAD = 4'd1, K_MAC = 4'd2, K_STORE = 4'd3,
                     K_RELU = 4'd4, K_MUL = 4'd5, K_RUNNOP = 4'd6;

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

    // ---------------------------------------------------------------------
    // Convoy programme: up to 16 convoys of 8 slots, index = convoy*8 + slot
    // ---------------------------------------------------------------------
    reg  [3:0]  p_kind [0:127];
    reg  [4:0]  p_vd   [0:127];
    reg  [4:0]  p_vs1  [0:127];
    reg  [4:0]  p_vs2  [0:127];
    reg  [31:0] p_addr [0:127];
    reg  [2:0]  c_last [0:15];
    reg  [4:0]  c_clr  [0:15];
    integer     n_conv;
    reg         early;
    reg         go;

    // ---- mini controller, identical to convoy_vl16_tb.v
    localparam [1:0] F_IDLE = 2'd0, F_ISSUE = 2'd1, F_WAIT = 2'd2, F_NEXT = 2'd3;
    reg [1:0] st;
    reg [3:0] conv;
    reg [2:0] issue_cnt;
    reg [4:0] wait_cnt;
    reg       seen_busy;
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
            st <= F_IDLE;  conv <= 4'd0;  issue_cnt <= 3'd0;  wait_cnt <= 5'd0;
            seen_busy <= 1'b0;  fsm_done <= 1'b0;  fsm_cycles = 0;  stall_cycles = 0;
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
                    conv <= 4'd0;  issue_cnt <= 3'd0;  seen_busy <= 1'b0;
                    fsm_cycles = 0;  stall_cycles = 0;
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
    integer i, j, b, t, e, p, g;
    reg [31:0] rd;
    // data (declared before the tasks that use them)
    reg [31:0] input_mem  [0:511];
    reg [31:0] weight_mem [0:143];
    reg [31:0] golden     [0:575];
    integer px_oh [0:2];
    integer px_ow [0:2];
    reg psum_nop;

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

    reg signed [31:0] got [0:15];
    reg signed [31:0] exp [0:15];
    integer nvals;
    integer total_good, total_checked, neg_good, neg_checked;
    reg     in_neg;

    task read_mem(input [31:0] addr);
    begin
        for (b = 0; b < nvals; b = b + 1) begin
            proc_read(addr + (b << 2), rd);
            got[b] = rd;
        end
    end
    endtask

    task compare(input [8*32:1] what);
        integer good;
    begin
        good = 0;
        for (b = 0; b < nvals; b = b + 1) if (got[b] === exp[b]) good = good + 1;
        if (in_neg) begin neg_good = neg_good + good; neg_checked = neg_checked + nvals; end
        else begin total_good = total_good + good; total_checked = total_checked + nvals; end
        $display("    exp [0..7] = %0d %0d %0d %0d %0d %0d %0d %0d", exp[0], exp[1], exp[2], exp[3], exp[4], exp[5], exp[6], exp[7]);
        $display("    got [0..7] = %0d %0d %0d %0d %0d %0d %0d %0d", got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7]);
        if (nvals > 8) begin
            $display("    exp [8..15]= %0d %0d %0d %0d %0d %0d %0d %0d", exp[8], exp[9], exp[10], exp[11], exp[12], exp[13], exp[14], exp[15]);
            $display("    got [8..15]= %0d %0d %0d %0d %0d %0d %0d %0d", got[8], got[9], got[10], got[11], got[12], got[13], got[14], got[15]);
        end
        $display("    %s: %0d/%0d -> %s", what, good, nvals, (good == nvals) ? "PASS" : "FAIL");
    end
    endtask

    // ---------------------------------------------------------------------
    // Programme helpers
    // ---------------------------------------------------------------------
    task set_slot(input integer c, input integer s, input [3:0] kind,
                  input [4:0] vd, input [4:0] vs1, input [4:0] vs2, input [31:0] addr);
    begin
        if (kind == K_STORE && s == 7) $display("ERROR: store placed in slot 7 (rule 2)");
        p_kind[c * 8 + s] = kind;  p_vd[c * 8 + s] = vd;  p_vs1[c * 8 + s] = vs1;
        p_vs2[c * 8 + s] = vs2;    p_addr[c * 8 + s] = addr;
    end
    endtask

    // start convoy c; vl=8: empty filler, issue up to the last real slot, clear
    // 8 cycles after it (wait_cnt 7, the live controller); vl=16: every slot a
    // running no-op, all 8 issued, clear 16 cycles after the last real slot
    // (convoy_vl16_tb.v init_convoy).
    task finish_convoy(input integer c, input integer real_last);
    begin
        if (vl == 9'd16) begin
            for (j = 0; j < 8; j = j + 1) if (p_kind[c * 8 + j] == K_EMPTY) p_kind[c * 8 + j] = K_RUNNOP;
            c_last[c] = 3'd7;
            c_clr[c]  = 16 - 1 - (7 - real_last);
        end else begin
            c_last[c] = real_last;
            c_clr[c]  = 5'd7;
        end
    end
    endtask

    task clear_convoy(input integer c);
    begin
        for (j = 0; j < 8; j = j + 1) set_slot(c, j, K_EMPTY, 5'd0, 5'd0, 5'd0, 32'd0);
    end
    endtask

    integer slot_model;    // per-convoy controller cost from the slot layout (printed for the record)

    // register plan
    reg [4:0] X0, ACC, W0, STEP;          // STEP = registers per vector (1 or 2)

    function [31:0] in_addr(input integer oh, input integer ow, input integer tap);
        in_addr = (vl == 9'd16) ? IN16_BASE + ((((oh + tap / 3) * 8) + ow + (tap % 3)) << 6)
                                : IN8_BASE  + ((((oh + tap / 3) * 8) + ow + (tap % 3)) << 5);
    endfunction
    function [31:0] out_addr(input integer run, input integer pix);
        out_addr = OUT_BASE + (run << 12) + ((vl == 9'd16) ? (pix << 6) : (pix << 5));
    endfunction
    function [31:0] w_addr(input integer tap);        // group g selects oc 8g..8g+7 at vl=8
        w_addr = W_BASE + ((tap * 16) << 2) + ((vl == 9'd16) ? 0 : (g << 5));
    endfunction

    // preload taps t0..t1 into W0 + STEP*(t - t0), convoys of <= 3 loads; returns next convoy index
    task add_preload(inout integer c, input integer t0, input integer t1);
        integer k, n;
    begin
        k = t0;
        while (k <= t1) begin
            n = (t1 - k + 1 >= 3) ? 3 : (t1 - k + 1);
            clear_convoy(c);
            for (j = 0; j < n; j = j + 1) set_slot(c, j, K_LOAD, W0 + STEP * (k + j - t0), 5'd0, 5'd0, w_addr(k + j));
            finish_convoy(c, n - 1);
            slot_model = slot_model + ((vl == 9'd16) ? (n - 1) + 18 : (n - 1) + 10);
            c = c + 1;  k = k + n;
        end
    end
    endtask

    // one compute convoy for pixel pix: taps ta..tb (<= 3) of a chunk starting at tc0
    task add_compute(inout integer c, input integer pix, input integer ta, input integer tb, input integer tc0,
                     input psum, input first_mul, input store, input integer run);
        integer s, n, m0, last;
    begin
        clear_convoy(c);
        s = 0;
        n = tb - ta + 1;
        if (psum) begin set_slot(c, 0, K_LOAD, ACC, 5'd0, 5'd0, out_addr(run, pix)); s = 1; end
        if (psum_nop && psum) set_slot(c, 0, K_RUNNOP, 5'd0, 5'd0, 5'd0, 32'd0);
        for (j = 0; j < n; j = j + 1)
            set_slot(c, s + j, K_LOAD, X0 + STEP * j, 5'd0, 5'd0, in_addr(px_oh[pix], px_ow[pix], ta + j));
        m0 = (n == 1) ? s + 2 : s + n;            // rule 1: a 1-tap convoy needs a gap
        for (j = 0; j < n; j = j + 1)
            set_slot(c, m0 + j, (first_mul && j == 0) ? K_MUL : K_MAC, ACC, X0 + STEP * j,
                     W0 + STEP * (ta + j - tc0), 32'd0);
        last = m0 + n - 1;
        if (store) begin last = last + 1; set_slot(c, last, K_STORE, ACC, 5'd0, 5'd0, out_addr(run, pix)); end
        finish_convoy(c, last);
        slot_model = slot_model + ((vl == 9'd16) ? last + 18 : last + 10);
        c = c + 1;
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

    function [31:0] pix_in(input integer oh, input integer ow, input integer tap);
        pix_in = input_mem[(((oh + tap / 3) * 8) + ow + (tap % 3)) * 8];
    endfunction

    task poison_regs;
    begin
        for (j = 1; j < 32; j = j + 1)
            for (e = 0; e < 8; e = e + 1)
                proc_write(VREG_BASE + (j << 5) + (e << 2), 32'h0BAD_0000 + (j << 8) + e);
    end
    endtask

    integer cyc_A, cyc_B, slot_A, slot_B, st_A, st_B;

    task chunk_test(input [8:0] vl_i, input integer grp, input integer run, input neg);
        integer c, oc0;
        reg [31:0] acc32;
    begin
        vl = vl_i;  g = grp;  early = 1'b1;  psum_nop = neg;  in_neg = 1'b0;
        STEP = (vl_i == 9'd16) ? 5'd2 : 5'd1;
        X0 = 5'd1;  ACC = (vl_i == 9'd16) ? 5'd9 : 5'd8;  W0 = (vl_i == 9'd16) ? 5'd13 : 5'd16;
        nvals = (vl_i == 9'd16) ? 16 : 8;
        oc0 = (vl_i == 9'd16) ? 0 : 8 * grp;
        $display("");
        $display("=== CHUNK run %0d: vl=%0d%s, chunk 0 = taps 0..3, chunk 1 = taps 4..8, 3 pixels%s ===", run, vl_i,
                 (vl_i == 9'd16) ? " (all 16 OC)" : (grp ? " OC group 1" : " OC group 0"),
                 neg ? ", NEG: PSUM slot = running no-op" : "");
        // output rows poisoned
        for (p = 0; p < 3; p = p + 1)
            for (e = 0; e < nvals; e = e + 1) proc_write(out_addr(run, p) + (e << 2), 32'h0DEA_D000 + e);
        poison_regs;
        // ---- run A: preload chunk 0, pixels chunk 0 (store partial sums)
        c = 0;  slot_model = 0;
        add_preload(c, 0, 3);
        for (p = 0; p < 3; p = p + 1) begin
            add_compute(c, p, 0, 2, 0, 1'b0, 1'b1, 1'b0, run);
            add_compute(c, p, 3, 3, 0, 1'b0, 1'b0, 1'b1, run);
        end
        n_conv = c;  slot_A = slot_model;
        run_fsm;
        cyc_A = fsm_cycles;  st_A = stall_cycles;
        $display("    run A (preload taps 0..3 + 3 pixels x chunk 0): FSM cycles %0d (slot-layout rule %0d), stall cycles %0d",
                 cyc_A, slot_A, st_A);
        for (p = 0; p < 3; p = p + 1) begin
            for (b = 0; b < nvals; b = b + 1) begin
                acc32 = 0;
                for (t = 0; t < 4; t = t + 1) acc32 = acc32 + pix_in(px_oh[p], px_ow[p], t) * weight_mem[t * 16 + oc0 + b];
                exp[b] = acc32;
            end
            read_mem(out_addr(run, p));
            compare("partial sum taps 0..3 (mem)");
        end
        // ---- between chunks: poison every register (accumulator, inputs, taps)
        poison_regs;
        // ---- run B: preload chunk 1 into the same tap registers, pixels chunk 1
        c = 0;  slot_model = 0;
        add_preload(c, 4, 8);
        for (p = 0; p < 3; p = p + 1) begin
            add_compute(c, p, 4, 6, 4, 1'b1, 1'b0, 1'b0, run);
            add_compute(c, p, 7, 8, 4, 1'b0, 1'b0, 1'b1, run);
        end
        n_conv = c;  slot_B = slot_model;
        run_fsm;
        cyc_B = fsm_cycles;  st_B = stall_cycles;
        $display("    run B (preload taps 4..8 + 3 pixels x chunk 1): FSM cycles %0d (slot-layout rule %0d), stall cycles %0d",
                 cyc_B, slot_B, st_B);
        in_neg = neg;
        for (p = 0; p < 3; p = p + 1) begin
            for (b = 0; b < nvals; b = b + 1) exp[b] = golden[(px_oh[p] * 6 + px_ow[p]) * 16 + oc0 + b];
            read_mem(out_addr(run, p));
            compare(neg ? "NEG final (mem), must FAIL" : "final output, 9 taps (mem)");
        end
        $display("    CYCLES vl=%0d run %0d: A %0d B %0d", vl_i, run, cyc_A, cyc_B);
    end
    endtask

    initial begin
        $readmemh("test1_input.hex",   input_mem);
        $readmemh("test1_weights.hex", weight_mem);
        $readmemh("test1_golden.hex",  golden);
        vl = 9'd8;  vcsr_quant = 2'b00;  go = 1'b0;  early = 1'b1;  n_conv = 0;  psum_nop = 1'b0;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        total_good = 0;  total_checked = 0;  neg_good = 0;  neg_checked = 0;  in_neg = 1'b0;
        for (i = 0; i < 128; i = i + 1) p_kind[i] = K_EMPTY;
        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);
        // DMEM: input in both replications (pixel value = input_mem[p*8]), weights
        for (p = 0; p < 64; p = p + 1) begin
            for (e = 0; e < 16; e = e + 1) proc_write(IN16_BASE + (p << 6) + (e << 2), input_mem[p * 8]);
            for (e = 0; e < 8;  e = e + 1) proc_write(IN8_BASE  + (p << 5) + (e << 2), input_mem[p * 8]);
        end
        for (i = 0; i < 144; i = i + 1) proc_write(W_BASE + (i << 2), weight_mem[i]);
        px_oh[0] = 0;  px_ow[0] = 0;
        px_oh[1] = 2;  px_ow[1] = 5;
        px_oh[2] = 5;  px_ow[2] = 5;

        chunk_test(9'd8,  0, 1, 1'b0);
        chunk_test(9'd8,  1, 2, 1'b0);
        chunk_test(9'd16, 0, 3, 1'b0);
        $display("");
        $display("SUMMARY: %0d of %0d compared elements correct -> %s", total_good, total_checked,
                 (total_good == total_checked) ? "ALL PASS" : "FAILURES");
        chunk_test(9'd8,  0, 4, 1'b1);
        chunk_test(9'd16, 0, 5, 1'b1);
        $display("");
        $display("NEG SUMMARY (PSUM load removed): %0d of %0d final elements correct (expected: far fewer than %0d)",
                 neg_good, neg_checked, neg_checked);
        $finish;
    end

endmodule
