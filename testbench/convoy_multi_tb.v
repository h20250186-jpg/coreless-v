`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_multi_tb
//
// Two isolated experiments on v_wrapper alone (no atee_top, no DMA), vl=8.
//
// TEST M -- several MACs in flight in ONE convoy, all accumulating into the
//           same register (vd = acc), operands already sitting in the VRF:
//   M2 / M4 / M8 : 2, 4, 8 MAC slots back to back (slots 0..N-1)
//   L3M3S        : load X1 | load X2 | load X3 | (empty) | MAC1 | MAC2 | MAC3 | store
//                  (weights preloaded in the VRF, inputs loaded in the convoy)
//
// TEST N -- two consecutive convoys A then B (each: load X | load W | (empty)
//           | MAC | store, same registers, B accumulates on top of A) where
//           I_clear for A is NOT held back until DONE:
//   N_done : reference, wait for DONE between A and B
//   N_k    : clear driven k cycles after A's last slot was driven, B's slot 0
//            driven on the very next cycle. k=8 is the earliest clear that
//            still lets A's last slot issue all 8 elements.
//////////////////////////////////////////////////////////////////////////////////

module convoy_multi_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;

    localparam K_NOP = 3'd0, K_LOAD = 3'd1, K_MAC = 3'd2, K_STORE = 3'd3;

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

    // Read by convoy_multi_trace.tcl
    reg       trace_en;
    reg       sim_done;
    reg [7:0] trace_slots;   // bit s set: print EXE operands of slot s

    // Slot programme: slots 0..n_slots-1, one per cycle
    integer     n_slots;
    reg  [2:0]  slot_kind [0:7];
    reg  [4:0]  slot_vd   [0:7];
    reg  [4:0]  slot_vs1  [0:7];
    reg  [4:0]  slot_vs2  [0:7];
    reg  [31:0] slot_addr [0:7];

    integer busy_cycles;
    integer stall_cycles;
    integer i, k, b;
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
            K_LOAD: begin   // vd <- DMEM[addr + 4*count]
                I_start <= 1'b1;  I_vd <= slot_vd[s];  I_RS1 <= slot_addr[s];
                I_dmr <= 1'b1;    I_reg_we <= 1'b1;    I_mem_reg <= 1'b1;
            end
            K_MAC: begin    // vd <- vd + vs1*vs2
                I_start <= 1'b1;  I_vs1 <= slot_vs1[s];  I_vs2 <= slot_vs2[s];
                I_vd <= slot_vd[s];  I_funct <= 8'b00000011;  I_reg_we <= 1'b1;
            end
            K_STORE: begin  // DMEM[addr + 4*count] <- vd
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

    // Drive slots 0..n_slots-1 on consecutive clock edges (slot 0 on the next edge)
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

    // Hold the last slot until DONE, then drive I_clear for one cycle
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

    // Drive I_clear exactly kc clock edges after the last slot was driven,
    // whether or not DONE has returned
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

    // ---------------------------------------------------------------------
    // Data
    // ---------------------------------------------------------------------
    // Memory rows (8 words each)
    localparam XA_ADDR = DMEM_BASE + 32'h100;   // XA[i] = i+1
    localparam WA_ADDR = DMEM_BASE + 32'h200;   // WA[i] = 10*(i+1)
    localparam XB_ADDR = DMEM_BASE + 32'hC00;   // XB[i] = 2*i+3
    localparam WB_ADDR = DMEM_BASE + 32'hD00;   // WB[i] = 7-i
    localparam XC_ADDR = DMEM_BASE + 32'hE00;   // XC[i] = 5*i+1

    function [31:0] acc0(input integer e);  acc0 = 1000 * (e + 1);        endfunction
    // Preloaded VRF operands for TEST M: Xk in v(8+k), Wk in v(16+k), k = 0..7
    function [31:0] xk(input integer kk, input integer e);  xk = kk + e + 1;            endfunction
    function [31:0] wk(input integer kk, input integer e);  wk = (kk + 2) * (e + 1);    endfunction

    task write_vreg(input [4:0] vreg, input integer e, input [31:0] data);
    begin
        proc_write(VREG_BASE + (vreg << 5) + (e << 2), data);
    end
    endtask

    reg [31:0] got [0:7];
    reg [31:0] exp [0:7];

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

    task compare(input [8*12:1] what);
        integer good;
    begin
        good = 0;
        for (b = 0; b < 8; b = b + 1)
            if (got[b] === exp[b]) good = good + 1;
        $display("    expected     = %0d %0d %0d %0d %0d %0d %0d %0d",
                 exp[0], exp[1], exp[2], exp[3], exp[4], exp[5], exp[6], exp[7]);
        $display("    %s = %0d %0d %0d %0d %0d %0d %0d %0d", what,
                 got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7]);
        $display("    %s: %0d/8 correct -> %s", what, good, (good == 8) ? "PASS" : "FAIL");
    end
    endtask

    localparam [4:0] V_ACC = 5'd24;

    // TEST M: nmac MAC slots back to back on preloaded operands
    task run_multi_mac(input integer nmac);
    begin
        $display("");
        $display("=== M%0d: %0d MAC slots back to back (slots 0..%0d), all vd=v24, operands preloaded in VRF, vl=8 ===",
                 nmac, nmac, nmac - 1);
        for (i = 0; i < 8; i = i + 1) write_vreg(V_ACC, i, acc0(i));
        n_slots = nmac;
        for (k = 0; k < nmac; k = k + 1) begin
            slot_kind[k] = K_MAC;  slot_vd[k] = V_ACC;
            slot_vs1[k] = 5'd8 + k;  slot_vs2[k] = 5'd16 + k;
        end
        for (b = 0; b < 8; b = b + 1) begin
            exp[b] = acc0(b);
            for (k = 0; k < nmac; k = k + 1) exp[b] = exp[b] + xk(k, b) * wk(k, b);
        end
        trace_slots = (nmac >= 8) ? 8'hFF : ((8'd1 << nmac) - 8'd1);
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        issue_slots;
        clear_on_done;
        settle;
        trace_en = 1'b0;
        $display("    M%0d DONE-low cycles = %0d, stall cycles = %0d", nmac, busy_cycles, stall_cycles);
        read_vreg(V_ACC);
        compare("acc (vrf)   ");
    end
    endtask

    // TEST N: convoy A then convoy B, clear between them after kc cycles (kc=0: wait DONE)
    task run_pair(input integer kc, input integer run_idx);
        reg [31:0] outa, outb;
    begin
        outa = DMEM_BASE + 32'h1000 + run_idx * 32'h40;
        outb = outa + 32'h20;
        $display("");
        if (kc == 0)
            $display("=== N_done: convoy A, wait for DONE, clear, convoy B (reference) ===");
        else
            $display("=== N_%0d: convoy A, clear %0d cycles after A's last slot, convoy B on the next cycle ===", kc, kc);
        for (i = 0; i < 8; i = i + 1) write_vreg(5'd3, i, acc0(i));
        n_slots = 5;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd1;
        slot_kind[1] = K_LOAD;  slot_vd[1] = 5'd2;
        slot_kind[2] = K_NOP;
        slot_kind[3] = K_MAC;   slot_vd[3] = 5'd3;  slot_vs1[3] = 5'd1;  slot_vs2[3] = 5'd2;
        slot_kind[4] = K_STORE; slot_vd[4] = 5'd3;
        trace_slots = 8'b0000_1000;
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        // convoy A
        slot_addr[0] = XA_ADDR;  slot_addr[1] = WA_ADDR;  slot_addr[4] = outa;
        issue_slots;
        if (kc == 0) clear_on_done; else clear_after(kc);
        // convoy B
        slot_addr[0] = XB_ADDR;  slot_addr[1] = WB_ADDR;  slot_addr[4] = outb;
        issue_slots;
        clear_on_done;
        settle;
        trace_en = 1'b0;
        $display("    total DONE-low cycles for A+B = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        for (b = 0; b < 8; b = b + 1) exp[b] = acc0(b) + (b + 1) * 10 * (b + 1);
        read_mem(outa);  compare("OUT_A (mem) ");
        for (b = 0; b < 8; b = b + 1) exp[b] = exp[b] + (2 * b + 3) * (7 - b);
        read_mem(outb);  compare("OUT_B (mem) ");
        read_vreg(5'd3); compare("acc (vrf)   ");
    end
    endtask

    initial begin
        vl = 9'd8;  vcsr_quant = 2'b00;  I_clear = 1'b0;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        trace_en = 1'b0;  sim_done = 1'b0;  trace_slots = 8'd0;
        I_start = 0; I_id = 0; I_vs1 = 0; I_vs2 = 0; I_vd = 0; I_RS1 = 0; I_RS2 = 0;
        I_uimm5 = 0; I_funct = 0; I_permute = 0; I_mask_en = 0; I_ALUSrc = 0;
        I_dmr = 0; I_dmw = 0; I_reg_we = 0; I_mem_reg = 0; I_Xout = 0; I_mode_lsu = 0;

        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);

        for (i = 0; i < 8; i = i + 1) begin
            proc_write(XA_ADDR + (i << 2), i + 1);
            proc_write(WA_ADDR + (i << 2), 10 * (i + 1));
            proc_write(XB_ADDR + (i << 2), 2 * i + 3);
            proc_write(WB_ADDR + (i << 2), 7 - i);
            proc_write(XC_ADDR + (i << 2), 5 * i + 1);
        end
        for (k = 0; k < 8; k = k + 1)
            for (i = 0; i < 8; i = i + 1) begin
                write_vreg(5'd8  + k, i, xk(k, i));
                write_vreg(5'd16 + k, i, wk(k, i));
            end

        // ================= TEST M =================
        run_multi_mac(1);
        run_multi_mac(2);
        run_multi_mac(4);
        run_multi_mac(8);

        $display("");
        $display("=== L3M3S (slots 0..7): load v1<-XA | load v2<-XB | load v4<-XC | (empty) | MAC v24+=v1*v16 | MAC v24+=v2*v17 | MAC v24+=v4*v18 | store v24, vl=8 ===");
        for (i = 0; i < 8; i = i + 1) write_vreg(V_ACC, i, acc0(i));
        n_slots = 8;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd1;  slot_addr[0] = XA_ADDR;
        slot_kind[1] = K_LOAD;  slot_vd[1] = 5'd2;  slot_addr[1] = XB_ADDR;
        slot_kind[2] = K_LOAD;  slot_vd[2] = 5'd4;  slot_addr[2] = XC_ADDR;
        slot_kind[3] = K_NOP;
        slot_kind[4] = K_MAC;   slot_vd[4] = V_ACC;  slot_vs1[4] = 5'd1;  slot_vs2[4] = 5'd16;
        slot_kind[5] = K_MAC;   slot_vd[5] = V_ACC;  slot_vs1[5] = 5'd2;  slot_vs2[5] = 5'd17;
        slot_kind[6] = K_MAC;   slot_vd[6] = V_ACC;  slot_vs1[6] = 5'd4;  slot_vs2[6] = 5'd18;
        slot_kind[7] = K_STORE; slot_vd[7] = V_ACC;  slot_addr[7] = DMEM_BASE + 32'hF00;
        for (b = 0; b < 8; b = b + 1)
            exp[b] = acc0(b) + (b + 1) * wk(0, b) + (2 * b + 3) * wk(1, b) + (5 * b + 1) * wk(2, b);
        trace_slots = 8'b0111_0000;
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        issue_slots;
        clear_on_done;
        settle;
        trace_en = 1'b0;
        $display("    L3M3S DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        read_mem(DMEM_BASE + 32'hF00);  compare("OUT (mem)   ");
        read_vreg(V_ACC);               compare("acc (vrf)   ");

        // Same work with no empty slot, so the store sits in slot 6 instead of 7.
        // Each MAC reads the load 3 slots ahead of it; no load is directly
        // ahead of the instruction that reads it.
        $display("");
        $display("=== L3M3S6 (slots 0..6): load v1<-XA | load v2<-XB | load v4<-XC | MAC v24+=v1*v16 | MAC v24+=v2*v17 | MAC v24+=v4*v18 | store v24, vl=8 ===");
        for (i = 0; i < 8; i = i + 1) write_vreg(V_ACC, i, acc0(i));
        n_slots = 7;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd1;  slot_addr[0] = XA_ADDR;
        slot_kind[1] = K_LOAD;  slot_vd[1] = 5'd2;  slot_addr[1] = XB_ADDR;
        slot_kind[2] = K_LOAD;  slot_vd[2] = 5'd4;  slot_addr[2] = XC_ADDR;
        slot_kind[3] = K_MAC;   slot_vd[3] = V_ACC;  slot_vs1[3] = 5'd1;  slot_vs2[3] = 5'd16;
        slot_kind[4] = K_MAC;   slot_vd[4] = V_ACC;  slot_vs1[4] = 5'd2;  slot_vs2[4] = 5'd17;
        slot_kind[5] = K_MAC;   slot_vd[5] = V_ACC;  slot_vs1[5] = 5'd4;  slot_vs2[5] = 5'd18;
        slot_kind[6] = K_STORE; slot_vd[6] = V_ACC;  slot_addr[6] = DMEM_BASE + 32'hF40;
        trace_slots = 8'b0011_1000;
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        issue_slots;
        clear_on_done;
        settle;
        trace_en = 1'b0;
        $display("    L3M3S6 DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        read_mem(DMEM_BASE + 32'hF40);  compare("OUT (mem)   ");
        read_vreg(V_ACC);               compare("acc (vrf)   ");

        // ================= TEST N =================
        run_pair(7, 6);     // negative control: one cycle too early
        run_pair(0, 0);
        run_pair(8, 1);
        run_pair(9, 2);
        run_pair(10, 3);
        run_pair(11, 4);
        run_pair(12, 5);

        sim_done = 1'b1;
        repeat (2) @(posedge clk);
        $finish;
    end

endmodule
