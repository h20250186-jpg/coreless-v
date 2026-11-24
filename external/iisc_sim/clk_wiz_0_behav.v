`timescale 1ns / 1ps
// BEHAVIOURAL STAND-IN for the I2SRV32-V clk_wiz_0 IP (the IP container was
// generated with Vivado 2020.2 and cannot be regenerated in Vivado 2019.1).
// The IP is configured for a 200 MHz differential input, clk_out1 = 50 MHz and
// clk_out2 = 100 MHz. This model generates the two output clocks directly,
// with coincident rising edges, and ignores the input clock pins and reset.
module clk_wiz_0 (
    output reg clk_out1,
    output reg clk_out2,
    input      reset,
    input      clk_in1_p,
    input      clk_in1_n
);
    initial begin
        clk_out1 = 1'b0;
        clk_out2 = 1'b0;
    end
    always #5  clk_out2 = ~clk_out2;                 // 100 MHz
    always @(posedge clk_out2) clk_out1 = ~clk_out1; // 50 MHz
endmodule
