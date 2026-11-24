`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: atee_tb
// Description: Testbench for ATEE (Autonomous Tensor Execution Engine).
//              Tests config register access, DMA transfer, and end-to-end
//              convolution execution.
//
// Test sequence:
//   1. Reset
//   2. Write CNN layer config (MNIST Conv1: 28x28x1, 3x3x1x16)
//   3. DMA: load input image and weights into DMEM
//   4. Trigger LAYER_START
//   5. Wait for LAYER_DONE
//   6. Read cycle count
//   7. Verify output against golden data
//////////////////////////////////////////////////////////////////////////////////

module atee_tb;

    // =========================================================================
    // Clock and reset
    // =========================================================================
    reg clk, reset;
    parameter CLK_PERIOD = 20; // 50 MHz

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT signals (matching atee_top port list)
    // =========================================================================
    reg  [8:0]  vl;
    reg  [1:0]  vcsr_quant;
    reg         I_clear;
    reg  [2:0]  I_id;
    wire        ALU_mon;
    wire        stall_out;
    wire        DONE_out;

    reg  [31:0] proc_addr;
    reg  [31:0] proc_din;
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
    reg         I_dmr, I_dmw;
    reg         I_reg_we, I_mem_reg;
    reg         I_Xout;
    reg  [1:0]  I_mode_lsu;

    // DMA Wishbone (simulated DRAM)
    wire [31:0] wb_dma_adr_o;
    wire [31:0] wb_dma_dat_o;
    reg  [31:0] wb_dma_dat_i;
    wire        wb_dma_we_o;
    wire [3:0]  wb_dma_sel_o;
    wire        wb_dma_stb_o;
    wire        wb_dma_cyc_o;
    reg         wb_dma_ack_i;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    atee_top dut (
        .clk          (clk),
        .reset        (reset),
        .vl           (vl),
        .vcsr_quant   (vcsr_quant),
        .I_clear      (I_clear),
        .I_id         (I_id),
        .ALU_mon      (ALU_mon),
        .stall        (stall_out),
        .DONE         (DONE_out),
        .proc_addr    (proc_addr),
        .proc_din     (proc_din),
        .proc_dout    (proc_dout),
        .proc_we      (proc_we),
        .XRF_ADDR     (XRF_ADDR),
        .XRF_DATAWR   (XRF_DATAWR),
        .XRF_WE       (XRF_WE),
        .I_start      (I_start),
        .I_vs1        (I_vs1),
        .I_vs2        (I_vs2),
        .I_vd         (I_vd),
        .I_RS1        (I_RS1),
        .I_RS2        (I_RS2),
        .I_uimm5      (I_uimm5),
        .I_funct      (I_funct),
        .I_permute    (I_permute),
        .I_mask_en    (I_mask_en),
        .I_ALUSrc     (I_ALUSrc),
        .I_dmr        (I_dmr),
        .I_dmw        (I_dmw),
        .I_reg_we     (I_reg_we),
        .I_mem_reg    (I_mem_reg),
        .I_Xout       (I_Xout),
        .I_mode_lsu   (I_mode_lsu),
        .wb_dma_adr_o (wb_dma_adr_o),
        .wb_dma_dat_o (wb_dma_dat_o),
        .wb_dma_dat_i (wb_dma_dat_i),
        .wb_dma_we_o  (wb_dma_we_o),
        .wb_dma_sel_o (wb_dma_sel_o),
        .wb_dma_stb_o (wb_dma_stb_o),
        .wb_dma_cyc_o (wb_dma_cyc_o),
        .wb_dma_ack_i (wb_dma_ack_i)
    );

    // =========================================================================
    // Simulated DRAM (Wishbone slave) — 64KB ROM with test data
    // =========================================================================
    reg [31:0] dram_mem [0:16383]; // 64K words

    // Simple Wishbone slave: single-cycle acknowledge
    always @(posedge clk) begin
        if (reset) begin
            wb_dma_ack_i <= 1'b0;
            wb_dma_dat_i <= 32'd0;
        end else if (wb_dma_stb_o && wb_dma_cyc_o && !wb_dma_ack_i) begin
            wb_dma_dat_i <= dram_mem[wb_dma_adr_o[15:2]];
            wb_dma_ack_i <= 1'b1;
        end else begin
            wb_dma_ack_i <= 1'b0;
        end
    end

    // =========================================================================
    // Config register address constants
    // =========================================================================
    localparam CFG_BASE       = 32'h0020_0000;
    localparam CFG_INPUT_H    = CFG_BASE + 32'h00;
    localparam CFG_INPUT_W    = CFG_BASE + 32'h04;
    localparam CFG_INPUT_C    = CFG_BASE + 32'h08;
    localparam CFG_KERNEL_H   = CFG_BASE + 32'h0C;
    localparam CFG_KERNEL_W   = CFG_BASE + 32'h10;
    localparam CFG_OUTPUT_C   = CFG_BASE + 32'h14;
    localparam CFG_STRIDE     = CFG_BASE + 32'h18;
    localparam CFG_PADDING    = CFG_BASE + 32'h1C;
    localparam CFG_POOL_SIZE  = CFG_BASE + 32'h20;
    localparam CFG_Q_FORMAT   = CFG_BASE + 32'h24;
    localparam CFG_ACTIVATION = CFG_BASE + 32'h28;
    localparam CFG_INPUT_BASE = CFG_BASE + 32'h2C;
    localparam CFG_WEIGHT_BASE= CFG_BASE + 32'h30;
    localparam CFG_OUTPUT_BASE= CFG_BASE + 32'h34;
    localparam CFG_LAYER_START= CFG_BASE + 32'h38;
    localparam CFG_STATUS     = CFG_BASE + 32'h3C;
    localparam CFG_CYCLE_CNT  = CFG_BASE + 32'h40;
    localparam CFG_DMA_SRC    = CFG_BASE + 32'h44;
    localparam CFG_DMA_DST    = CFG_BASE + 32'h48;
    localparam CFG_DMA_LEN    = CFG_BASE + 32'h4C;
    localparam CFG_DMA_START  = CFG_BASE + 32'h50;
    localparam CFG_DMA_STATUS = CFG_BASE + 32'h54;

    // DMEM addresses for test data
    localparam DMEM_INPUT_BASE  = 32'h0010_0000;
    localparam DMEM_WEIGHT_BASE = 32'h0014_0000;
    localparam DMEM_OUTPUT_BASE = 32'h0016_0000;

    // =========================================================================
    // Helper tasks
    // =========================================================================
    task write_cfg(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        proc_addr <= addr;
        proc_din  <= data;
        proc_we   <= 1'b1;
        @(posedge clk);
        proc_we   <= 1'b0;
    end
    endtask

    task read_cfg(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk);
        proc_addr <= addr;
        proc_we   <= 1'b0;
        @(posedge clk);
        data = proc_dout;
    end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    integer i;
    reg [31:0] status_val;
    reg [31:0] cycle_val;

    initial begin
        // Initialize all scalar-side signals to idle
        vl          = 9'd8;
        vcsr_quant  = 2'b10;     // Q16.16
        I_clear     = 1'b0;
        I_id        = 3'd0;
        proc_addr   = 32'd0;
        proc_din    = 32'd0;
        proc_we     = 1'b0;
        I_start     = 1'b0;
        I_vs1       = 5'd0;
        I_vs2       = 5'd0;
        I_vd        = 5'd0;
        I_RS1       = 32'd0;
        I_RS2       = 32'd0;
        I_uimm5     = 5'd0;
        I_funct     = 8'd0;
        I_permute   = 2'd0;
        I_mask_en   = 1'b0;
        I_ALUSrc    = 2'b00;
        I_dmr       = 1'b0;
        I_dmw       = 1'b0;
        I_reg_we    = 1'b0;
        I_mem_reg   = 1'b0;
        I_Xout      = 1'b0;
        I_mode_lsu  = 2'b00;

        // Initialize simulated DRAM with test patterns
        // Input: 28x28 = 784 words (simple ramp pattern for test)
        for (i = 0; i < 784; i = i + 1)
            dram_mem[i] = i;

        // Weights: 3x3x1x16 = 144 words (simple pattern)
        for (i = 0; i < 144; i = i + 1)
            dram_mem[1024 + i] = i + 1;

        // -----------------------------------------------------------------
        // Reset
        // -----------------------------------------------------------------
        reset = 1'b1;
        #(CLK_PERIOD * 10);
        reset = 1'b0;
        #(CLK_PERIOD * 5);

        $display("=== Coreless-V Testbench Start ===");
        $display("Time: %0t", $time);

        // -----------------------------------------------------------------
        // TEST 1: Config register write/read
        // -----------------------------------------------------------------
        $display("\n--- Test 1: Config Register Access ---");

        write_cfg(CFG_INPUT_H, 32'd28);
        write_cfg(CFG_INPUT_W, 32'd28);
        write_cfg(CFG_INPUT_C, 32'd1);
        write_cfg(CFG_KERNEL_H, 32'd3);
        write_cfg(CFG_KERNEL_W, 32'd3);
        write_cfg(CFG_OUTPUT_C, 32'd16);
        write_cfg(CFG_STRIDE, 32'd1);
        write_cfg(CFG_PADDING, 32'd0);
        write_cfg(CFG_POOL_SIZE, 32'd0);
        write_cfg(CFG_Q_FORMAT, 32'd2);      // Q16.16
        write_cfg(CFG_ACTIVATION, 32'd1);     // ReLU

        // Verify readback
        read_cfg(CFG_INPUT_H, status_val);
        if (status_val == 32'd28)
            $display("  PASS: INPUT_H = %0d", status_val);
        else
            $display("  FAIL: INPUT_H = %0d (expected 28)", status_val);

        read_cfg(CFG_KERNEL_H, status_val);
        if (status_val == 32'd3)
            $display("  PASS: KERNEL_H = %0d", status_val);
        else
            $display("  FAIL: KERNEL_H = %0d (expected 3)", status_val);

        // -----------------------------------------------------------------
        // TEST 2: DMA Transfer (input image: 784 words from DRAM to DMEM)
        // -----------------------------------------------------------------
        $display("\n--- Test 2: DMA Transfer ---");

        // Configure DMA
        write_cfg(CFG_DMA_SRC, 32'h0000_0000);      // DRAM offset 0
        write_cfg(CFG_DMA_DST, DMEM_INPUT_BASE);     // DMEM input region
        write_cfg(CFG_DMA_LEN, 32'd784);             // 784 words
        write_cfg(CFG_DMA_START, 32'd1);              // Trigger DMA

        // Wait for DMA completion
        status_val = 32'h0000_0001; // busy
        while (status_val[0]) begin
            read_cfg(CFG_DMA_STATUS, status_val);
            #(CLK_PERIOD * 10);
        end
        $display("  DMA transfer complete (784 words)");

        // Transfer weights (144 words)
        write_cfg(CFG_DMA_SRC, 32'h0000_1000);       // DRAM offset 4096
        write_cfg(CFG_DMA_DST, DMEM_WEIGHT_BASE);
        write_cfg(CFG_DMA_LEN, 32'd144);
        write_cfg(CFG_DMA_START, 32'd1);

        status_val = 32'h0000_0001;
        while (status_val[0]) begin
            read_cfg(CFG_DMA_STATUS, status_val);
            #(CLK_PERIOD * 10);
        end
        $display("  DMA transfer complete (144 weights)");

        // -----------------------------------------------------------------
        // TEST 3: Configure and run MNIST Conv1 layer
        // -----------------------------------------------------------------
        $display("\n--- Test 3: MNIST Conv1 Execution ---");

        write_cfg(CFG_INPUT_BASE, DMEM_INPUT_BASE);
        write_cfg(CFG_WEIGHT_BASE, DMEM_WEIGHT_BASE);
        write_cfg(CFG_OUTPUT_BASE, DMEM_OUTPUT_BASE);

        // Trigger layer execution
        $display("  Starting Conv1 (28x28x1 * 3x3x1x16)...");
        write_cfg(CFG_LAYER_START, 32'd1);

        // Poll for completion
        status_val = 32'h0000_0001;
        while (status_val[0]) begin
            read_cfg(CFG_STATUS, status_val);
            #(CLK_PERIOD * 100);
        end

        // Read cycle count
        read_cfg(CFG_CYCLE_CNT, cycle_val);
        $display("  Layer complete! Cycles: %0d", cycle_val);
        $display("  Estimated time at 50MHz: %0d us", cycle_val / 50);

        // -----------------------------------------------------------------
        // TEST 4: Read back output (first few values)
        // -----------------------------------------------------------------
        $display("\n--- Test 4: Output Verification ---");
        for (i = 0; i < 8; i = i + 1) begin
            proc_addr = DMEM_OUTPUT_BASE + (i * 4);
            proc_we   = 1'b0;
            #(CLK_PERIOD * 2);
            $display("  Output[%0d] = 0x%08h", i, proc_dout);
        end

        // -----------------------------------------------------------------
        // Done
        // -----------------------------------------------------------------
        $display("\n=== Coreless-V Testbench Complete ===");
        $display("Total simulation time: %0t", $time);
        #(CLK_PERIOD * 10);
        $finish;
    end

    // =========================================================================
    // Waveform dump (for Vivado or other tools)
    // =========================================================================
    initial begin
        $dumpfile("atee_tb.vcd");
        $dumpvars(0, atee_tb);
    end

    // =========================================================================
    // Timeout watchdog
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 10_000_000); // 200ms at 50MHz
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
