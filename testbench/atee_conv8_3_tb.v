`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: atee_conv8_3_tb
//
// BRAM-only functional testbench for conv8_3 (8x8x1 input, 3x3 kernel,
// 16 filters, 576 outputs). NO DMA, NO DRAM: the .hex images are written
// straight into DMEM through the proc interface before the layer starts.
//
// Data layout (see scripts/generate_test_data.py):
//   test1_input.hex   512 words: pixel p replicated in words p*8 .. p*8+7
//   test1_weights.hex 144 words: OC-innermost  [(kh*3+kw)*16 + oc]
//   test1_golden.hex  576 words: OC-innermost  [(oh*6+ow)*16 + oc]
// Line i of each file is word i of its DMEM region (byte address base + 4*i).
//
// Cycle count = tensor_config_regs CYCLE_COUNT (cycles with layer_busy=1).
// Loading DMEM is not included in that count.
//////////////////////////////////////////////////////////////////////////////////

module atee_conv8_3_tb;

    parameter CLK_PERIOD = 20;       // 50 MHz
    parameter ERR_LIMIT  = 10;       // Same as repo's err_limit in conv benchmarks

`ifdef MNIST_CONV1
    // xvlog -d MNIST_CONV1: 28x28x1 MNIST digit, trained 3x3x1x16 kernels,
    // BIAS OMITTED (the controller has no bias path). test2_*.hex.
    parameter IMG_SIZE   = 28;
    parameter KER_SIZE   = 3;
    parameter N_FILT     = 16;
    parameter OUT_SIZE   = 26;       // 28 - 3 + 1
    parameter IN_WORDS   = 6272;     // 784 pixels x 8 (replicated)
    parameter KER_WORDS  = 144;      // 9 x 16
    parameter OUT_TOTAL  = 10816;    // 26 x 26 x 16
`else
    parameter IMG_SIZE   = 8;
    parameter KER_SIZE   = 3;
    parameter N_FILT     = 16;
    parameter OUT_SIZE   = 6;        // 8 - 3 + 1
    parameter IN_WORDS   = 512;      // 64 pixels x 8 (replicated)
    parameter KER_WORDS  = 144;      // 9 x 16
    parameter OUT_TOTAL  = 576;      // 6 x 6 x 16
`endif
    // Without either define the controller's own EARLY_CLEAR default is used
    // (and archived controllers that have no such parameter still elaborate).
`ifdef EARLY_CLEAR_ON
    parameter EARLY_CLEAR = 1;       // xvlog -d EARLY_CLEAR_ON
`else
    parameter EARLY_CLEAR = 0;       // only applied with xvlog -d EARLY_CLEAR_OFF
`endif
`ifdef RELU_ON
    parameter ACTIVATION = 1;        // xvlog -d RELU_ON: layer runs with ReLU
`else
    parameter ACTIVATION = 0;
`endif

    reg clk, reset;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg  [31:0] proc_addr, proc_din;
    wire [31:0] proc_dout;
    reg         proc_we;
    wire        ALU_mon, stall_out, DONE_out;
    wire [4:0]  XRF_ADDR;
    wire [31:0] XRF_DATAWR;
    wire        XRF_WE;

    // Scalar-core vector instruction inputs are unused: the testbench only
    // writes config registers and DMEM, standing in for the CPU.
    atee_top dut (
        .clk(clk), .reset(reset),
        .vl(9'd8), .vcsr_quant(2'b00), .I_clear(1'b0), .I_id(3'd0),
        .ALU_mon(ALU_mon), .stall(stall_out), .DONE(DONE_out),
        .proc_addr(proc_addr), .proc_din(proc_din), .proc_dout(proc_dout), .proc_we(proc_we),
        .XRF_ADDR(XRF_ADDR), .XRF_DATAWR(XRF_DATAWR), .XRF_WE(XRF_WE),
        .I_start(1'b0), .I_vs1(5'd0), .I_vs2(5'd0), .I_vd(5'd0),
        .I_RS1(32'd0), .I_RS2(32'd0), .I_uimm5(5'd0), .I_funct(8'd0),
        .I_permute(2'd0), .I_mask_en(1'b0), .I_ALUSrc(2'b00),
        .I_dmr(1'b0), .I_dmw(1'b0), .I_reg_we(1'b0), .I_mem_reg(1'b0),
        .I_Xout(1'b0), .I_mode_lsu(2'b00)
    );

`ifdef DIV_OFF
    defparam dut.ENABLE_DIV = 0;         // xvlog -d DIV_OFF: divider hardware removed
`endif
`ifdef EARLY_CLEAR_ON
    defparam dut.u_hbm_lite.EARLY_CLEAR = EARLY_CLEAR;
`endif
`ifdef EARLY_CLEAR_OFF
    defparam dut.u_hbm_lite.EARLY_CLEAR = EARLY_CLEAR;
`endif

    // Config register addresses
    localparam CFG_BASE        = 32'h0020_0000;
    localparam CFG_INPUT_H     = CFG_BASE + 32'h00;
    localparam CFG_INPUT_W     = CFG_BASE + 32'h04;
    localparam CFG_INPUT_C     = CFG_BASE + 32'h08;
    localparam CFG_KERNEL_H    = CFG_BASE + 32'h0C;
    localparam CFG_KERNEL_W    = CFG_BASE + 32'h10;
    localparam CFG_OUTPUT_C    = CFG_BASE + 32'h14;
    localparam CFG_STRIDE      = CFG_BASE + 32'h18;
    localparam CFG_PADDING     = CFG_BASE + 32'h1C;
    localparam CFG_POOL_SIZE   = CFG_BASE + 32'h20;
    localparam CFG_Q_FORMAT    = CFG_BASE + 32'h24;
    localparam CFG_ACTIVATION  = CFG_BASE + 32'h28;
    localparam CFG_INPUT_BASE  = CFG_BASE + 32'h2C;
    localparam CFG_WEIGHT_BASE = CFG_BASE + 32'h30;
    localparam CFG_OUTPUT_BASE = CFG_BASE + 32'h34;
    localparam CFG_LAYER_START = CFG_BASE + 32'h38;
    localparam CFG_STATUS      = CFG_BASE + 32'h3C;
    localparam CFG_CYCLE_CNT   = CFG_BASE + 32'h40;

    // DMEM regions (all 32-byte aligned)
    localparam DMEM_INPUT_BASE  = 32'h0010_0000;
    localparam DMEM_WEIGHT_BASE = 32'h0014_0000;
    localparam DMEM_OUTPUT_BASE = 32'h0016_0000;

    reg [31:0] input_mem  [0:IN_WORDS-1];
    reg [31:0] weight_mem [0:KER_WORDS-1];
    reg [31:0] golden     [0:OUT_TOTAL-1];

    // Same access task for config registers and DMEM words
    task proc_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        proc_addr <= addr;  proc_din <= data;  proc_we <= 1'b1;
        @(posedge clk);
        proc_we <= 1'b0;
    end
    endtask

    task proc_read(input [31:0] addr, output [31:0] data);
    begin
        @(posedge clk);
        proc_addr <= addr;  proc_we <= 1'b0;
        @(posedge clk);
        @(negedge clk);
        data = proc_dout;
    end
    endtask

    integer i;
    integer err_count, exact_err, max_abs_err, abs_err;
    reg [31:0] status, cycle_count, computed;
    reg signed [31:0] diff;

    initial begin
`ifdef MNIST_CONV1
        $readmemh("test2_input.hex",   input_mem);
        $readmemh("test2_weights.hex", weight_mem);
`ifdef RELU_ON
        $readmemh("test2_golden_relu.hex", golden);
`else
        $readmemh("test2_golden.hex",  golden);
`endif
`else
        $readmemh("test1_input.hex",   input_mem);
        $readmemh("test1_weights.hex", weight_mem);
        $readmemh("test1_golden.hex",  golden);
`endif

        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        reset = 1'b1;
        #(CLK_PERIOD * 20);
        reset = 1'b0;
        #(CLK_PERIOD * 5);

        $display("");
        $display("================================================================");
`ifdef MNIST_CONV1
        $display("  MNIST conv1 (bias omitted), BRAM-only (no DMA): %0dx%0dx1 input, %0dx%0d kernel, %0d filters",
                 IMG_SIZE, IMG_SIZE, KER_SIZE, KER_SIZE, N_FILT);
`else
        $display("  conv8_3, BRAM-only (no DMA): 8x8x1 input, 3x3 kernel, 16 filters");
`endif
`ifdef EARLY_CLEAR_ON
        $display("  vl=8 over output channel, output-stationary, EARLY_CLEAR forced to 1, ACTIVATION=%0d", ACTIVATION);
`else
`ifdef EARLY_CLEAR_OFF
        $display("  vl=8 over output channel, output-stationary, EARLY_CLEAR forced to 0, ACTIVATION=%0d", ACTIVATION);
`else
        $display("  vl=8 over output channel, output-stationary, EARLY_CLEAR = controller default, ACTIVATION=%0d", ACTIVATION);
`endif
`endif
`ifdef DIV_OFF
        $display("  DIVIDER: REMOVED (ENABLE_DIV=0)");
`else
        $display("  DIVIDER: present (design default)");
`endif
        $display("================================================================");

        $display("  [1/4] Writing DMEM directly: %0d input words (replicated), %0d weight words",
                 IN_WORDS, KER_WORDS);
        for (i = 0; i < IN_WORDS; i = i + 1)
            proc_write(DMEM_INPUT_BASE + (i << 2), input_mem[i]);
        for (i = 0; i < KER_WORDS; i = i + 1)
            proc_write(DMEM_WEIGHT_BASE + (i << 2), weight_mem[i]);

        $display("  [2/4] Writing layer configuration");
        proc_write(CFG_INPUT_H,     IMG_SIZE);
        proc_write(CFG_INPUT_W,     IMG_SIZE);
        proc_write(CFG_INPUT_C,     32'd1);
        proc_write(CFG_KERNEL_H,    KER_SIZE);
        proc_write(CFG_KERNEL_W,    KER_SIZE);
        proc_write(CFG_OUTPUT_C,    N_FILT);
        proc_write(CFG_STRIDE,      32'd1);
        proc_write(CFG_PADDING,     32'd0);
        proc_write(CFG_POOL_SIZE,   32'd0);
        proc_write(CFG_Q_FORMAT,    32'd0);     // Q32.0 (plain integer)
        proc_write(CFG_ACTIVATION,  ACTIVATION); // conv8_3 itself has no ReLU
        proc_write(CFG_INPUT_BASE,  DMEM_INPUT_BASE);
        proc_write(CFG_WEIGHT_BASE, DMEM_WEIGHT_BASE);
        proc_write(CFG_OUTPUT_BASE, DMEM_OUTPUT_BASE);

        $display("  [3/4] Executing Conv2D");
        proc_write(CFG_LAYER_START, 32'd1);
        status = 32'd1;
        while (status[0]) begin
            proc_read(CFG_STATUS, status);
            #(CLK_PERIOD * 20);
        end
        proc_read(CFG_CYCLE_CNT, cycle_count);

        $display("  [4/4] Verifying %0d outputs against the golden file (tolerance +/-%0d, exact match also counted)",
                 OUT_TOTAL, ERR_LIMIT);
        err_count = 0;  exact_err = 0;  max_abs_err = 0;
        for (i = 0; i < OUT_TOTAL; i = i + 1) begin
            proc_read(DMEM_OUTPUT_BASE + (i << 2), computed);
            if (computed !== golden[i]) exact_err = exact_err + 1;
            diff = $signed(computed) - $signed(golden[i]);
            abs_err = (diff < 0) ? -diff : diff;
            if (abs_err > max_abs_err) max_abs_err = abs_err;
            if (abs_err > ERR_LIMIT) begin
                err_count = err_count + 1;
                if (err_count <= 16)
                    $display("    MISMATCH[%0d] (oh=%0d ow=%0d oc=%0d): computed=%0d expected=%0d",
                             i, i / (OUT_SIZE * N_FILT), (i / N_FILT) % OUT_SIZE, i % N_FILT,
                             $signed(computed), $signed(golden[i]));
            end
        end

        $display("");
`ifdef MNIST_CONV1
        $display("  ---------- RESULTS: MNIST conv1, bias omitted (BRAM-only) ----------");
`else
        $display("  ---------------- RESULTS: conv8_3 (BRAM-only) ----------------");
`endif
        $display("  Output elements checked : %0d / %0d", OUT_TOTAL, OUT_TOTAL);
        $display("  Matching                : %0d / %0d", OUT_TOTAL - err_count, OUT_TOTAL);
        $display("  Bit-exact matches       : %0d / %0d", OUT_TOTAL - exact_err, OUT_TOTAL);
        $display("  Errors (|diff| > %0d)    : %0d", ERR_LIMIT, err_count);
        $display("  Max absolute error      : %0d", max_abs_err);
        $display("  Coreless-V cycle count        : %0d cycles", cycle_count);
        $display("  Execution time @50MHz   : %0d ns", cycle_count * CLK_PERIOD);
        $display("  STATUS                  : %s", (err_count == 0 && exact_err == 0) ? "** PASS **" : "** FAIL **");
        $display("  ---------------------------------------------------------------");
        #(CLK_PERIOD * 10);
        $finish;
    end

    // Timeout watchdog
    initial begin
        #(CLK_PERIOD * 2_000_000);
        $display("ERROR: Simulation timeout after 2M cycles (FSM stuck?)");
        $finish;
    end

endmodule
