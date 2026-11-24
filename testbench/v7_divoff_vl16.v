// NEW (2026-11-14). Second top-level module for the RTL-SAIF power method:
// sets ENABLE_DIV = 0 on the vl=16 design inside testbench/atee_conv_vl16_tb.v
// (unchanged) so the RTL matches the Virtex-7 Run 1 build (ENABLE_DIV=0).
// Elaborate together with the testbench: xelab ... atee_conv_vl16_tb v7_divoff_vl16
module v7_divoff_vl16;
    defparam atee_conv_vl16_tb.dut.ENABLE_DIV = 0;
endmodule
