`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: ibuf_ram
// NEW (2026-11-17, scalar-operand variant). Controller-side input buffer
// (IBUF, docs/chunked_taps_design.md section 10.2): 4,096 x 32-bit simple
// dual-port RAM, one write port, one synchronous read port (data 1 cycle after
// the address). Holds the current layer's input, NOT replicated.
//////////////////////////////////////////////////////////////////////////////////

module ibuf_ram (
    input  wire        clk,
    input  wire        we,
    input  wire [11:0] wa,
    input  wire [31:0] wd,
    input  wire [11:0] ra,
    output reg  [31:0] q
);
    reg [31:0] mem [0:4095];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        q <= mem[ra];
    end
endmodule
