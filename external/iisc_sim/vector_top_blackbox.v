`timescale 1ns / 1ps
// BLACK-BOX declaration of the I2SRV32-V vector unit (port list copied from
// rtl/vector_unit/vector_top.v). Used ONLY for the out-of-context synthesis of
// the scalar core alone, so that the vector unit's logic is not counted there
// and the scalar logic driving / reading it is not trimmed away.
(* black_box *)
module vector_top(
    input           clk,
    input           reset,
    input           Branch_Taken__EX_MEM,
    input           Branch_Taken__MEM_WB,
    input  [31:0]   Instruction__IF_ID,
    input  [31:0]   Instruction__ID_EX,
    input  [31:0]   rs1_data,
    input  [31:0]   rs2_data,
    input  [8:0]    vl,
    input  [8:0]    vcsr_quant,
    input           freeze_vector_ops,
    input           Data_Cache__Stall,
    input  [31:0]   proc_addr,
    input  [31:0]   proc_din,
    output [31:0]   proc_dout,
    input           proc_we,
    output          sv_vv,
    output          v_stall,
    output          freeze_x,
    output          freeze,
    output [1:0]    release_counter,
    output [4:0]    rs2_sel,
    output [4:0]    rs1_sel,
    output          ALU_monitor,
    output          vect_cxt_changed,
    output          vec_wr_XRF,
    output [4:0]    XRF_ADDR,
    output [31:0]   XRF_DATAWR,
    output          XRF_WE
    );
endmodule
