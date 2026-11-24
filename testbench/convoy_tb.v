`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_tb
//
// Isolated convoy overlap test on v_wrapper alone (no atee_top, no DMA):
//   load X -> load W -> MAC (acc += X*W) -> store acc, all with vl=8.
//
// V0 (serial reference): the four instructions issued one at a time in slot 0,
//                        each waiting for DONE before the next.
// V1 (adjacent convoy) : slots 0,1,2,3 loaded on 4 consecutive cycles.
// V1b                  : as V1, but the next slot is not issued while stall=1.
// V2 (spaced convoy)   : slots 0,1,3,4 with an empty slot 2 between the second
//                        load and the MAC (no load directly ahead of its user).
//
// Each variant uses its own registers and its own output row so results are
// independent. Expected OUT[i] = ACC0[i] + X[i]*W[i].
//////////////////////////////////////////////////////////////////////////////////

module convoy_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;
    localparam X_ADDR    = DMEM_BASE + 32'h100;
    localparam W_ADDR    = DMEM_BASE + 32'h200;

    localparam K_NOP = 3'd0, K_LOAD = 3'd1, K_MAC = 3'd2, K_STORE = 3'd3, K_BLOAD = 3'd4;

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

    // Read by convoy_trace.tcl
    reg trace_en;
    reg sim_done;

    // Slot programme for run_convoy: slots 0..n_slots-1, one per cycle
    integer     n_slots;
    reg  [2:0]  slot_kind [0:7];
    reg  [4:0]  slot_vd   [0:7];
    reg  [4:0]  slot_vs1  [0:7];
    reg  [4:0]  slot_vs2  [0:7];
    reg  [31:0] slot_addr [0:7];

    reg     honor_stall;
    integer busy_cycles;
    integer stall_cycles;
    integer i, b;
    reg [31:0] rd;

    // Cycles with DONE low / stall high, sampled mid-cycle; zeroed by the test
    always @(negedge clk) begin
        if (trace_en && !DONE_out) busy_cycles  = busy_cycles + 1;
        if (trace_en && stall_out) stall_cycles = stall_cycles + 1;
    end

    task drive_idle(input [2:0] id);
    begin
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
            K_BLOAD: begin  // broadcast: vd[all elements] <- DMEM[addr] (strided, RS2=0)
                I_start <= 1'b1;  I_vd <= slot_vd[s];  I_RS1 <= slot_addr[s];
                I_dmr <= 1'b1;    I_reg_we <= 1'b1;    I_mem_reg <= 1'b1;
                I_mode_lsu <= 2'b10;  I_RS2 <= 32'd0;
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

    // Load slots 0..n_slots-1 on consecutive cycles, hold the last one until
    // DONE returns, then I_clear.
    task run_convoy;
        integer s;
        integer guard;
    begin
        @(posedge clk);
        drive_slot(0);
        for (s = 1; s < n_slots; s = s + 1) begin
            @(posedge clk);
            if (honor_stall) begin
                // Like a real issuer: do not present a new instruction while
                // the unit is stalling (stall is combinational, let it settle)
                #1;
                while (stall_out) begin
                    @(posedge clk);
                    #1;
                end
            end
            drive_slot(s);
        end
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
        @(posedge clk);
        I_clear <= 1'b0;
        repeat (3) @(posedge clk);
    end
    endtask

    // Preload accumulator register and check OUT row + accumulator afterwards
    task init_acc(input [4:0] vacc);
    begin
        for (i = 0; i < 8; i = i + 1)
            proc_write(VREG_BASE + (vacc << 5) + (i << 2), 32'd1000 * (i + 1));
    end
    endtask

    // xb = 0: X[i] = i+1 (unit-stride X);  xb != 0: X[i] = xb for all i (broadcast)
    task check_result(input [31:0] out_addr, input [4:0] vacc, input integer xb);
        integer good_mem, good_reg;
        reg [31:0] exp;
        reg [31:0] m [0:7];
        reg [31:0] r [0:7];
        reg [31:0] e [0:7];
    begin
        good_mem = 0;  good_reg = 0;
        for (b = 0; b < 8; b = b + 1) begin
            exp = 32'd1000 * (b + 1) + (xb ? xb : (b + 1)) * 10 * (b + 1);
            e[b] = exp;
            proc_read(out_addr + (b << 2), rd);                   m[b] = rd;
            if (rd === exp) good_mem = good_mem + 1;
            proc_read(VREG_BASE + (vacc << 5) + (b << 2), rd);    r[b] = rd;
            if (rd === exp) good_reg = good_reg + 1;
        end
        $display("    expected  = %0d %0d %0d %0d %0d %0d %0d %0d",
                 e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7]);
        $display("    OUT (mem) = %0d %0d %0d %0d %0d %0d %0d %0d",
                 m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7]);
        $display("    acc (vrf) = %0d %0d %0d %0d %0d %0d %0d %0d",
                 r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
        $display("    stored to DMEM correct: %0d/8, accumulator register correct: %0d/8 -> %s",
                 good_mem, good_reg, (good_mem == 8 && good_reg == 8) ? "PASS" : "FAIL");
    end
    endtask

    // Broadcast pre-test: slots 0,1 = the two loads (order chosen by bcast_first),
    // slot 2 empty, slot 3 MAC, slot 4 store. Uses registers vbase, vbase+1, vbase+2.
    task run_bcast(input [23:0] name, input bcast_first, input [31:0] pix_addr,
                   input [4:0] vbase, input [31:0] out_addr);
        integer sb, sw;
    begin
        sb = bcast_first ? 0 : 1;
        sw = bcast_first ? 1 : 0;
        $display("");
        $display("=== %s (slots 0,1,-,3,4): %s, pixel in DMEM bank %0d | (empty) | MAC | store, vl=8 ===",
                 name, bcast_first ? "broadcast X | unit-stride W" : "unit-stride W | broadcast X",
                 pix_addr[4:2]);
        init_acc(vbase + 5'd2);
        n_slots = 5;
        slot_kind[sb] = K_BLOAD; slot_vd[sb] = vbase;         slot_addr[sb] = pix_addr;
        slot_kind[sw] = K_LOAD;  slot_vd[sw] = vbase + 5'd1;  slot_addr[sw] = W_ADDR;
        slot_kind[2]  = K_NOP;
        slot_kind[3]  = K_MAC;   slot_vd[3] = vbase + 5'd2;  slot_vs1[3] = vbase;  slot_vs2[3] = vbase + 5'd1;
        slot_kind[4]  = K_STORE; slot_vd[4] = vbase + 5'd2;  slot_addr[4] = out_addr;
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        run_convoy;
        trace_en = 1'b0;
        $display("    %s DONE-low cycles = %0d, stall cycles = %0d", name, busy_cycles, stall_cycles);
        check_result(out_addr, vbase + 5'd2, 7);
    end
    endtask

    initial begin
        vl = 9'd8;  vcsr_quant = 2'b00;  I_clear = 1'b0;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        trace_en = 1'b0;  sim_done = 1'b0;  honor_stall = 1'b0;
        I_start = 0; I_id = 0; I_vs1 = 0; I_vs2 = 0; I_vd = 0; I_RS1 = 0; I_RS2 = 0;
        I_uimm5 = 0; I_funct = 0; I_permute = 0; I_mask_en = 0; I_ALUSrc = 0;
        I_dmr = 0; I_dmw = 0; I_reg_we = 0; I_mem_reg = 0; I_Xout = 0; I_mode_lsu = 0;

        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);

        // X[i] = i+1, W[i] = 10*(i+1), each one element per bank in one row
        for (i = 0; i < 8; i = i + 1) begin
            proc_write(X_ADDR + (i << 2), i + 1);
            proc_write(W_ADDR + (i << 2), 10 * (i + 1));
        end

        // ================= V0: serial reference =================
        $display("");
        $display("=== V0 (serial): load v9, load v10, MAC v11+=v9*v10, store v11 -- one at a time, vl=8 ===");
        init_acc(5'd11);
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;  n_slots = 1;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd9;   slot_addr[0] = X_ADDR;  run_convoy;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd10;  slot_addr[0] = W_ADDR;  run_convoy;
        slot_kind[0] = K_MAC;   slot_vd[0] = 5'd11;  slot_vs1[0] = 5'd9;  slot_vs2[0] = 5'd10;  run_convoy;
        slot_kind[0] = K_STORE; slot_vd[0] = 5'd11;  slot_addr[0] = DMEM_BASE + 32'h500;  run_convoy;
        trace_en = 1'b0;
        $display("    V0 DONE-low cycles (sum of 4 instructions) = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        check_result(DMEM_BASE + 32'h500, 5'd11, 0);

        // ================= V1: adjacent convoy =================
        $display("");
        $display("=== V1 (convoy, slots 0,1,2,3): load v1 | load v2 | MAC v3+=v1*v2 | store v3, vl=8 ===");
        init_acc(5'd3);
        n_slots = 4;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd1;  slot_addr[0] = X_ADDR;
        slot_kind[1] = K_LOAD;  slot_vd[1] = 5'd2;  slot_addr[1] = W_ADDR;
        slot_kind[2] = K_MAC;   slot_vd[2] = 5'd3;  slot_vs1[2] = 5'd1;  slot_vs2[2] = 5'd2;
        slot_kind[3] = K_STORE; slot_vd[3] = 5'd3;  slot_addr[3] = DMEM_BASE + 32'h300;
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        run_convoy;
        trace_en = 1'b0;
        $display("    V1 DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        check_result(DMEM_BASE + 32'h300, 5'd3, 0);

        // ================= V1b: adjacent convoy, issue held during stall =================
        $display("");
        $display("=== V1b (convoy, slots 0,1,2,3, issue waits while stall=1): load v12 | load v13 | MAC v14+=v12*v13 | store v14, vl=8 ===");
        init_acc(5'd14);
        n_slots = 4;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd12;  slot_addr[0] = X_ADDR;
        slot_kind[1] = K_LOAD;  slot_vd[1] = 5'd13;  slot_addr[1] = W_ADDR;
        slot_kind[2] = K_MAC;   slot_vd[2] = 5'd14;  slot_vs1[2] = 5'd12;  slot_vs2[2] = 5'd13;
        slot_kind[3] = K_STORE; slot_vd[3] = 5'd14;  slot_addr[3] = DMEM_BASE + 32'h600;
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;  honor_stall = 1'b1;
        run_convoy;
        trace_en = 1'b0;  honor_stall = 1'b0;
        $display("    V1b DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        check_result(DMEM_BASE + 32'h600, 5'd14, 0);

        // ================= V2: spaced convoy =================
        $display("");
        $display("=== V2 (convoy, slots 0,1,-,3,4): load v5 | load v6 | (empty) | MAC v7+=v5*v6 | store v7, vl=8 ===");
        init_acc(5'd7);
        n_slots = 5;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd5;  slot_addr[0] = X_ADDR;
        slot_kind[1] = K_LOAD;  slot_vd[1] = 5'd6;  slot_addr[1] = W_ADDR;
        slot_kind[2] = K_NOP;
        slot_kind[3] = K_MAC;   slot_vd[3] = 5'd7;  slot_vs1[3] = 5'd5;  slot_vs2[3] = 5'd6;
        slot_kind[4] = K_STORE; slot_vd[4] = 5'd7;  slot_addr[4] = DMEM_BASE + 32'h400;
        busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
        run_convoy;
        trace_en = 1'b0;
        $display("    V2 DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        check_result(DMEM_BASE + 32'h400, 5'd7, 0);

        // ================= V3: broadcast input load next to a unit-stride weight load =================
        // Pixel value 7 stored at three addresses that differ only in DMEM bank.
        proc_write(DMEM_BASE + 32'h700, 32'd7);   // bank 0
        proc_write(DMEM_BASE + 32'h70C, 32'd7);   // bank 3
        proc_write(DMEM_BASE + 32'h71C, 32'd7);   // bank 7

        run_bcast("V3a", 1'b1, DMEM_BASE + 32'h70C, 5'd15, DMEM_BASE + 32'h800);  // bcast first, pixel in bank 3
        run_bcast("V3b", 1'b1, DMEM_BASE + 32'h71C, 5'd18, DMEM_BASE + 32'h900);  // bcast first, pixel in bank 7
        run_bcast("V3c", 1'b0, DMEM_BASE + 32'h70C, 5'd21, DMEM_BASE + 32'hA00);  // weights first, pixel in bank 3
        run_bcast("V3d", 1'b0, DMEM_BASE + 32'h700, 5'd24, DMEM_BASE + 32'hB00);  // weights first, pixel in bank 0

        sim_done = 1'b1;
        repeat (2) @(posedge clk);
        $finish;
    end

endmodule
