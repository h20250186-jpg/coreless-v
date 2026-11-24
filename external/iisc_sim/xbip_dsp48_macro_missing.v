`timescale 1ns / 1ps
// STAND-INS for two IP cores that the I2SRV32-V repository instantiates
// (rtl/EVA/EVA_update.v) but does NOT ship: there is no xbip_dsp48_macro_1 or
// xbip_dsp48_macro_2 container in "Source code/IP". Their real configuration
// (function, signedness, pipeline depth) is therefore unknown.
//
// They sit in the EVA replacement-ranking logic of the ITLB/TLB, i.e. they only
// influence WHICH translation entry is chosen for eviction. The functions below
// are ASSUMPTIONS made from the port lists and from xbip_dsp48_macro_0 (A*B,
// one M register); they have not been checked against the original IP.
//   xbip_dsp48_macro_1 : P = A*B + C         (ports A, B, C)
//   xbip_dsp48_macro_2 : P = (D + A)*B + C   (ports A, B, C, D)
module xbip_dsp48_macro_1 (
    input  wire               CLK,
    input  wire signed [17:0] A,
    input  wire signed [17:0] B,
    input  wire signed [47:0] C,
    output reg  signed [47:0] P
);
    always @(posedge CLK) P <= A * B + C;
endmodule

module xbip_dsp48_macro_2 (
    input  wire               CLK,
    input  wire signed [17:0] A,
    input  wire signed [17:0] B,
    input  wire signed [47:0] C,
    input  wire signed [17:0] D,
    output reg  signed [47:0] P
);
    always @(posedge CLK) P <= (D + A) * B + C;
endmodule
