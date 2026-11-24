`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: dma_controller
// Description: Hardware DMA engine for ATEE. Transfers data from external DRAM
//              (via Wishbone bus) to on-chip DMEM (via v_wrapper proc interface).
//              Operates autonomously once triggered — no CPU intervention needed.
//
// Features:
//   - Burst transfer from DRAM to DMEM
//   - Runs concurrently with HBM-Lite compute (double-buffer strategy)
//   - Yields to HBM-Lite when both request DMEM access
//
// Interface:
//   - Wishbone master port: reads from DRAM
//   - DMEM write port: proc_addr/proc_din/proc_we to v_wrapper
//////////////////////////////////////////////////////////////////////////////////

module dma_controller (
    input  wire        clk,
    input  wire        reset,

    // Control interface (from tensor_config_regs)
    input  wire [31:0] dma_src_addr,   // Source address in DRAM
    input  wire [31:0] dma_dst_addr,   // Destination address in DMEM
    input  wire [31:0] dma_length,     // Transfer length in 32-bit words
    input  wire        dma_start,      // Pulse to begin transfer
    output reg         dma_busy,
    output reg         dma_done,

    // Priority: HBM-Lite compute takes priority over DMA for DMEM access
    input  wire        compute_active, // From HBM-Lite: currently using DMEM

    // Wishbone master interface (to DRAM)
    output reg  [31:0] wb_adr_o,       // Address
    output reg  [31:0] wb_dat_o,       // Write data (unused for reads)
    input  wire [31:0] wb_dat_i,       // Read data from DRAM
    output reg         wb_we_o,        // Write enable (0 for reads)
    output reg  [3:0]  wb_sel_o,       // Byte select (all bytes)
    output reg         wb_stb_o,       // Strobe
    output reg         wb_cyc_o,       // Bus cycle
    input  wire        wb_ack_i,       // Acknowledge from DRAM

    // DMEM write port (to v_wrapper proc interface)
    output reg  [31:0] dmem_addr,      // DMEM destination address
    output reg  [31:0] dmem_din,       // Data to write
    output reg         dmem_we         // Write enable
);

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [2:0]
        DMA_IDLE       = 3'd0,
        DMA_REQUEST    = 3'd1,
        DMA_WAIT_ACK   = 3'd2,
        DMA_WRITE_DMEM = 3'd3,
        DMA_NEXT       = 3'd4,
        DMA_COMPLETE   = 3'd5;

    reg [2:0] state, next_state;

    // =========================================================================
    // Internal registers
    // =========================================================================
    reg [31:0] src_ptr;       // Current DRAM read address
    reg [31:0] dst_ptr;       // Current DMEM write address
    reg [31:0] words_left;    // Remaining words to transfer
    reg [31:0] read_data;     // Latched data from Wishbone read

    // =========================================================================
    // FSM: State register
    // =========================================================================
    always @(posedge clk) begin
        if (reset)
            state <= DMA_IDLE;
        else
            state <= next_state;
    end

    // =========================================================================
    // FSM: Datapath
    // =========================================================================
    always @(posedge clk) begin
        if (reset) begin
            dma_busy   <= 1'b0;
            dma_done   <= 1'b0;
            src_ptr    <= 32'd0;
            dst_ptr    <= 32'd0;
            words_left <= 32'd0;
            read_data  <= 32'd0;
            wb_adr_o   <= 32'd0;
            wb_dat_o   <= 32'd0;
            wb_we_o    <= 1'b0;
            wb_sel_o   <= 4'b0000;
            wb_stb_o   <= 1'b0;
            wb_cyc_o   <= 1'b0;
            dmem_addr  <= 32'd0;
            dmem_din   <= 32'd0;
            dmem_we    <= 1'b0;
        end else begin
            // Defaults
            dmem_we  <= 1'b0;
            dma_done <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                DMA_IDLE: begin
                    dma_busy <= 1'b0;
                    wb_stb_o <= 1'b0;
                    wb_cyc_o <= 1'b0;
                    if (dma_start) begin
                        dma_busy   <= 1'b1;
                        dma_done   <= 1'b0;
                        src_ptr    <= dma_src_addr;
                        dst_ptr    <= dma_dst_addr;
                        words_left <= dma_length;
                    end
                end

                // ---------------------------------------------------------
                // Initiate Wishbone read from DRAM
                DMA_REQUEST: begin
                    wb_adr_o <= src_ptr;
                    wb_we_o  <= 1'b0;        // Read
                    wb_sel_o <= 4'b1111;     // All bytes
                    wb_stb_o <= 1'b1;
                    wb_cyc_o <= 1'b1;
                end

                // ---------------------------------------------------------
                // Wait for DRAM acknowledge
                DMA_WAIT_ACK: begin
                    if (wb_ack_i) begin
                        read_data <= wb_dat_i;
                        wb_stb_o  <= 1'b0;
                        wb_cyc_o  <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                // Write fetched word to DMEM (yield if compute is active)
                DMA_WRITE_DMEM: begin
                    if (!compute_active) begin
                        dmem_addr <= dst_ptr;
                        dmem_din  <= read_data;
                        dmem_we   <= 1'b1;
                    end
                    // If compute_active, stay in this state (yield)
                end

                // ---------------------------------------------------------
                // Advance pointers
                DMA_NEXT: begin
                    src_ptr    <= src_ptr + 32'd4;     // Next DRAM word
                    dst_ptr    <= dst_ptr + 32'd32;    // Next DMEM word (32-byte stride to stay in bank 0)
                    words_left <= words_left - 32'd1;
                end

                // ---------------------------------------------------------
                DMA_COMPLETE: begin
                    dma_busy <= 1'b0;
                    dma_done <= 1'b1;
                end
            endcase
        end
    end

    // =========================================================================
    // FSM: Next state logic
    // =========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            DMA_IDLE:
                if (dma_start && dma_length != 32'd0)
                    next_state = DMA_REQUEST;

            DMA_REQUEST:
                next_state = DMA_WAIT_ACK;

            DMA_WAIT_ACK:
                if (wb_ack_i)
                    next_state = DMA_WRITE_DMEM;

            DMA_WRITE_DMEM:
                if (!compute_active)
                    next_state = DMA_NEXT;
                // else stay (yield to compute)

            DMA_NEXT:
                if (words_left == 32'd1)
                    next_state = DMA_COMPLETE;
                else
                    next_state = DMA_REQUEST;

            DMA_COMPLETE:
                next_state = DMA_IDLE;
        endcase
    end

endmodule
