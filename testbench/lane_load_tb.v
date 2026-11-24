`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: lane_load_tb
//
// Minimal, isolated testbench for the instruction-bank load/execute protocol.
// DUT is v_wrapper alone (no atee_top, no hbm_lite_controller, no DMA) — the
// testbench drives I_id / I_start / instruction fields directly.
//
// EXP A: vec_id=0 then vec_id=1, vl=1, different addresses, different vd.
// EXP B: same as A but both slots target the SAME vd.
// EXP C: vec_id=0..7 loaded on 8 consecutive cycles, vl=1, 8 addresses, 8 vds.
// EXP D: one instruction in slot 0 with vl=8, unit-stride over 8 addresses.
// EXP E: same as D with vl=9.
//
// Results are read back through the proc (CPU) interface, which is only
// routed to the VRF/DMEM while DONE=1.
//////////////////////////////////////////////////////////////////////////////////

module lane_load_tb;

    parameter CLK_PERIOD = 20;       // 50 MHz

    localparam DMEM_BASE = 32'h0010_0000;   // bank = addr[4:2], row = addr[18:5]
    localparam VREG_BASE = 32'h0018_0000;   // reg  = addr[9:5], bank = addr[4:2]

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

    // Read by lane_load_trace.tcl to gate the per-cycle internal trace
    reg trace_en;
    reg sim_done;

    // Slot programme for run_loads
    integer     n_slots;
    reg  [4:0]  slot_vd   [0:7];
    reg  [31:0] slot_addr [0:7];

    integer busy_cycles;
    integer errors;
    integer i, b;
    reg [31:0] rd;
    reg [31:0] bank_val [0:7];

    // Cycles with DONE low, sampled mid-cycle; zeroed at the start of run_loads
    always @(negedge clk)
        if (trace_en && !DONE_out) busy_cycles = busy_cycles + 1;

    task drive_idle;
    begin
        I_start <= 1'b0;  I_id <= 3'd0;
        I_vs1 <= 5'd0;    I_vs2 <= 5'd0;   I_vd <= 5'd0;
        I_RS1 <= 32'd0;   I_RS2 <= 32'd0;  I_uimm5 <= 5'd0;
        I_funct <= 8'd0;  I_permute <= 2'd0; I_mask_en <= 1'b0;
        I_ALUSrc <= 2'b00; I_dmr <= 1'b0;  I_dmw <= 1'b0;
        I_reg_we <= 1'b0; I_mem_reg <= 1'b0; I_Xout <= 1'b0;
        I_mode_lsu <= 2'b00;
    end
    endtask

    // Unit-stride vector load: vd <- DMEM[addr + 4*count]
    task drive_load(input [2:0] id, input [4:0] vd, input [31:0] addr);
    begin
        drive_idle;
        I_start <= 1'b1;  I_id <= id;  I_vd <= vd;  I_RS1 <= addr;
        I_dmr <= 1'b1;    I_reg_we <= 1'b1;  I_mem_reg <= 1'b1;
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

    // Read all 8 banks of one vector register into bank_val[]
    task read_vreg(input [4:0] vreg);
    begin
        for (b = 0; b < 8; b = b + 1) begin
            proc_read(VREG_BASE + (vreg << 5) + (b << 2), rd);
            bank_val[b] = rd;
        end
        $display("    v%-2d banks[0..7] = %h %h %h %h %h %h %h %h", vreg,
                 bank_val[0], bank_val[1], bank_val[2], bank_val[3],
                 bank_val[4], bank_val[5], bank_val[6], bank_val[7]);
    end
    endtask

    // Load slots 0..n_slots-1 on consecutive cycles (one I_id per cycle), hold
    // the last slot's instruction until DONE returns, then I_clear.
    task run_loads;
        integer s;
        integer guard;
    begin
        trace_en = 1'b1;
        busy_cycles = 0;
        @(posedge clk);
        drive_load(3'd0, slot_vd[0], slot_addr[0]);
        for (s = 1; s < n_slots; s = s + 1) begin
            @(posedge clk);
            drive_load(s[2:0], slot_vd[s], slot_addr[s]);
        end
        // Last slot is captured by the bank at this edge; keep holding it
        @(posedge clk);
        @(negedge clk);
        guard = 0;
        while (!DONE_out && guard < 400) begin
            guard = guard + 1;
            @(negedge clk);
        end
        if (guard >= 400) begin
            $display("    TIMEOUT waiting for DONE");
            errors = errors + 1;
        end
        @(posedge clk);
        drive_idle;
        I_clear <= 1'b1;
        @(posedge clk);
        I_clear <= 1'b0;
        repeat (4) @(posedge clk);
        trace_en = 1'b0;
        $display("    DONE low for %0d cycles", busy_cycles);
    end
    endtask

    initial begin
        vl = 9'd1;  vcsr_quant = 2'b00;  I_clear = 1'b0;
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        trace_en = 1'b0;  sim_done = 1'b0;  errors = 0;
        I_start = 0; I_id = 0; I_vs1 = 0; I_vs2 = 0; I_vd = 0; I_RS1 = 0; I_RS2 = 0;
        I_uimm5 = 0; I_funct = 0; I_permute = 0; I_mask_en = 0; I_ALUSrc = 0;
        I_dmr = 0; I_dmw = 0; I_reg_we = 0; I_mem_reg = 0; I_Xout = 0; I_mode_lsu = 0;

        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);

        // ---- Preload DMEM through the proc interface ----
        // row 0: 2 words (banks 0,1) for EXP A/B; row 2: 8 words for EXP C/D
        proc_write(DMEM_BASE + 32'h00, 32'hAAAA_0001);
        proc_write(DMEM_BASE + 32'h04, 32'hBBBB_0002);
        for (i = 0; i < 8; i = i + 1)
            proc_write(DMEM_BASE + 32'h40 + (i << 2), 32'hC0DE_0000 + i);
        proc_read(DMEM_BASE + 32'h00, rd);
        $display("DMEM readback [bank0,row0] = %h (expect aaaa0001)", rd);
        proc_read(DMEM_BASE + 32'h04, rd);
        $display("DMEM readback [bank1,row0] = %h (expect bbbb0002)", rd);

        // ================= EXP A =================
        $display("");
        $display("=== EXP A: vec_id=0 -> v1 <- [bank0], vec_id=1 -> v2 <- [bank1], vl=1 ===");
        vl = 9'd1;  n_slots = 2;
        slot_vd[0] = 5'd1;  slot_addr[0] = DMEM_BASE + 32'h00;
        slot_vd[1] = 5'd2;  slot_addr[1] = DMEM_BASE + 32'h04;
        run_loads;
        read_vreg(5'd1);
        if (bank_val[0] !== 32'hAAAA_0001) errors = errors + 1;
        $display("    slot0 -> v1[bank0] = %h (expect aaaa0001) %s", bank_val[0],
                 (bank_val[0] === 32'hAAAA_0001) ? "OK" : "MISMATCH");
        read_vreg(5'd2);
        if (bank_val[0] !== 32'hBBBB_0002) errors = errors + 1;
        $display("    slot1 -> v2[bank0] = %h (expect bbbb0002) %s", bank_val[0],
                 (bank_val[0] === 32'hBBBB_0002) ? "OK" : "MISMATCH");
        $display("EXP A: %s", (errors == 0) ? "PASS" : "FAIL");

        // ================= EXP B =================
        $display("");
        $display("=== EXP B: vec_id=0 and vec_id=1 both -> v3, different addresses, vl=1 ===");
        n_slots = 2;
        slot_vd[0] = 5'd3;  slot_addr[0] = DMEM_BASE + 32'h00;
        slot_vd[1] = 5'd3;  slot_addr[1] = DMEM_BASE + 32'h04;
        run_loads;
        read_vreg(5'd3);
        begin : expb
            integer seen_a, seen_b;
            seen_a = 0; seen_b = 0;
            for (b = 0; b < 8; b = b + 1) begin
                if (bank_val[b] === 32'hAAAA_0001) seen_a = seen_a + 1;
                if (bank_val[b] === 32'hBBBB_0002) seen_b = seen_b + 1;
            end
            $display("EXP B: slot0 value present in v3: %s, slot1 value present in v3: %s",
                     seen_a ? "YES" : "NO", seen_b ? "YES" : "NO");
        end

        // ================= EXP C =================
        $display("");
        $display("=== EXP C: vec_id=0..7 on 8 consecutive cycles, slot j -> v(8+j) <- word j, vl=1 ===");
        n_slots = 8;
        for (i = 0; i < 8; i = i + 1) begin
            slot_vd[i]   = 5'd8 + i;
            slot_addr[i] = DMEM_BASE + 32'h40 + (i << 2);
        end
        run_loads;
        begin : expc
            integer good;
            good = 0;
            for (i = 0; i < 8; i = i + 1) begin
                read_vreg(5'd8 + i);
                if (bank_val[0] === 32'hC0DE_0000 + i) good = good + 1;
            end
            $display("EXP C: %0d of 8 slots landed their value in bank 0 of their vd", good);
        end

        // ================= EXP D =================
        $display("");
        $display("=== EXP D: single instruction in slot 0, vl=8, unit-stride -> v4 ===");
        vl = 9'd8;  n_slots = 1;
        slot_vd[0] = 5'd4;  slot_addr[0] = DMEM_BASE + 32'h40;
        run_loads;
        read_vreg(5'd4);
        begin : expd
            integer good;
            good = 0;
            for (b = 0; b < 8; b = b + 1)
                if (bank_val[b] === 32'hC0DE_0000 + b) good = good + 1;
            if (good != 8) errors = errors + 1;
            $display("EXP D: %0d of 8 elements correct -> %s", good, (good == 8) ? "PASS" : "FAIL");
        end

        // ================= EXP E =================
        $display("");
        $display("=== EXP E: same as D but vl=9 -> v5 (does vl=N+1 give N elements?) ===");
        vl = 9'd9;  n_slots = 1;
        slot_vd[0] = 5'd5;  slot_addr[0] = DMEM_BASE + 32'h40;
        run_loads;
        read_vreg(5'd5);
        begin : expe
            integer good;
            good = 0;
            for (b = 0; b < 8; b = b + 1)
                if (bank_val[b] === 32'hC0DE_0000 + b) good = good + 1;
            $display("EXP E: %0d of 8 elements correct in v5", good);
        end
        read_vreg(5'd6);   // element 8 would spill into v6[bank0]

        $display("");
        $display("TOTAL CHECK ERRORS (EXP A + EXP D): %0d", errors);
        sim_done = 1'b1;
        repeat (2) @(posedge clk);
        $finish;
    end

endmodule
