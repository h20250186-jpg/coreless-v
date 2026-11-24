`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: convoy_relu_tb
//
// Isolated ReLU tests on v_wrapper alone (no atee_top, no DMA), vl=8.
// ReLU = ALU funct 101 (signed max) with vs1 = acc, vs2 = v12 (never written, 0).
//
//   R2       : ReLU (slot 0) | store (slot 1) on a preloaded mixed-sign register
//   MR_done  : convoy A = load X | load W | (empty) | MAC, wait for DONE, clear;
//              convoy B = ReLU | store            (the controller's sequence)
//   MR_early : as MR_done, but A is cleared 8 cycles after its last slot and B
//              starts on the next cycle; B is also cleared early and followed
//              by a second ReLU | store convoy on another register
//   MRS      : load X | load W | (empty) | MAC | ReLU | store in ONE convoy
//
// MAC data: acc = -200 everywhere, X[i] = i+1, W[i] = 10*(i+1), so acc + X*W is
// negative for elements 0..3 and positive for 4..7.
//////////////////////////////////////////////////////////////////////////////////

module convoy_relu_tb;

    parameter CLK_PERIOD = 20;

    localparam DMEM_BASE = 32'h0010_0000;
    localparam VREG_BASE = 32'h0018_0000;
    localparam X_ADDR    = DMEM_BASE + 32'h100;
    localparam W_ADDR    = DMEM_BASE + 32'h200;

    localparam K_NOP = 3'd0, K_LOAD = 3'd1, K_MAC = 3'd2, K_STORE = 3'd3, K_RELU = 3'd4;
    localparam [4:0] V_ZERO = 5'd12;

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

    // Read by convoy_relu_trace.tcl
    reg       trace_en;
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
    integer i, b;
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
            K_MAC: begin    // vd <- vd + vs1*vs2
                I_start <= 1'b1;  I_vs1 <= slot_vs1[s];  I_vs2 <= slot_vs2[s];
                I_vd <= slot_vd[s];  I_funct <= 8'b00000011;  I_reg_we <= 1'b1;
            end
            K_RELU: begin   // vd <- max(vd, 0)   (exactly what the controller drives)
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

    reg signed [31:0] got [0:7];
    reg signed [31:0] exp [0:7];

    task write_vreg(input [4:0] vreg, input integer e, input [31:0] data);
    begin
        proc_write(VREG_BASE + (vreg << 5) + (e << 2), data);
    end
    endtask

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

    // mixed-sign preload: +100, -200, +300, -400, ...
    function signed [31:0] mixed(input integer e);
        mixed = (e % 2) ? -100 * (e + 1) : 100 * (e + 1);
    endfunction
    function signed [31:0] relu(input signed [31:0] v);
        relu = (v < 0) ? 0 : v;
    endfunction
    // acc + X*W with acc = -200, X = e+1, W = 10*(e+1)
    function signed [31:0] macv(input integer e);
        macv = -200 + (e + 1) * 10 * (e + 1);
    endfunction

    task prog_relu_store(input [4:0] vacc, input [31:0] out_addr);
    begin
        n_slots = 2;
        slot_kind[0] = K_RELU;   slot_vd[0] = vacc;
        slot_kind[1] = K_STORE;  slot_vd[1] = vacc;  slot_addr[1] = out_addr;
    end
    endtask

    task prog_mac(input [4:0] vacc);
    begin
        n_slots = 4;
        slot_kind[0] = K_LOAD;  slot_vd[0] = 5'd1;  slot_addr[0] = X_ADDR;
        slot_kind[1] = K_LOAD;  slot_vd[1] = 5'd2;  slot_addr[1] = W_ADDR;
        slot_kind[2] = K_NOP;
        slot_kind[3] = K_MAC;   slot_vd[3] = vacc;  slot_vs1[3] = 5'd1;  slot_vs2[3] = 5'd2;
    end
    endtask

    task start_trace(input [7:0] slots);
    begin
        trace_slots = slots;  busy_cycles = 0;  stall_cycles = 0;  trace_en = 1'b1;
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
            proc_write(X_ADDR + (i << 2), i + 1);
            proc_write(W_ADDR + (i << 2), 10 * (i + 1));
        end

        // ================= R2 =================
        $display("");
        $display("=== R2 (slots 0,1): ReLU v8 = max(v8, v12=0) | store v8, preloaded mixed-sign v8, vl=8 ===");
        for (i = 0; i < 8; i = i + 1) write_vreg(5'd8, i, mixed(i));
        prog_relu_store(5'd8, DMEM_BASE + 32'h300);
        start_trace(8'b0000_0001);
        issue_slots;  clear_on_done;  settle;
        trace_en = 1'b0;
        $display("    R2 DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        for (b = 0; b < 8; b = b + 1) exp[b] = relu(mixed(b));
        read_mem(DMEM_BASE + 32'h300);  compare("OUT (mem)   ");
        read_vreg(5'd8);                compare("acc (vrf)   ");

        // ================= MR_done =================
        $display("");
        $display("=== MR_done: A = load v1 | load v2 | (empty) | MAC v9+=v1*v2, wait DONE, clear; B = ReLU v9 | store v9 ===");
        for (i = 0; i < 8; i = i + 1) write_vreg(5'd9, i, -200);
        start_trace(8'b0000_1001);
        prog_mac(5'd9);
        issue_slots;  clear_on_done;
        prog_relu_store(5'd9, DMEM_BASE + 32'h400);
        issue_slots;  clear_on_done;  settle;
        trace_en = 1'b0;
        $display("    MR_done DONE-low cycles (A+B) = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        for (b = 0; b < 8; b = b + 1) exp[b] = relu(macv(b));
        read_mem(DMEM_BASE + 32'h400);  compare("OUT (mem)   ");
        read_vreg(5'd9);                compare("acc (vrf)   ");

        // ================= MR_early =================
        $display("");
        $display("=== MR_early: A = load|load|(empty)|MAC v10, clear 8 cycles after A's last slot; B = ReLU v10 | store v10, clear 8 cycles after; C = ReLU v11 | store v11 ===");
        for (i = 0; i < 8; i = i + 1) write_vreg(5'd10, i, -200);
        for (i = 0; i < 8; i = i + 1) write_vreg(5'd11, i, mixed(i));
        start_trace(8'b0000_1001);
        prog_mac(5'd10);
        issue_slots;  clear_after(8);
        prog_relu_store(5'd10, DMEM_BASE + 32'h500);
        issue_slots;  clear_after(8);
        prog_relu_store(5'd11, DMEM_BASE + 32'h520);
        issue_slots;  clear_on_done;  settle;
        trace_en = 1'b0;
        $display("    MR_early DONE-low cycles (A+B+C) = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        for (b = 0; b < 8; b = b + 1) exp[b] = relu(macv(b));
        read_mem(DMEM_BASE + 32'h500);  compare("OUT_B (mem) ");
        read_vreg(5'd10);               compare("v10 (vrf)   ");
        for (b = 0; b < 8; b = b + 1) exp[b] = relu(mixed(b));
        read_mem(DMEM_BASE + 32'h520);  compare("OUT_C (mem) ");
        read_vreg(5'd11);               compare("v11 (vrf)   ");

        // ================= MRS =================
        $display("");
        $display("=== MRS (slots 0,1,-,3,4,5): load v1 | load v2 | (empty) | MAC v13+=v1*v2 | ReLU v13 | store v13, one convoy ===");
        for (i = 0; i < 8; i = i + 1) write_vreg(5'd13, i, -200);
        prog_mac(5'd13);
        n_slots = 6;
        slot_kind[4] = K_RELU;   slot_vd[4] = 5'd13;
        slot_kind[5] = K_STORE;  slot_vd[5] = 5'd13;  slot_addr[5] = DMEM_BASE + 32'h600;
        start_trace(8'b0001_1000);
        issue_slots;  clear_on_done;  settle;
        trace_en = 1'b0;
        $display("    MRS DONE-low cycles = %0d, stall cycles = %0d", busy_cycles, stall_cycles);
        for (b = 0; b < 8; b = b + 1) exp[b] = relu(macv(b));
        read_mem(DMEM_BASE + 32'h600);  compare("OUT (mem)   ");
        read_vreg(5'd13);               compare("acc (vrf)   ");

        sim_done = 1'b1;
        repeat (2) @(posedge clk);
        $finish;
    end

endmodule
