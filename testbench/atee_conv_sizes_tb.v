`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: atee_conv_sizes_tb
//
// NEW testbench (2026-11-11), derived from atee_conv8_3_tb.v (unchanged).
// Runs the LIVE controller (vl=8, multi-MAC, EARLY_CLEAR default, no ReLU) on
// the I2SRV32-V CONV2D 3x3 benchmarks at any image size, BRAM-only, no DMA.
// Sizes and their symbol addresses come from conv_params.txt; data from
// conv_input.hex / conv_weights.hex / conv_golden.hex / conv_theirs.hex
// (scripts/gen_conv_sizes.py, built from THEIR img.c / ker.c / expected_output.c).
//
// DMEM layout (one layout for every size; 512 KB DMEM = 0x100000..0x17FFFF):
//   input   0x100000  IMG*IMG*8 words (pixel replicated over the 8 banks)
//   weights 0x120000  144 words, OC-innermost
//   output  0x121000  OH*OW*16 words, OC-innermost
// Cycle count = tensor_config_regs CYCLE_COUNT (cycles with layer_busy = 1).
//////////////////////////////////////////////////////////////////////////////////

module atee_conv_sizes_tb;

    parameter CLK_PERIOD = 20;       // 50 MHz
    parameter MAX_IN     = 32768;    // 64*64*8
    parameter MAX_OUT    = 61504;    // 62*62*16
    parameter KER_WORDS  = 144;

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

    localparam DMEM_INPUT_BASE  = 32'h0010_0000;
    localparam DMEM_WEIGHT_BASE = 32'h0012_0000;
    localparam DMEM_OUTPUT_BASE = 32'h0012_1000;
    localparam DMEM_END         = 32'h0018_0000;   // 512 KB DMEM

    reg [31:0] input_mem  [0:MAX_IN-1];
    reg [31:0] weight_mem [0:KER_WORDS-1];
    reg [31:0] golden     [0:MAX_OUT-1];
    reg [31:0] theirs     [0:MAX_OUT-1];

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

    integer i, fd, rc;
    integer img_size, ker_size, n_filt, out_size, in_words, n_out, distinct;
    reg [31:0] their_y, their_exp, their_err;
    integer exact_g, exact_t, maxd_g, maxd_t, ad;
    integer bytes_in, bytes_w, bytes_out;
    reg [31:0] status, cycle_count, computed;
    reg signed [31:0] diff;

    initial begin
        fd = $fopen("conv_params.txt", "r");
        rc = $fscanf(fd, "%d\n%d\n%d\n%d\n%d\n%d\n%h\n%h\n%h\n%d\n",
                     img_size, ker_size, n_filt, out_size, in_words, n_out,
                     their_y, their_exp, their_err, distinct);
        $fclose(fd);
        $readmemh("conv_input.hex",   input_mem, 0, in_words - 1);
        $readmemh("conv_weights.hex", weight_mem);
        $readmemh("conv_golden.hex",  golden, 0, n_out - 1);
        if (!distinct) $readmemh("conv_theirs.hex", theirs, 0, n_out - 1);

        bytes_in  = in_words * 4;
        bytes_w   = KER_WORDS * 4;
        bytes_out = n_out * 4;

        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        reset = 1'b1;
        #(CLK_PERIOD * 20);
        reset = 1'b0;
        #(CLK_PERIOD * 5);

        $display("");
        $display("================================================================");
        $display("  CONV2D 3x3 at %0dx%0d (their conv%0d_3 data%s), BRAM-only (no DMA)",
                 img_size, img_size, img_size, distinct ? ", DISTINCT mixed-sign weights" : "");
        $display("  %0d filters, %0d outputs (%0dx%0dx%0d); live vl=8 controller, EARLY_CLEAR default, no ReLU",
                 n_filt, n_out, out_size, out_size, n_filt);
        $display("  DMEM used: input %0d B + weights %0d B + output %0d B = %0d B of 524288 B",
                 bytes_in, bytes_w, bytes_out, bytes_in + bytes_w + bytes_out);
        $display("================================================================");
        if (DMEM_INPUT_BASE + bytes_in > DMEM_WEIGHT_BASE || DMEM_OUTPUT_BASE + bytes_out > DMEM_END) begin
            $display("  DOES NOT FIT in this layout: input end 0x%08h, output end 0x%08h", DMEM_INPUT_BASE + bytes_in, DMEM_OUTPUT_BASE + bytes_out);
            $finish;
        end

        for (i = 0; i < in_words; i = i + 1)
            proc_write(DMEM_INPUT_BASE + (i << 2), input_mem[i]);
        for (i = 0; i < KER_WORDS; i = i + 1)
            proc_write(DMEM_WEIGHT_BASE + (i << 2), weight_mem[i]);

        proc_write(CFG_INPUT_H,     img_size);
        proc_write(CFG_INPUT_W,     img_size);
        proc_write(CFG_INPUT_C,     32'd1);
        proc_write(CFG_KERNEL_H,    ker_size);
        proc_write(CFG_KERNEL_W,    ker_size);
        proc_write(CFG_OUTPUT_C,    n_filt);
        proc_write(CFG_STRIDE,      32'd1);
        proc_write(CFG_PADDING,     32'd0);
        proc_write(CFG_POOL_SIZE,   32'd0);
        proc_write(CFG_Q_FORMAT,    32'd0);
        proc_write(CFG_ACTIVATION,  32'd0);
        proc_write(CFG_INPUT_BASE,  DMEM_INPUT_BASE);
        proc_write(CFG_WEIGHT_BASE, DMEM_WEIGHT_BASE);
        proc_write(CFG_OUTPUT_BASE, DMEM_OUTPUT_BASE);

        proc_write(CFG_LAYER_START, 32'd1);
        status = 32'd1;
        while (status[0]) begin
            proc_read(CFG_STATUS, status);
            #(CLK_PERIOD * 20);
        end
        proc_read(CFG_CYCLE_CNT, cycle_count);

        exact_g = 0;  exact_t = 0;  maxd_g = 0;  maxd_t = 0;
        for (i = 0; i < n_out; i = i + 1) begin
            proc_read(DMEM_OUTPUT_BASE + (i << 2), computed);
            if (computed === golden[i]) exact_g = exact_g + 1;
            diff = $signed(computed) - $signed(golden[i]);
            ad = (diff < 0) ? -diff : diff;
            if (ad > maxd_g) maxd_g = ad;
            if (!distinct) begin
                if (computed === theirs[i]) exact_t = exact_t + 1;
                diff = $signed(computed) - $signed(theirs[i]);
                ad = (diff < 0) ? -diff : diff;
                if (ad > maxd_t) maxd_t = ad;
            end
        end

        $display("  ---------------- RESULTS ----------------");
        $display("  layer-busy cycles               : %0d", cycle_count);
        $display("  bit-exact vs Python reference   : %0d / %0d (max |diff| %0d)", exact_g, n_out, maxd_g);
        if (!distinct)
            $display("  bit-exact vs THEIR expected     : %0d / %0d (max |diff| %0d)", exact_t, n_out, maxd_t);
        $display("  STATUS                          : %s",
                 (exact_g == n_out && (distinct || exact_t == n_out)) ? "** PASS **" : "** FAIL **");
        $display("  -----------------------------------------");
        #(CLK_PERIOD * 10);
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 5_000_000);
        $display("ERROR: Simulation timeout after 5M cycles");
        $finish;
    end

endmodule
