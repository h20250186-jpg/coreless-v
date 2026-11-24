`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: tensor_config_regs
// Description: Memory-mapped configuration register bank for ATEE (Autonomous
//              Tensor Execution Engine). Scalar core writes CNN layer parameters
//              here via store instructions. HBM-Lite controller reads them to
//              drive autonomous convolution.
//
// Address Map (base = 0x0020_0000, offset in bytes):
//   0x00  REG_INPUT_H        - Input feature map height
//   0x04  REG_INPUT_W        - Input feature map width
//   0x08  REG_INPUT_C        - Input channels
//   0x0C  REG_KERNEL_H       - Kernel height
//   0x10  REG_KERNEL_W       - Kernel width
//   0x14  REG_OUTPUT_C       - Output channels (number of filters)
//   0x18  REG_STRIDE         - Convolution stride
//   0x1C  REG_PADDING        - Zero-padding amount
//   0x20  REG_POOL_SIZE      - Pooling window (0=no pooling, 2=2x2 max pool)
//   0x24  REG_Q_FORMAT       - Quantization: 00=Q32.0, 01=Q24.8, 10=Q16.16, 11=Q8.24
//   0x28  REG_ACTIVATION     - 0=none, 1=ReLU
//   0x2C  REG_INPUT_BASE     - DMEM base address for input data
//   0x30  REG_WEIGHT_BASE    - DMEM base address for weight data
//   0x34  REG_OUTPUT_BASE    - DMEM base address for output data
//   0x38  REG_LAYER_START    - Write 1 to start layer execution (auto-clears)
//   0x3C  REG_LAYER_STATUS   - Read-only: bit0=busy, bit1=done
//   0x40  REG_CYCLE_COUNT    - Read-only: cycle counter for benchmarking
//   0x44  REG_DMA_SRC_ADDR   - DMA source address in DRAM
//   0x48  REG_DMA_DST_ADDR   - DMA destination address in DMEM
//   0x4C  REG_DMA_LENGTH     - DMA transfer length (words)
//   0x50  REG_DMA_START      - Write 1 to start DMA (auto-clears)
//   0x54  REG_DMA_STATUS     - Read-only: bit0=busy, bit1=done
//////////////////////////////////////////////////////////////////////////////////

module tensor_config_regs (
    input  wire        clk,
    input  wire        reset,

    // Scalar core write interface (memory-mapped store)
    input  wire [31:0] cfg_addr,       // Full 32-bit address from scalar core
    input  wire [31:0] cfg_wdata,      // Write data
    input  wire        cfg_we,         // Write enable
    output reg  [31:0] cfg_rdata,      // Read data

    // Configuration outputs to HBM-Lite controller
    output wire [31:0] input_h,
    output wire [31:0] input_w,
    output wire [31:0] input_c,
    output wire [31:0] kernel_h,
    output wire [31:0] kernel_w,
    output wire [31:0] output_c,
    output wire [31:0] stride,
    output wire [31:0] padding,
    output wire [31:0] pool_size,
    output wire [1:0]  q_format,
    output wire [31:0] activation,
    output wire [31:0] input_base,
    output wire [31:0] weight_base,
    output wire [31:0] output_base,

    // Layer control handshake
    output reg         layer_start,     // Pulse: triggers HBM-Lite controller
    input  wire        layer_busy,      // From HBM-Lite: currently executing
    input  wire        layer_done,      // From HBM-Lite: execution complete

    // DMA control handshake
    output wire [31:0] dma_src_addr,
    output wire [31:0] dma_dst_addr,
    output wire [31:0] dma_length,
    output reg         dma_start,       // Pulse: triggers DMA controller
    input  wire        dma_busy,
    input  wire        dma_done,

    // Cycle counter (active during layer execution)
    output wire [31:0] cycle_count
);

    // -------------------------------------------------------------------------
    // Register storage
    // -------------------------------------------------------------------------
    reg [31:0] regs [0:21];   // 22 registers total

    // Address offset extraction: cfg_addr[7:2] gives word index (6 bits = 64 words)
    wire [5:0] reg_idx = cfg_addr[7:2];

    // -------------------------------------------------------------------------
    // Cycle counter
    // -------------------------------------------------------------------------
    reg [31:0] cycle_cnt;
    always @(posedge clk) begin
        if (reset)
            cycle_cnt <= 32'd0;
        else if (layer_start)
            cycle_cnt <= 32'd0;
        else if (layer_busy)
            cycle_cnt <= cycle_cnt + 32'd1;
    end

    // -------------------------------------------------------------------------
    // Register write logic
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 22; i = i + 1)
                regs[i] <= 32'd0;
            layer_start <= 1'b0;
            dma_start   <= 1'b0;
        end else begin
            // Auto-clear start pulses
            layer_start <= 1'b0;
            dma_start   <= 1'b0;

            if (cfg_we) begin
                case (reg_idx)
                    6'd0:  regs[0]  <= cfg_wdata;  // INPUT_H
                    6'd1:  regs[1]  <= cfg_wdata;  // INPUT_W
                    6'd2:  regs[2]  <= cfg_wdata;  // INPUT_C
                    6'd3:  regs[3]  <= cfg_wdata;  // KERNEL_H
                    6'd4:  regs[4]  <= cfg_wdata;  // KERNEL_W
                    6'd5:  regs[5]  <= cfg_wdata;  // OUTPUT_C
                    6'd6:  regs[6]  <= cfg_wdata;  // STRIDE
                    6'd7:  regs[7]  <= cfg_wdata;  // PADDING
                    6'd8:  regs[8]  <= cfg_wdata;  // POOL_SIZE
                    6'd9:  regs[9]  <= cfg_wdata;  // Q_FORMAT
                    6'd10: regs[10] <= cfg_wdata;  // ACTIVATION
                    6'd11: regs[11] <= cfg_wdata;  // INPUT_BASE
                    6'd12: regs[12] <= cfg_wdata;  // WEIGHT_BASE
                    6'd13: regs[13] <= cfg_wdata;  // OUTPUT_BASE
                    6'd14: layer_start <= cfg_wdata[0]; // LAYER_START (pulse)
                    // 6'd15: read-only LAYER_STATUS
                    // 6'd16: read-only CYCLE_COUNT
                    6'd17: regs[17] <= cfg_wdata;  // DMA_SRC_ADDR
                    6'd18: regs[18] <= cfg_wdata;  // DMA_DST_ADDR
                    6'd19: regs[19] <= cfg_wdata;  // DMA_LENGTH
                    6'd20: dma_start <= cfg_wdata[0]; // DMA_START (pulse)
                    // 6'd21: read-only DMA_STATUS
                    default: ; // ignore writes to undefined addresses
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Register read logic (combinational)
    // -------------------------------------------------------------------------
    always @(*) begin
        case (reg_idx)
            6'd0:  cfg_rdata = regs[0];
            6'd1:  cfg_rdata = regs[1];
            6'd2:  cfg_rdata = regs[2];
            6'd3:  cfg_rdata = regs[3];
            6'd4:  cfg_rdata = regs[4];
            6'd5:  cfg_rdata = regs[5];
            6'd6:  cfg_rdata = regs[6];
            6'd7:  cfg_rdata = regs[7];
            6'd8:  cfg_rdata = regs[8];
            6'd9:  cfg_rdata = regs[9];
            6'd10: cfg_rdata = regs[10];
            6'd11: cfg_rdata = regs[11];
            6'd12: cfg_rdata = regs[12];
            6'd13: cfg_rdata = regs[13];
            6'd14: cfg_rdata = 32'd0;                             // LAYER_START (write-only)
            6'd15: cfg_rdata = {30'd0, layer_done, layer_busy};   // LAYER_STATUS
            6'd16: cfg_rdata = cycle_cnt;                         // CYCLE_COUNT
            6'd17: cfg_rdata = regs[17];
            6'd18: cfg_rdata = regs[18];
            6'd19: cfg_rdata = regs[19];
            6'd20: cfg_rdata = 32'd0;                             // DMA_START (write-only)
            6'd21: cfg_rdata = {30'd0, dma_done, dma_busy};       // DMA_STATUS
            default: cfg_rdata = 32'd0;
        endcase
    end

    // -------------------------------------------------------------------------
    // Output assignments
    // -------------------------------------------------------------------------
    assign input_h      = regs[0];
    assign input_w      = regs[1];
    assign input_c      = regs[2];
    assign kernel_h     = regs[3];
    assign kernel_w     = regs[4];
    assign output_c     = regs[5];
    assign stride       = regs[6];
    assign padding      = regs[7];
    assign pool_size    = regs[8];
    assign q_format     = regs[9][1:0];
    assign activation   = regs[10];
    assign input_base   = regs[11];
    assign weight_base  = regs[12];
    assign output_base  = regs[13];

    assign dma_src_addr = regs[17];
    assign dma_dst_addr = regs[18];
    assign dma_length   = regs[19];

    assign cycle_count  = cycle_cnt;

endmodule
