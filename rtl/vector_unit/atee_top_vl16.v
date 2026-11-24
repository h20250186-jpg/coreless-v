`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: atee_top_vl16
// NEW top (2026-11-11): a copy of atee_top.v (unchanged) that instantiates
// hbm_lite_controller_vl16 (vl=16, all 16 output channels per pass) instead of
// the live vl=8 controller, and exports its cfg_error flag.
// Description: Top-level wrapper for the Autonomous Tensor Execution Engine.
//              Integrates config registers, HBM-Lite controller and the
//              existing v_wrapper (vector execution unit). BRAM-only: there
//              is no DMA engine and no DRAM port; DMEM is loaded through the
//              proc interface (or $readmemh in simulation).
//
//              Multiplexes v_wrapper control signals between:
//                - HBM-Lite controller (during autonomous CNN execution)
//                - Scalar core passthrough (for legacy vector ops / debug)
//
//              Multiplexes DMEM proc interface between:
//                - Scalar core (during CPU-driven memory access)
//                - HBM-Lite controller (during compute address generation)
//
// Port interface matches original v_wrapper — drop-in replacement in
// IF_ID_EX.v instantiation.
//////////////////////////////////////////////////////////////////////////////////

module atee_top_vl16 #(
    parameter ENABLE_DIV = 1            // 1: dividers present, 0: divider hardware removed
) (
    input  wire        clk,
    input  wire        reset,

    // --- Scalar core interface (same as v_wrapper) ---
    input  wire [8:0]  vl,
    input  wire [1:0]  vcsr_quant,
    input  wire        I_clear,
    input  wire [2:0]  I_id,
    output wire        ALU_mon,
    output wire        stall,
    output wire        DONE,

    // Processor memory interface
    input  wire [31:0] proc_addr,
    input  wire [31:0] proc_din,
    output wire [31:0] proc_dout,
    input  wire        proc_we,

    // Scalar register file interface
    output wire [4:0]  XRF_ADDR,
    output wire [31:0] XRF_DATAWR,
    output wire        XRF_WE,

    // Vector instruction signals from scalar decode
    input  wire        I_start,
    input  wire [4:0]  I_vs1,
    input  wire [4:0]  I_vs2,
    input  wire [4:0]  I_vd,
    input  wire [31:0] I_RS1,
    input  wire [31:0] I_RS2,
    input  wire [4:0]  I_uimm5,
    input  wire [7:0]  I_funct,
    input  wire [1:0]  I_permute,
    input  wire        I_mask_en,
    input  wire [1:0]  I_ALUSrc,
    input  wire        I_dmr,
    input  wire        I_dmw,
    input  wire        I_reg_we,
    input  wire        I_mem_reg,
    input  wire        I_Xout,
    input  wire [1:0]  I_mode_lsu,

    // vl=16 controller: layer refused (outside its limits)
    output wire        cfg_error
);

    // =========================================================================
    // Internal wires: Config registers <-> HBM-Lite controller
    // =========================================================================
    wire [31:0] cfg_input_h, cfg_input_w, cfg_input_c;
    wire [31:0] cfg_kernel_h, cfg_kernel_w, cfg_output_c;
    wire [31:0] cfg_stride, cfg_padding, cfg_pool_size;
    wire [1:0]  cfg_q_format;
    wire [31:0] cfg_activation;
    wire [31:0] cfg_input_base, cfg_weight_base, cfg_output_base;
    wire        cfg_layer_start, cfg_layer_busy, cfg_layer_done;
    wire [31:0] cfg_cycle_count;

    // DMA config registers still exist in tensor_config_regs but drive nothing:
    // the DMA engine was removed, so busy/done are tied off.
    wire [31:0] cfg_dma_src, cfg_dma_dst, cfg_dma_len;
    wire        cfg_dma_start;
    wire        cfg_dma_busy = 1'b0;
    wire        cfg_dma_done = 1'b0;

    // =========================================================================
    // Internal wires: HBM-Lite controller -> v_wrapper mux
    // =========================================================================
    wire        hbm_vec_start;
    wire [2:0]  hbm_vec_id;
    wire [8:0]  hbm_vec_vl;
    wire [1:0]  hbm_vec_quant;
    wire        hbm_vec_clear;
    wire [4:0]  hbm_vec_vs1, hbm_vec_vs2, hbm_vec_vd;
    wire [31:0] hbm_vec_RS1, hbm_vec_RS2;
    wire [4:0]  hbm_vec_uimm5;
    wire [7:0]  hbm_vec_funct;
    wire [1:0]  hbm_vec_permute;
    wire        hbm_vec_mask_en;
    wire [1:0]  hbm_vec_ALUSrc;
    wire        hbm_vec_dmr, hbm_vec_dmw;
    wire        hbm_vec_reg_we, hbm_vec_mem_reg;
    wire        hbm_vec_Xout;
    wire [1:0]  hbm_vec_mode_lsu;
    wire [31:0] hbm_proc_addr, hbm_proc_din;
    wire        hbm_proc_we;

    // v_wrapper status
    wire        vw_stall, vw_done, vw_alu_mon;
    wire [31:0] vw_proc_dout;
    wire [4:0]  vw_xrf_addr;
    wire [31:0] vw_xrf_datawr;
    wire        vw_xrf_we;

    // =========================================================================
    // Config register address detection
    // Config regs at 0x0020_0000 - 0x0020_00FF
    // =========================================================================
    wire is_cfg_addr = (proc_addr[31:8] == 24'h002000);
    wire cfg_we      = proc_we && is_cfg_addr;

    // =========================================================================
    // Mode select: HBM-Lite has control when layer is busy
    // =========================================================================
    wire atee_mode = cfg_layer_busy;

    // =========================================================================
    // Multiplexed v_wrapper inputs
    // =========================================================================
    wire        mux_start    = atee_mode ? hbm_vec_start    : I_start;
    wire [2:0]  mux_id       = atee_mode ? hbm_vec_id       : I_id;
    wire [8:0]  mux_vl       = atee_mode ? hbm_vec_vl       : vl;
    wire [1:0]  mux_quant    = atee_mode ? hbm_vec_quant    : vcsr_quant;
    wire        mux_clear    = atee_mode ? hbm_vec_clear    : I_clear;
    wire [4:0]  mux_vs1      = atee_mode ? hbm_vec_vs1      : I_vs1;
    wire [4:0]  mux_vs2      = atee_mode ? hbm_vec_vs2      : I_vs2;
    wire [4:0]  mux_vd       = atee_mode ? hbm_vec_vd       : I_vd;
    wire [31:0] mux_RS1      = atee_mode ? hbm_vec_RS1      : I_RS1;
    wire [31:0] mux_RS2      = atee_mode ? hbm_vec_RS2      : I_RS2;
    wire [4:0]  mux_uimm5    = atee_mode ? hbm_vec_uimm5    : I_uimm5;
    wire [7:0]  mux_funct    = atee_mode ? hbm_vec_funct    : I_funct;
    wire [1:0]  mux_permute  = atee_mode ? hbm_vec_permute  : I_permute;
    wire        mux_mask_en  = atee_mode ? hbm_vec_mask_en  : I_mask_en;
    wire [1:0]  mux_ALUSrc   = atee_mode ? hbm_vec_ALUSrc   : I_ALUSrc;
    wire        mux_dmr      = atee_mode ? hbm_vec_dmr      : I_dmr;
    wire        mux_dmw      = atee_mode ? hbm_vec_dmw      : I_dmw;
    wire        mux_reg_we   = atee_mode ? hbm_vec_reg_we   : I_reg_we;
    wire        mux_mem_reg  = atee_mode ? hbm_vec_mem_reg  : I_mem_reg;
    wire        mux_Xout     = atee_mode ? hbm_vec_Xout     : I_Xout;
    wire [1:0]  mux_mode_lsu = atee_mode ? hbm_vec_mode_lsu : I_mode_lsu;

    // =========================================================================
    // Multiplexed proc interface (priority: HBM-Lite > Scalar)
    // =========================================================================
    wire [31:0] mux_proc_addr = atee_mode    ? hbm_proc_addr  :
                                               proc_addr;
    wire [31:0] mux_proc_din  = atee_mode    ? hbm_proc_din   :
                                               proc_din;
    wire        mux_proc_we   = atee_mode    ? hbm_proc_we    :
                                (proc_we && !is_cfg_addr);

    // =========================================================================
    // Stall output: stall scalar core during ATEE execution
    // =========================================================================
    assign stall    = vw_stall || (atee_mode && I_start);
    assign DONE     = vw_done && !atee_mode;
    assign ALU_mon  = vw_alu_mon;

    // Config register read: when scalar reads from cfg address range
    wire [31:0] cfg_rdata_out;
    assign proc_dout = is_cfg_addr ? cfg_rdata_out : vw_proc_dout;

    // XRF passthrough
    assign XRF_ADDR   = vw_xrf_addr;
    assign XRF_DATAWR = vw_xrf_datawr;
    assign XRF_WE     = vw_xrf_we;

    // =========================================================================
    // Submodule: tensor_config_regs
    // =========================================================================
    tensor_config_regs u_config (
        .clk          (clk),
        .reset        (reset),
        .cfg_addr     (proc_addr),
        .cfg_wdata    (proc_din),
        .cfg_we       (cfg_we),
        .cfg_rdata    (cfg_rdata_out),
        .input_h      (cfg_input_h),
        .input_w      (cfg_input_w),
        .input_c      (cfg_input_c),
        .kernel_h     (cfg_kernel_h),
        .kernel_w     (cfg_kernel_w),
        .output_c     (cfg_output_c),
        .stride       (cfg_stride),
        .padding      (cfg_padding),
        .pool_size    (cfg_pool_size),
        .q_format     (cfg_q_format),
        .activation   (cfg_activation),
        .input_base   (cfg_input_base),
        .weight_base  (cfg_weight_base),
        .output_base  (cfg_output_base),
        .layer_start  (cfg_layer_start),
        .layer_busy   (cfg_layer_busy),
        .layer_done   (cfg_layer_done),
        .dma_src_addr (cfg_dma_src),
        .dma_dst_addr (cfg_dma_dst),
        .dma_length   (cfg_dma_len),
        .dma_start    (cfg_dma_start),
        .dma_busy     (cfg_dma_busy),
        .dma_done     (cfg_dma_done),
        .cycle_count  (cfg_cycle_count)
    );

    // =========================================================================
    // Submodule: hbm_lite_controller
    // =========================================================================
    hbm_lite_controller_vl16 u_hbm_lite (
        .clk          (clk),
        .reset        (reset),
        .input_h      (cfg_input_h),
        .input_w      (cfg_input_w),
        .input_c      (cfg_input_c),
        .kernel_h     (cfg_kernel_h),
        .kernel_w     (cfg_kernel_w),
        .output_c     (cfg_output_c),
        .stride       (cfg_stride),
        .padding      (cfg_padding),
        .pool_size    (cfg_pool_size),
        .q_format     (cfg_q_format),
        .activation   (cfg_activation),
        .input_base   (cfg_input_base),
        .weight_base  (cfg_weight_base),
        .output_base  (cfg_output_base),
        .layer_start  (cfg_layer_start),
        .layer_busy   (cfg_layer_busy),
        .layer_done   (cfg_layer_done),
        .cfg_error    (cfg_error),
        .vec_start    (hbm_vec_start),
        .vec_id       (hbm_vec_id),
        .vec_vl       (hbm_vec_vl),
        .vec_quant    (hbm_vec_quant),
        .vec_clear    (hbm_vec_clear),
        .vec_vs1      (hbm_vec_vs1),
        .vec_vs2      (hbm_vec_vs2),
        .vec_vd       (hbm_vec_vd),
        .vec_RS1      (hbm_vec_RS1),
        .vec_RS2      (hbm_vec_RS2),
        .vec_uimm5    (hbm_vec_uimm5),
        .vec_funct    (hbm_vec_funct),
        .vec_permute  (hbm_vec_permute),
        .vec_mask_en  (hbm_vec_mask_en),
        .vec_ALUSrc   (hbm_vec_ALUSrc),
        .vec_dmr      (hbm_vec_dmr),
        .vec_dmw      (hbm_vec_dmw),
        .vec_reg_we   (hbm_vec_reg_we),
        .vec_mem_reg  (hbm_vec_mem_reg),
        .vec_Xout     (hbm_vec_Xout),
        .vec_mode_lsu (hbm_vec_mode_lsu),
        .vec_stall    (vw_stall),
        .vec_done     (vw_done),
        .proc_addr    (hbm_proc_addr),
        .proc_din     (hbm_proc_din),
        .proc_we      (hbm_proc_we),
        .proc_dout    (vw_proc_dout)
    );

    // =========================================================================
    // Submodule: v_wrapper (existing vector execution unit — unchanged)
    // =========================================================================
    v_wrapper #(.ENABLE_DIV(ENABLE_DIV)) u_vec_unit (
        .clk          (clk),
        .reset        (reset),
        .vl           (mux_vl),
        .vcsr_quant   (mux_quant),
        .I_clear      (mux_clear),
        .I_id         (mux_id),
        .ALU_mon      (vw_alu_mon),
        .stall        (vw_stall),
        .DONE         (vw_done),
        .proc_addr    (mux_proc_addr),
        .proc_din     (mux_proc_din),
        .proc_dout    (vw_proc_dout),
        .proc_we      (mux_proc_we),
        .XRF_ADDR     (vw_xrf_addr),
        .XRF_DATAWR   (vw_xrf_datawr),
        .XRF_WE       (vw_xrf_we),
        .I_start      (mux_start),
        .I_vs1        (mux_vs1),
        .I_vs2        (mux_vs2),
        .I_vd         (mux_vd),
        .I_RS1        (mux_RS1),
        .I_RS2        (mux_RS2),
        .I_uimm5      (mux_uimm5),
        .I_funct      (mux_funct),
        .I_permute    (mux_permute),
        .I_mask_en    (mux_mask_en),
        .I_ALUSrc     (mux_ALUSrc),
        .I_dmr        (mux_dmr),
        .I_dmw        (mux_dmw),
        .I_reg_we     (mux_reg_we),
        .I_mem_reg    (mux_mem_reg),
        .I_Xout       (mux_Xout),
        .I_mode_lsu   (mux_mode_lsu)
    );

endmodule
