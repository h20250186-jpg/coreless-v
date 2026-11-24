`timescale 1ns / 1ps
// SENSITIVITY-TEST stand-ins for xbip_dsp48_macro_1 / _2 (not shipped by the
// I2SRV32-V repository). Same ports as xbip_dsp48_macro_missing.v, but every
// output is tied to 0: a deliberately DIFFERENT assumed function, used only
// to check whether the conv8_3 cycle count depends on what the stand-ins do.
module xbip_dsp48_macro_1 (
    input  wire               CLK,
    input  wire signed [17:0] A,
    input  wire signed [17:0] B,
    input  wire signed [47:0] C,
    output wire signed [47:0] P
);
    assign P = 48'sd0;
endmodule

module xbip_dsp48_macro_2 (
    input  wire               CLK,
    input  wire signed [17:0] A,
    input  wire signed [17:0] B,
    input  wire signed [47:0] C,
    input  wire signed [17:0] D,
    output wire signed [47:0] P
);
    assign P = 48'sd0;
endmodule
