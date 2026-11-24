`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_4tap_tb
//
// Isolated four-taps-per-convoy tests on v_wrapper alone (no atee_top, no DMA),
// vl=8.
//
// TEST A (synthetic, mixed-sign) -- shape 1 on its own:
//   load v1 | load v2 | load v3 | load v4 | MAC | MAC | MAC | MAC   (slots 0..7)
//   Each MAC reads the load exactly 4 slots back. No forwarding path reaches
//   that far, so the operand comes through the register file. v1..v4 are
//   filled with a poison value first, and the convoy is run twice on different
//   rows, so a stale register read cannot produce the expected result.
//
// TEST B (real conv data from test1_*.hex) -- the 4+4+1 pixel sequence:
//   C1: load taps 0..3 -> v1..v4 | MUL tap0, MAC taps 1..3 (slots 4..7)
//   C2: load taps 4..7 -> v1..v4 | MAC taps 4..7           (slots 4..7)
//   C3: load tap 8 -> v1 | (empty) | (empty) | MAC | [ReLU] | store
//       store in slot 5 with ReLU, slot 4 without. Slots 6,7 stay empty.
//   Weights of the 9 taps are preloaded in v16..v24. Three output pixels are
//   computed back to back per run and compared with test1_golden.hex
//   (ReLU applied here when the ReLU variant is run).
//   Variants: wait for DONE between convoys / clear 8 cycles after the last
//   slot; with and without ReLU; OC group 0 and OC group 1.
//////////////////////////////////////////////////////////////////////////////////

module convoy_4tap_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;
    localparam IN_BASE   = DMEM_BASE;                 // replicated input, row = pixel
    localparam OUT_BASE  = DMEM_BASE + 32'h6_0000;
    localparam SYN_BASE  = DMEM_BASE + 32'h4_0000;    // synthetic rows for TEST A

    localparam K_NOP = 3'd0, K_LOAD = 3'd1, K_MAC = 3'd2, K_STORE = 3'd3,
               K_RELU = 3'd4, K_MUL = 3'd5;
    localparam [4:0] V_ACC = 5'd8, V_ZERO = 5'd12, V_W0 = 5'd16, V_SW0 = 5'd26;

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

    // Read by convoy_4tap_trace.tcl
    reg       trace_en;      // count busy/stall cycles
    reg       trace_print;   // print the per-cycle trace
    reg       sim_done;
    reg [7:0] trace_slots;

    integer     n_slots;
    reg  [2:0]  slot_kind [0:7];
    reg  [4:0]  slot_vd   [0:7];
    reg  [4:0]  slot_vs1  [0:7];
    reg  [4:0]  slot_vs2  [0:7];
    reg  [31:0] slot_addr [0:7];

    integer busy_cycles;
    integer stall_cycles;
    integer i, j, b, t;
    reg [31:0] rd;

    always @(negedge clk) begin
        if (trace_en && !DONE_out) busy_cycles  = busy_cycles + 1;
        if (trace_en && stall_out) stall_cycles = stall_cycles + 1;
    end

    task drive_idle(input [2:0] id);
    begin
        I_clear <= 1'b0;
        I_start <= 1'b0;  I_id <= id;
        I_vs1 <= 5'd0;    I_vs2 <= 5'd0;   I_vd <= 5'd0;
        I_RS1 <= 32'd0;   I_RS2 <= 32'd0;  I_uimm5 <= 5'd0;
        I_funct <= 8'd0;  I_permute <= 2'd0; I_mask_en <= 1'b0;
        I_ALUSrc <= 2'b00; I_dmr <= 1'b0;  I_dmw <= 1'b0;
        I_reg_we <= 1'b0; I_mem_reg <= 1'b0; I_Xout <= 1'b0;
        I_mode_lsu <= 2'b00;
    end
    endtask

    task drive_slot(input integer s);
    begin
        drive_idle(s[2:0]);
        case (slot_kind[s])
            K_LOAD: begin
                I_start <= 1'b1;  I_vd <= slot_vd[s];  I_RS1 <= slot_addr[s];
                I_dmr <= 1'b1;    I_reg_we <= 1'b1;    I_mem_reg <= 1'b1;
            end
            K_MAC, K_MUL: begin   // MAC: vd <- vd + vs1*vs2,  MUL: vd <- vs1*vs2
                I_start <= 1'b1;  I_vs1 <= slot_vs1[s];  I_vs2 <= slot_vs2[s];
                I_vd <= slot_vd[s];  I_reg_we <= 1'b1;
                I_funct <= (slot_kind[s] == K_MUL) ? 8'b00000010 : 8'b00000011;
            end
            K_RELU: begin         // vd <- max(vd, 0)
                I_start <= 1'b1;  I_vs1 <= slot_vd[s];  I_vs2 <= V_ZERO;
                I_vd <= slot_vd[s];  I_funct <= 8'b00000101;  I_reg_we <= 1'b1;
            end
            K_STORE: begin
                I_start <= 1'b1;  I_vd <= slot_vd[s];  I_RS1 <= slot_addr[s];
                I_dmw <= 1'b1;
            end
            default: ;
        endcase
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

    task issue_slots;
        integer s;
    begin
        @(posedge clk);
        drive_slot(0);
        for (s = 1; s < n_slots; s = s + 1) begin
            @(posedge clk);
            drive_slot(s);
        end
    end
    endtask

    task clear_on_done;
        integer guard;
    begin
        @(posedge clk);
        @(negedge clk);
        guard = 0;
        while (!DONE_out && guard < 400) begin
            guard = guard + 1;
            @(negedge clk);
        end
        if (guard >= 400) $display("    TIMEOUT waiting for DONE");
        @(posedge clk);
        drive_idle(3'd0);
        I_clear <= 1'b1;
    end
    endtask

    task clear_after(input integer kc);
    begin
        repeat (kc) @(posedge clk);
        drive_idle(3'd0);
        I_clear <= 1'b1;
    end
    endtask

    task settle;
    begin
        @(posedge clk);
        drive_idle(3'd0);
        repeat (4) @(posedge clk);
    end
    endtask

    task write_vreg(input [4:0] vreg, input integer e, input [31:0] data);
    begin
        proc_write(VREG_BASE + (vreg << 5) + (e << 2), data);
    end
    endtask

    reg signed [31:0] got [0:7];
    reg signed [31:0] exp [0:7];

    task read_vreg(input [4:0] vreg);
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

    integer total_good, total_checked;

    task compare(input [8*14:1] what);
        integer good;
    begin
        good = 0;
        for (b = 0; b < 8; b = b + 1)
            if (got[b] === exp[b]) good = good + 1;
        total_good = total_good + good;  total_checked = total_checked + 8;
        $display("    expected       = %0d %0d %0d %0d %0d %0d %0d %0d",
                 exp[0], exp[1], exp[2], exp[3], exp[4], exp[5], exp[6], exp[7]);
        $display("    %s = %0d %0d %0d %0d %0d %0d %0d %0d  -> %0d/8 %s", what,
                 got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7],
                 good, (good == 8) ? "PASS" : "FAIL");
    end
    endtask

    // ---------------------------------------------------------------------
    // TEST A data (synthetic, mixed sign)
    // ---------------------------------------------------------------------
    function signed [31:0] xs(input integer r, input integer e);   // input row r
        xs = (((r + e) % 2) ? -1 : 1) * (3 * r + e + 1);
    endfunction
    function signed [31:0] ws(input integer k, input integer e);   // weight reg k
        ws = (((k + 2 * e) % 3 == 0) ? -1 : 1) * (k + 2) * (e + 1);
    endfunction
    function signed [31:0] acc_init(input integer e);
        acc_init = ((e % 2) ? 1 : -1) * 50 * (e + 1);
    endfunction

    task prog_l4m4_syn(input integer row0);
    begin
        n_slots = 8;
        for (j = 0; j < 4; j = j + 1) begin
            slot_kind[j]     = K_LOAD;  slot_vd[j] = 5'd1 + j;
            slot_addr[j]     = SYN_BASE + ((row0 + j) << 5);
            slot_kind[4 + j] = K_MAC;   slot_vd[4 + j] = 5'd9;
            slot_vs1[4 + j]  = 5'd1 + j;  slot_vs2[4 + j] = V_SW0 + j;
        end
    end
    endtask

    // ---------------------------------------------------------------------
    // TEST B data (real conv8_3 layout)
    // ---------------------------------------------------------------------
    reg [31:0] input_mem  [0:511];
    reg [31:0] weight_mem [0:143];
    reg [31:0] golden     [0:575];

    function [31:0] in_addr(input integer oh, input integer ow, input integer tap);
        in_addr = IN_BASE + ((((oh + tap / 3) * 8) + ow + (tap % 3)) << 5);
    endfunction
    function signed [31:0] relu(input signed [31:0] v);
        relu = (v < 0) ? 0 : v;
    endfunction

    integer px_oh [0:2];
    integer px_ow [0:2];

    // Three pixels back to back for OC group g, each as C1 | C2 | C3
    task run_pixels(input integer g, input early, input relu_on, input integer run_idx);
        integer p, base;
        reg [31:0] oaddr;
    begin
        $display("");
        $display("=== B%0d: OC group %0d, %s, %s; pixels (%0d,%0d) (%0d,%0d) (%0d,%0d) ===", run_idx, g,
                 early ? "clear 8 cycles after last slot" : "wait for DONE",
                 relu_on ? "ReLU on (store in slot 5)" : "ReLU off (store in slot 4)",
                 px_oh[0], px_ow[0], px_oh[1], px_ow[1], px_oh[2], px_ow[2]);
        // tap weights of this group -> v16..v24
        for (t = 0; t < 9; t = t + 1)
            for (i = 0; i < 8; i = i + 1)
                write_vreg(V_W0 + t, i, weight_mem[t * 16 + g * 8 + i]);
        // poison the accumulator and the input registers
        for (i = 0; i < 8; i = i + 1) write_vreg(V_ACC, i, 32'h0BAD_0000 + i);
        for (j = 1; j <= 4; j = j + 1)
            for (i = 0; i < 8; i = i + 1) write_vreg(j, i, 32'h0000_7777);

        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        for (p = 0; p < 3; p = p + 1) begin
            trace_print = (p == 0);
            oaddr = OUT_BASE + (run_idx << 12) + (p << 5);
            // C1 / C2: four loads, four MACs each reading the load 4 slots back
            for (base = 0; base < 8; base = base + 4) begin
                n_slots = 8;
                for (j = 0; j < 4; j = j + 1) begin
                    slot_kind[j]     = K_LOAD;  slot_vd[j] = 5'd1 + j;
                    slot_addr[j]     = in_addr(px_oh[p], px_ow[p], base + j);
                    slot_kind[4 + j] = (base + j == 0) ? K_MUL : K_MAC;
                    slot_vd[4 + j]   = V_ACC;
                    slot_vs1[4 + j]  = 5'd1 + j;  slot_vs2[4 + j] = V_W0 + base + j;
                end
                trace_slots = 8'b1111_0000;
                issue_slots;
                if (early) clear_after(8); else clear_on_done;
            end
            // C3: last tap fused with ReLU and store
            slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd1;  slot_addr[0] = in_addr(px_oh[p], px_ow[p], 8);
            slot_kind[1] = K_NOP;   slot_kind[2] = K_NOP;
            slot_kind[3] = K_MAC;   slot_vd[3] = V_ACC;  slot_vs1[3] = 5'd1;  slot_vs2[3] = V_W0 + 8;
            if (relu_on) begin
                n_slots = 6;
                slot_kind[4] = K_RELU;   slot_vd[4] = V_ACC;
                slot_kind[5] = K_STORE;  slot_vd[5] = V_ACC;  slot_addr[5] = oaddr;
            end else begin
                n_slots = 5;
                slot_kind[4] = K_STORE;  slot_vd[4] = V_ACC;  slot_addr[4] = oaddr;
            end
            trace_slots = 8'b0001_1000;
            issue_slots;
            if (early && p < 2) clear_after(8); else clear_on_done;
        end
        settle;
        trace_en = 1'b0;  trace_print = 1'b0;
        $display("    DONE-low cycles for 3 pixels = %0d (%0d per pixel), stall cycles = %0d",
                 busy_cycles, busy_cycles / 3, stall_cycles);
        for (p = 0; p < 3; p = p + 1) begin
            for (b = 0; b < 8; b = b + 1) begin
                exp[b] = golden[(px_oh[p] * 6 + px_ow[p]) * 16 + g * 8 + b];
                if (relu_on) exp[b] = relu(exp[b]);
            end
            read_mem(OUT_BASE + (run_idx << 12) + (p << 5));
            compare("OUT (mem)     ");
        end
        read_vreg(V_ACC);   // accumulator still holds the last pixel
        compare("acc (vrf) last");
    end
    endtask

    initial begin
        $readmemh("test1_input.hex",   input_mem);
        $readmemh("test1_weights.hex", weight_mem);
        $readmemh("test1_golden.hex",  golden);

        vl = 9'd8;  vcsr_quant = 2'b00;  I_clear = 1'b0;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        trace_en = 1'b0;  trace_print = 1'b0;  sim_done = 1'b0;  trace_slots = 8'd0;
        total_good = 0;  total_checked = 0;
        I_start = 0; I_id = 0; I_vs1 = 0; I_vs2 = 0; I_vd = 0; I_RS1 = 0; I_RS2 = 0;
        I_uimm5 = 0; I_funct = 0; I_permute = 0; I_mask_en = 0; I_ALUSrc = 0;
        I_dmr = 0; I_dmw = 0; I_reg_we = 0; I_mem_reg = 0; I_Xout = 0; I_mode_lsu = 0;

        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);

        // DMEM: real input image (replicated layout) and the synthetic rows
        for (i = 0; i < 512; i = i + 1)
            proc_write(IN_BASE + (i << 2), input_mem[i]);
        for (j = 0; j < 8; j = j + 1)
            for (i = 0; i < 8; i = i + 1)
                proc_write(SYN_BASE + (j << 5) + (i << 2), xs(j, i));
        for (j = 0; j < 4; j = j + 1)
            for (i = 0; i < 8; i = i + 1)
                write_vreg(V_SW0 + j, i, ws(j, i));

        // ================= TEST A =================
        $display("");
        $display("=== A1 (slots 0..7): load v1..v4 <- rows 0..3 | MAC v9 += v(1+j)*v(26+j), j=0..3; v1..v4 poisoned first ===");
        for (i = 0; i < 8; i = i + 1) write_vreg(5'd9, i, acc_init(i));
        for (j = 1; j <= 4; j = j + 1)
            for (i = 0; i < 8; i = i + 1) write_vreg(j, i, 32'h0000_7777);
        prog_l4m4_syn(0);
        trace_slots = 8'b1111_0000;  busy_cycles = 0;  stall_cycles = 0;
        trace_en = 1'b1;  trace_print = 1'b1;
        issue_slots;  clear_on_done;  settle;
        trace_en = 1'b0;  trace_print = 1'b0;
        $display("    A1 DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        for (b = 0; b < 8; b = b + 1) begin
            exp[b] = acc_init(b);
            for (j = 0; j < 4; j = j + 1) exp[b] = exp[b] + xs(j, b) * ws(j, b);
        end
        read_vreg(5'd9);  compare("acc (vrf)     ");

        $display("");
        $display("=== A2 (slots 0..7): same convoy on rows 4..7, accumulating on top of A1 (v1..v4 now hold A1's rows) ===");
        prog_l4m4_syn(4);
        trace_slots = 8'b1111_0000;  busy_cycles = 0;  stall_cycles = 0;
        trace_en = 1'b1;  trace_print = 1'b1;
        issue_slots;  clear_on_done;  settle;
        trace_en = 1'b0;  trace_print = 1'b0;
        $display("    A2 DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        for (b = 0; b < 8; b = b + 1)
            for (j = 0; j < 4; j = j + 1) exp[b] = exp[b] + xs(4 + j, b) * ws(j, b);
        read_vreg(5'd9);  compare("acc (vrf)     ");

        // ================= TEST B =================
        px_oh[0] = 0;  px_ow[0] = 0;
        px_oh[1] = 2;  px_ow[1] = 5;
        px_oh[2] = 5;  px_ow[2] = 5;
        run_pixels(0, 1'b0, 1'b1, 1);
        run_pixels(0, 1'b1, 1'b1, 2);
        run_pixels(0, 1'b1, 1'b0, 3);
        run_pixels(1, 1'b1, 1'b1, 4);
        run_pixels(1, 1'b0, 1'b0, 5);

        $display("");
        $display("TOTAL: %0d of %0d compared elements correct -> %s", total_good, total_checked,
                 (total_good == total_checked) ? "ALL PASS" : "FAILURES");
        sim_done = 1'b1;
        repeat (2) @(posedge clk);
        $finish;
    end

endmodule
