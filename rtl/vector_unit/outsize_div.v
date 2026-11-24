`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: outsize_div
// Description: Output-size computation for hbm_lite_controller, once per layer:
//
//     out = (input + 2*padding - kernel) / stride + 1       (all 16-bit unsigned,
//                                                            wrapping like the
//                                                            Verilog expression)
//
// for height and width at the same time, with a restoring shift-subtract
// divider instead of a combinational '/'. One quotient bit per cycle.
//
// Timing: `start` is sampled on a clock edge; the 16 iterations run in the 16
// cycles that follow; `last` is high during the 16th of them. out_h / out_w
// are valid from the cycle after `last` until the next `start`.
//
// stride = 0 is not a supported configuration; it gives out = 0 after the same
// 16 cycles (quotient all ones, plus one), it does not hang.
//////////////////////////////////////////////////////////////////////////////////

module outsize_div (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [15:0] input_h,
    input  wire [15:0] input_w,
    input  wire [14:0] padding,
    input  wire [15:0] kernel_h,
    input  wire [15:0] kernel_w,
    input  wire [15:0] stride,
    output wire [15:0] out_h,
    output wire [15:0] out_w,
    output wire        busy,
    output wire        last
);

    reg [15:0] q_h, q_w;     // numerator on load, quotient when done
    reg [16:0] r_h, r_w;     // partial remainder
    reg [15:0] den;
    reg [4:0]  cnt;          // iterations left

    // shift the next numerator bit into the remainder, try to subtract
    wire [16:0] rs_h = {r_h[15:0], q_h[15]};
    wire [16:0] rs_w = {r_w[15:0], q_w[15]};
    wire        ge_h = (rs_h >= {1'b0, den});
    wire        ge_w = (rs_w >= {1'b0, den});

    always @(posedge clk) begin
        if (reset) begin
            q_h <= 16'd0;  q_w <= 16'd0;
            r_h <= 17'd0;  r_w <= 17'd0;
            den <= 16'd0;  cnt <= 5'd0;
        end else if (start) begin
            q_h <= input_h + {padding, 1'b0} - kernel_h;
            q_w <= input_w + {padding, 1'b0} - kernel_w;
            r_h <= 17'd0;  r_w <= 17'd0;
            den <= stride;
            cnt <= 5'd16;
        end else if (cnt != 5'd0) begin
            r_h <= ge_h ? rs_h - {1'b0, den} : rs_h;
            r_w <= ge_w ? rs_w - {1'b0, den} : rs_w;
            q_h <= {q_h[14:0], ge_h};
            q_w <= {q_w[14:0], ge_w};
            cnt <= cnt - 5'd1;
        end
    end

    assign busy  = (cnt != 5'd0);
    assign last  = (cnt == 5'd1);
    assign out_h = q_h + 16'd1;
    assign out_w = q_w + 16'd1;

endmodule
