`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: atee_conv_vl16_tb
//
// NEW testbench (2026-11-11) for atee_top_vl16 (hbm_lite_controller_vl16:
// vl=16, all 16 output channels per pass). Derived from atee_conv_sizes_tb.v.
// BRAM-only, no DMA. Sizes from conv_params.txt; data from conv_input.hex
// (8x-replicated file: word p*8 is pixel p), conv_weights.hex, conv_golden.hex
// and, when present, conv_theirs.hex (see scripts/run_conv_vl16.ps1).
//
// xvlog defines:
//   RELU_ON      layer runs with ReLU; compared against max(golden, 0)
//   NEG_CONTROL  layer runs WITHOUT ReLU but is compared against max(golden, 0):
//                it must fail on exactly the outputs whose golden is negative
//   LIMIT_TEST   no layer data: three configurations outside the vl=16 limits
//                are started and must be refused (cfg_error = 1)
//
// DMEM layout (512 KB = 0x100000..0x17FFFF), regions back to back:
//   input   0x100000                IMG*IMG*16 words (pixel replicated 16x)
//   weights input end               144 words, OC-innermost
//   output  weights end             OH*OW*16 words, OC-innermost
//////////////////////////////////////////////////////////////////////////////////

module atee_conv_vl16_tb;

    parameter CLK_PERIOD = 20;
    parameter MAX_PIX    = 4096;     // 64*64
    parameter MAX_OUT    = 61504;    // 62*62*16
    parameter KER_WORDS  = 144;

`ifdef RELU_ON
    localparam ACTIVATION = 1;
`else
    localparam ACTIVATION = 0;
`endif

    reg clk, reset;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg  [31:0] proc_addr, proc_din;
    wire [31:0] proc_dout;
    reg         proc_we;
    wire        ALU_mon, stall_out, DONE_out, cfg_error;
    wire [4:0]  XRF_ADDR;
    wire [31:0] XRF_DATAWR;
    wire        XRF_WE;

    atee_top_vl16 dut (
        .clk(clk), .reset(reset),
        .vl(9'd8), .vcsr_quant(2'b00), .I_clear(1'b0), .I_id(3'd0),
        .ALU_mon(ALU_mon), .stall(stall_out), .DONE(DONE_out),
        .proc_addr(proc_addr), .proc_din(proc_din), .proc_dout(proc_dout), .proc_we(proc_we),
        .XRF_ADDR(XRF_ADDR), .XRF_DATAWR(XRF_DATAWR), .XRF_WE(XRF_WE),
        .I_start(1'b0), .I_vs1(5'd0), .I_vs2(5'd0), .I_vd(5'd0),
        .I_RS1(32'd0), .I_RS2(32'd0), .I_uimm5(5'd0), .I_funct(8'd0),
        .I_permute(2'd0), .I_mask_en(1'b0), .I_ALUSrc(2'b00),
        .I_dmr(1'b0), .I_dmw(1'b0), .I_reg_we(1'b0), .I_mem_reg(1'b0),
        .I_Xout(1'b0), .I_mode_lsu(2'b00),
        .cfg_error(cfg_error)
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

    localparam DMEM_BASE = 32'h0010_0000;
    localparam DMEM_END  = 32'h0018_0000;

    reg [31:0] input8     [0:MAX_PIX*8-1];
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

    integer i, e, fd, rc;
    integer img_size, ker_size, n_filt, out_size, in_words, n_out, distinct, has_theirs;
    reg [31:0] dummy_a, dummy_b, dummy_c;
    integer n_pix, bytes_in, bytes_w, bytes_out;
    reg [31:0] in_base, w_base, out_base;
    integer exact_g, exact_t, maxd_g, maxd_t, ad, n_neg, fail_neg, fail_nonneg;
    reg [31:0] status, cycle_count, computed, expect_v;
    reg signed [31:0] diff;

    task run_layer(input [31:0] ih, input [31:0] iw, input [31:0] ic, input [31:0] kh,
                   input [31:0] kw, input [31:0] oc, input [31:0] act);
    begin
        proc_write(CFG_INPUT_H,     ih);
        proc_write(CFG_INPUT_W,     iw);
        proc_write(CFG_INPUT_C,     ic);
        proc_write(CFG_KERNEL_H,    kh);
        proc_write(CFG_KERNEL_W,    kw);
        proc_write(CFG_OUTPUT_C,    oc);
        proc_write(CFG_STRIDE,      32'd1);
        proc_write(CFG_PADDING,     32'd0);
        proc_write(CFG_POOL_SIZE,   32'd0);
        proc_write(CFG_Q_FORMAT,    32'd0);
        proc_write(CFG_ACTIVATION,  act);
        proc_write(CFG_INPUT_BASE,  in_base);
        proc_write(CFG_WEIGHT_BASE, w_base);
        proc_write(CFG_OUTPUT_BASE, out_base);
        proc_write(CFG_LAYER_START, 32'd1);
        status = 32'd1;
        while (status[0]) begin
            proc_read(CFG_STATUS, status);
            #(CLK_PERIOD * 20);
        end
        proc_read(CFG_CYCLE_CNT, cycle_count);
    end
    endtask

    initial begin
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;
        reset = 1'b1;
        #(CLK_PERIOD * 20);
        reset = 1'b0;
        #(CLK_PERIOD * 5);

`ifdef LIMIT_TEST
        in_base = DMEM_BASE;  w_base = DMEM_BASE + 32'h4_0000;  out_base = DMEM_BASE + 32'h5_0000;
        $display("");
        $display("  LIMIT TEST (vl=16 controller): configurations outside the limits must be refused");
        run_layer(16, 16, 1, 5, 2, 16, 1);
        $display("    10 taps, ReLU on  (limit 9)        : cfg_error = %0d, layer-busy cycles %0d -> %s", cfg_error, cycle_count, cfg_error ? "REFUSED" : "ACCEPTED");
        run_layer(16, 16, 1, 4, 3, 16, 0);
        $display("    12 taps, ReLU off (limit 11)       : cfg_error = %0d, layer-busy cycles %0d -> %s", cfg_error, cycle_count, cfg_error ? "REFUSED" : "ACCEPTED");
        run_layer(16, 16, 1, 3, 3, 8, 0);
        $display("    9 taps, OUTPUT_C = 8 (not x16)     : cfg_error = %0d, layer-busy cycles %0d -> %s", cfg_error, cycle_count, cfg_error ? "REFUSED" : "ACCEPTED");
        run_layer(16, 16, 1, 3, 3, 24, 0);
        $display("    9 taps, OUTPUT_C = 24 (not x16)    : cfg_error = %0d, layer-busy cycles %0d -> %s", cfg_error, cycle_count, cfg_error ? "REFUSED" : "ACCEPTED");
        $finish;
`endif

        fd = $fopen("conv_params.txt", "r");
        rc = $fscanf(fd, "%d\n%d\n%d\n%d\n%d\n%d\n%h\n%h\n%h\n%d\n",
                     img_size, ker_size, n_filt, out_size, in_words, n_out, dummy_a, dummy_b, dummy_c, distinct);
        $fclose(fd);
        n_pix = img_size * img_size;
        $readmemh("conv_input.hex",   input8, 0, n_pix * 8 - 1);
        $readmemh("conv_weights.hex", weight_mem);
        $readmemh("conv_golden.hex",  golden, 0, n_out - 1);
        fd = $fopen("conv_theirs.hex", "r");
        has_theirs = (fd != 0);
        if (has_theirs) begin
            $fclose(fd);
            $readmemh("conv_theirs.hex", theirs, 0, n_out - 1);
        end

        bytes_in  = n_pix * 16 * 4;
        bytes_w   = KER_WORDS * 4;
        bytes_out = n_out * 4;
        in_base   = DMEM_BASE;
        w_base    = in_base + bytes_in;
        out_base  = w_base + bytes_w;

        $display("");
        $display("================================================================");
        $display("  vl=16 controller: CONV2D %0dx%0d, %0dx%0d kernel, %0d filters, %0d outputs%s",
                 img_size, img_size, ker_size, ker_size, n_filt, n_out, distinct ? " (DISTINCT mixed-sign weights)" : "");
`ifdef NEG_CONTROL
        $display("  NEGATIVE CONTROL: ReLU OFF, compared against max(golden, 0)");
`else
        $display("  ReLU %s; BRAM-only (no DMA); EARLY_CLEAR default", ACTIVATION ? "ON (compared against max(golden, 0))" : "off");
`endif
        $display("  DMEM used: input %0d B (16x replication) + weights %0d B + output %0d B = %0d B of 524288 B",
                 bytes_in, bytes_w, bytes_out, bytes_in + bytes_w + bytes_out);
        $display("================================================================");
        if (out_base + bytes_out > DMEM_END) begin
            $display("  DOES NOT FIT: output would end at 0x%08h (DMEM ends at 0x%08h); size skipped", out_base + bytes_out, DMEM_END);
            $finish;
        end

        for (i = 0; i < n_pix; i = i + 1)
            for (e = 0; e < 16; e = e + 1)
                proc_write(in_base + (((i << 4) + e) << 2), input8[i * 8]);
        for (i = 0; i < KER_WORDS; i = i + 1)
            proc_write(w_base + (i << 2), weight_mem[i]);

        run_layer(img_size, img_size, 1, ker_size, ker_size, n_filt, ACTIVATION);

        exact_g = 0;  exact_t = 0;  maxd_g = 0;  maxd_t = 0;
        n_neg = 0;  fail_neg = 0;  fail_nonneg = 0;
        for (i = 0; i < n_out; i = i + 1) begin
            proc_read(out_base + (i << 2), computed);
`ifdef RELU_ON
            expect_v = ($signed(golden[i]) < 0) ? 32'd0 : golden[i];
`elsif NEG_CONTROL
            expect_v = ($signed(golden[i]) < 0) ? 32'd0 : golden[i];
`else
            expect_v = golden[i];
`endif
            if ($signed(golden[i]) < 0) n_neg = n_neg + 1;
            if (computed === expect_v) exact_g = exact_g + 1;
            else if ($signed(golden[i]) < 0) fail_neg = fail_neg + 1;
            else fail_nonneg = fail_nonneg + 1;
            diff = $signed(computed) - $signed(expect_v);
            ad = (diff < 0) ? -diff : diff;
            if (ad > maxd_g) maxd_g = ad;
            if (has_theirs && !ACTIVATION) begin
                if (computed === theirs[i]) exact_t = exact_t + 1;
                diff = $signed(computed) - $signed(theirs[i]);
                ad = (diff < 0) ? -diff : diff;
                if (ad > maxd_t) maxd_t = ad;
            end
        end

        $display("  ---------------- RESULTS ----------------");
        $display("  cfg_error                       : %0d", cfg_error);
        $display("  layer-busy cycles               : %0d", cycle_count);
        $display("  bit-exact vs reference%s : %0d / %0d (max |diff| %0d)",
                 ACTIVATION ? " (ReLU'd) " : "          ", exact_g, n_out, maxd_g);
`ifdef NEG_CONTROL
        $display("  reference outputs < 0           : %0d", n_neg);
        $display("  mismatches on negative outputs  : %0d ; on non-negative outputs: %0d", fail_neg, fail_nonneg);
        $display("  NEGATIVE CONTROL                : %s",
                 (fail_neg == n_neg && fail_nonneg == 0 && n_neg > 0) ? "** fails on exactly the outputs that should clamp **" : "** UNEXPECTED **");
`else
        if (ACTIVATION) $display("  reference outputs < 0 (clamped) : %0d", n_neg);
        if (has_theirs && !ACTIVATION)
            $display("  bit-exact vs THEIR expected     : %0d / %0d (max |diff| %0d)", exact_t, n_out, maxd_t);
        $display("  STATUS                          : %s",
                 (!cfg_error && exact_g == n_out && (!has_theirs || ACTIVATION || exact_t == n_out)) ? "** PASS **" : "** FAIL **");
`endif
        $display("  -----------------------------------------");
        #(CLK_PERIOD * 10);
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 8_000_000);
        $display("ERROR: Simulation timeout after 8M cycles");
        $finish;
    end

endmodule
