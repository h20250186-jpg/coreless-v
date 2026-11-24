`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: outsize_div_tb
//
// Standalone check of outsize_div against the reference formula
//     out = (input + 2*padding - kernel) / stride + 1      (16-bit unsigned)
// written with the same operand widths as the expression it replaces in
// hbm_lite_controller. Height and width are checked on every operation with
// DIFFERENT operands, so both dividers are exercised.
//
//   A  structured layer shapes: input 1..64, padding 0..3, kernel 1..7,
//      stride 1..4 (includes kernel > input + 2*padding, which wraps)
//   B  exhaustive numerator 0..65535 for a list of strides (padding 0,
//      kernel 0 on the height channel; the width channel gets the complement)
//   C  random operands over the full 16-bit / 15-bit ranges, stride 1..65535
//   D  stride = 0: not supported; must finish in 16 cycles with out = 0
// Every operation also checks that exactly 16 cycles elapse between the start
// edge and `last`, and that busy drops afterwards.
//////////////////////////////////////////////////////////////////////////////////

module outsize_div_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg         reset, start;
    reg  [15:0] input_h, input_w, kernel_h, kernel_w, stride;
    reg  [14:0] padding;
    wire [15:0] out_h, out_w;
    wire        busy, last;

    outsize_div dut (
        .clk(clk), .reset(reset), .start(start),
        .input_h(input_h), .input_w(input_w), .padding(padding),
        .kernel_h(kernel_h), .kernel_w(kernel_w), .stride(stride),
        .out_h(out_h), .out_w(out_w), .busy(busy), .last(last)
    );

    // reference: same widths as the original controller expression
    function [15:0] ref_out(input [15:0] in, input [14:0] pad, input [15:0] k, input [15:0] s);
        ref_out = (in + {pad, 1'b0} - k) / s + 16'd1;
    endfunction

    integer ops, errs, cyc_errs, cyc;
    integer a_ops, b_ops, c_ops, d_ops;
    reg [15:0] eh, ew;

    task run(input [15:0] ih, input [15:0] iw, input [14:0] pd,
             input [15:0] kh, input [15:0] kw, input [15:0] st, input zero_stride);
    begin
        @(posedge clk);
        input_h <= ih;  input_w <= iw;  padding <= pd;
        kernel_h <= kh; kernel_w <= kw; stride <= st;
        start <= 1'b1;
        @(posedge clk);            // start sampled on this edge
        start <= 1'b0;
        cyc = 0;
        @(negedge clk);
        cyc = 1;
        while (!last && cyc < 40) begin
            @(negedge clk);
            cyc = cyc + 1;
        end
        if (cyc != 16) begin
            cyc_errs = cyc_errs + 1;
            if (cyc_errs <= 5) $display("  CYCLE ERROR: last seen in cycle %0d after start (expected 16)", cyc);
        end
        @(posedge clk);            // 16th iteration completes
        @(negedge clk);
        if (busy) begin
            cyc_errs = cyc_errs + 1;
            if (cyc_errs <= 5) $display("  BUSY ERROR: still busy after the 16th iteration");
        end
        if (zero_stride) begin
            eh = 16'd0;  ew = 16'd0;
        end else begin
            eh = ref_out(ih, pd, kh, st);
            ew = ref_out(iw, pd, kw, st);
        end
        ops = ops + 1;
        if (out_h !== eh || out_w !== ew) begin
            errs = errs + 1;
            if (errs <= 10)
                $display("  MISMATCH in=(%0d,%0d) pad=%0d k=(%0d,%0d) stride=%0d : got (%0d,%0d) expected (%0d,%0d)",
                         ih, iw, pd, kh, kw, st, out_h, out_w, eh, ew);
        end
    end
    endtask

    integer i, p, k, s, n, si;
    reg [15:0] slist [0:9];
    reg [15:0] rs;

    initial begin
        slist[0] = 16'd1;   slist[1] = 16'd2;   slist[2] = 16'd3;     slist[3] = 16'd4;
        slist[4] = 16'd5;   slist[5] = 16'd7;   slist[6] = 16'd8;     slist[7] = 16'd16;
        slist[8] = 16'd255; slist[9] = 16'd65535;
        ops = 0;  errs = 0;  cyc_errs = 0;
        reset = 1'b1;  start = 1'b0;
        input_h = 0; input_w = 0; padding = 0; kernel_h = 0; kernel_w = 0; stride = 1;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // A: structured layer shapes
        for (i = 1; i <= 64; i = i + 1)
            for (p = 0; p <= 3; p = p + 1)
                for (k = 1; k <= 7; k = k + 1)
                    for (s = 1; s <= 4; s = s + 1)
                        run(i, 65 - i, p, k, 8 - k, s, 1'b0);
        a_ops = ops;
        $display("A structured (input 1..64, padding 0..3, kernel 1..7, stride 1..4): %0d operations, %0d mismatches so far", a_ops, errs);

        // B: exhaustive numerator for selected strides
        for (si = 0; si < 10; si = si + 1) begin
            for (n = 0; n < 65536; n = n + 1)
                run(n, ~n, 15'd0, 16'd0, 16'd0, slist[si], 1'b0);
            $display("B exhaustive numerator 0..65535, stride %0d: done, %0d mismatches so far", slist[si], errs);
        end
        b_ops = ops - a_ops;

        // C: random, full ranges
        for (i = 0; i < 300000; i = i + 1) begin
            rs = $random;
            if (rs == 16'd0) rs = 16'd1;
            run($random, $random, $random, $random, $random, rs, 1'b0);
        end
        c_ops = ops - a_ops - b_ops;
        $display("C random full-range operands, stride 1..65535: %0d operations, %0d mismatches so far", c_ops, errs);

        // D: stride = 0
        for (i = 0; i < 16; i = i + 1)
            run($random, $random, $random, $random, $random, 16'd0, 1'b1);
        d_ops = ops - a_ops - b_ops - c_ops;
        $display("D stride = 0 (unsupported; expect out = 0 in 16 cycles): %0d operations, %0d mismatches so far", d_ops, errs);

        $display("");
        $display("outsize_div: %0d operations (A %0d, B %0d, C %0d, D %0d)", ops, a_ops, b_ops, c_ops, d_ops);
        $display("  value mismatches : %0d", errs);
        $display("  timing errors    : %0d   (16 cycles from start to last, busy low after)", cyc_errs);
        $display("  STATUS           : %s", (errs == 0 && cyc_errs == 0) ? "** PASS **" : "** FAIL **");
        $finish;
    end

endmodule
