`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: hbm_lite_controller
// Description: Autonomous convolution FSM for ATEE. Reads CNN layer parameters
//              from tensor_config_regs, generates all loop addresses, and drives
//              the v_wrapper (vector execution unit) control signals directly —
//              eliminating instruction decode overhead.
//
// Execution flow:
//   IDLE → INIT → INIT2 → LOAD_INPUT → LOAD_WEIGHT → CONV_MAC → WAIT_MAC →
//   NEXT_KERNEL → ACTIVATION → WAIT_ACT → STORE_OUTPUT → WAIT_STORE →
//   NEXT_PIXEL → ... → LAYER_DONE
//
// Drives v_wrapper signals: I_start, I_id, I_funct, I_vs1/vs2/vd,
//   I_ALUSrc, I_dmr, I_dmw, I_reg_we, I_mem_reg, I_mode_lsu, vl, vcsr_quant
//
// Convolution loop order (output-stationary):
//   for (oc = 0; oc < OUTPUT_C; oc++)
//     for (oh = 0; oh < OUTPUT_H; oh++)
//       for (ow = 0; ow < OUTPUT_W; ow++)
//         for (ic = 0; ic < INPUT_C; ic++)
//           for (kh = 0; kh < KERNEL_H; kh++)
//             for (kw = 0; kw < KERNEL_W; kw++)
//               acc += input[ic][oh*S+kh][ow*S+kw] * weight[oc][ic][kh][kw]
//
// Address generation is COMBINATIONAL (wire) to avoid 1-cycle stale bugs.
// S_INIT is split into 2 cycles so output_h/w are settled before
// output_plane_size is computed.
//////////////////////////////////////////////////////////////////////////////////

module hbm_lite_controller (
    input  wire        clk,
    input  wire        reset,

    // Configuration inputs (from tensor_config_regs)
    input  wire [31:0] input_h,
    input  wire [31:0] input_w,
    input  wire [31:0] input_c,
    input  wire [31:0] kernel_h,
    input  wire [31:0] kernel_w,
    input  wire [31:0] output_c,
    input  wire [31:0] stride,
    input  wire [31:0] padding,
    input  wire [31:0] pool_size,
    input  wire [1:0]  q_format,
    input  wire [31:0] activation,
    input  wire [31:0] input_base,
    input  wire [31:0] weight_base,
    input  wire [31:0] output_base,

    // Layer control
    input  wire        layer_start,
    output reg         layer_busy,
    output reg         layer_done,

    // v_wrapper control signals (active during autonomous execution)
    output reg         vec_start,
    output reg  [2:0]  vec_id,
    output reg  [8:0]  vec_vl,
    output reg  [1:0]  vec_quant,
    output reg         vec_clear,
    output reg  [4:0]  vec_vs1,
    output reg  [4:0]  vec_vs2,
    output reg  [4:0]  vec_vd,
    output reg  [31:0] vec_RS1,
    output reg  [31:0] vec_RS2,
    output reg  [4:0]  vec_uimm5,
    output reg  [7:0]  vec_funct,
    output reg  [1:0]  vec_permute,
    output reg         vec_mask_en,
    output reg  [1:0]  vec_ALUSrc,
    output reg         vec_dmr,
    output reg         vec_dmw,
    output reg         vec_reg_we,
    output reg         vec_mem_reg,
    output reg         vec_Xout,
    output reg  [1:0]  vec_mode_lsu,

    // v_wrapper status inputs
    input  wire        vec_stall,
    input  wire        vec_done,

    // Processor memory interface (for loading/storing data to DMEM)
    output reg  [31:0] proc_addr,
    output reg  [31:0] proc_din,
    output reg         proc_we,
    input  wire [31:0] proc_dout
);

    // =========================================================================
    // FSM States (16 states — all instructions use bank 0 with wait states)
    // =========================================================================
    localparam [3:0]
        S_IDLE           = 4'd0,
        S_INIT           = 4'd1,
        S_INIT2          = 4'd2,    // 2nd init cycle: compute derived dimensions
        S_LOAD_INPUT     = 4'd3,
        S_WAIT_LOAD_IN   = 4'd4,    // wait for load-input to complete pipeline
        S_LOAD_WEIGHT    = 4'd5,
        S_WAIT_LOAD_WT   = 4'd6,    // wait for load-weight to complete pipeline
        S_CONV_MAC       = 4'd7,
        S_WAIT_MAC       = 4'd8,
        S_NEXT_KERNEL    = 4'd9,
        S_ACTIVATION     = 4'd10,
        S_WAIT_ACT       = 4'd11,
        S_STORE_OUTPUT   = 4'd12,
        S_WAIT_STORE     = 4'd13,
        S_NEXT_PIXEL     = 4'd14,
        S_LAYER_DONE     = 4'd15;

    reg [3:0] state, next_state;

    // =========================================================================
    // Loop counters
    // =========================================================================
    reg [15:0] oc_cnt;   // Output channel counter
    reg [15:0] oh_cnt;   // Output height counter
    reg [15:0] ow_cnt;   // Output width counter
    reg [15:0] ic_cnt;   // Input channel counter
    reg [15:0] kh_cnt;   // Kernel height counter
    reg [15:0] kw_cnt;   // Kernel width counter

    // =========================================================================
    // Derived dimensions (computed during INIT/INIT2, stable afterwards)
    // =========================================================================
    reg [15:0] output_h;          // computed in S_INIT
    reg [15:0] output_w;          // computed in S_INIT
    reg [31:0] input_plane_size;  // computed in S_INIT
    reg [31:0] kernel_size;       // computed in S_INIT
    reg [31:0] output_plane_size; // computed in S_INIT2 (after output_h/w settle)

    // =========================================================================
    // COMBINATIONAL address computation (FIX for stale-address bug)
    // These wires are valid in the same cycle they're used by vec_RS1.
    // =========================================================================
    wire [31:0] comb_input_addr;
    wire [31:0] comb_weight_addr;
    wire [31:0] comb_output_addr;

    // NOTE: Offsets are shifted left by 2 (×4) to convert word indices to
    // byte addresses, matching the DMA byte-addressed storage and the
    // LSU/dmem_xbar hardware which extracts bank from addr[4:2] and
    // word address from addr[18:5].
    // Shift left by 5 (×32) instead of 2 (×4) because DMA stores words with
    // 32-byte spacing to keep all data in DMEM bank 0 (bank = addr[4:2]).
    assign comb_input_addr = input_base
                             + ((ic_cnt * input_plane_size
                                 + (oh_cnt * stride[15:0] + kh_cnt) * input_w
                                 + (ow_cnt * stride[15:0] + kw_cnt)) << 5);

    assign comb_weight_addr = weight_base
                              + ((oc_cnt * input_c[15:0] * kernel_size
                                  + ic_cnt * kernel_size
                                  + kh_cnt * kernel_w
                                  + kw_cnt) << 5);

    assign comb_output_addr = output_base
                              + ((oc_cnt * output_plane_size
                                  + oh_cnt * output_w
                                  + ow_cnt) << 5);

    // Wait counter for pipeline latency
    reg [3:0] wait_cnt;
    reg        first_iter;  // First MAC of each output pixel uses MUL (not MAC)
    reg [7:0]  held_funct;  // Saved funct for wait states (first_iter changes at issue)
    reg        seen_busy;   // Set when vec_done goes low (pipeline started processing)

    // VRF register allocation:
    //   v0-v3:  Input tile (loaded from DMEM)
    //   v4-v7:  Weight tile (loaded from DMEM)
    //   v8-v11: Accumulator
    //   v12:    Zero register (for ReLU max(0,x))
    localparam [4:0] VR_INPUT  = 5'd0;
    localparam [4:0] VR_WEIGHT = 5'd4;
    localparam [4:0] VR_ACCUM  = 5'd8;
    localparam [4:0] VR_ZERO   = 5'd12;

    // =========================================================================
    // Default all v_wrapper outputs to inactive
    // =========================================================================
    task set_vec_idle;
    begin
        vec_start    <= 1'b0;
        vec_id       <= 3'd0;
        vec_clear    <= 1'b0;
        vec_vs1      <= 5'd0;
        vec_vs2      <= 5'd0;
        vec_vd       <= 5'd0;
        vec_RS1      <= 32'd0;
        vec_RS2      <= 32'd0;
        vec_uimm5    <= 5'd0;
        vec_funct    <= 8'd0;
        vec_permute  <= 2'd0;
        vec_mask_en  <= 1'b0;
        vec_ALUSrc   <= 2'b00;
        vec_dmr      <= 1'b0;
        vec_dmw      <= 1'b0;
        vec_reg_we   <= 1'b0;
        vec_mem_reg  <= 1'b0;
        vec_Xout     <= 1'b0;
        vec_mode_lsu <= 2'b00;
        proc_addr    <= 32'd0;
        proc_din     <= 32'd0;
        proc_we      <= 1'b0;
    end
    endtask

    // =========================================================================
    // FSM: State register
    // =========================================================================
    always @(posedge clk) begin
        if (reset)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    // =========================================================================
    // FSM: Datapath (sequential)
    // =========================================================================
    always @(posedge clk) begin
        if (reset) begin
            layer_busy        <= 1'b0;
            layer_done        <= 1'b0;
            oc_cnt            <= 16'd0;
            oh_cnt            <= 16'd0;
            ow_cnt            <= 16'd0;
            ic_cnt            <= 16'd0;
            kh_cnt            <= 16'd0;
            kw_cnt            <= 16'd0;
            output_h          <= 16'd0;
            output_w          <= 16'd0;
            input_plane_size  <= 32'd0;
            kernel_size       <= 32'd0;
            output_plane_size <= 32'd0;
            wait_cnt          <= 4'd0;
            first_iter        <= 1'b1;
            held_funct        <= 8'd0;
            seen_busy         <= 1'b0;
            set_vec_idle;
        end else begin
            // Defaults each cycle
            set_vec_idle;
            layer_done <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    layer_busy <= 1'b0;
                    if (layer_start) begin
                        layer_busy <= 1'b1;
                        layer_done <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                // INIT cycle 1: compute output dimensions + base sizes
                S_INIT: begin
                    output_h <= (input_h[15:0] + {padding[14:0], 1'b0} - kernel_h[15:0]) / stride[15:0] + 16'd1;
                    output_w <= (input_w[15:0] + {padding[14:0], 1'b0} - kernel_w[15:0]) / stride[15:0] + 16'd1;
                    input_plane_size <= input_h * input_w;
                    kernel_size      <= kernel_h * kernel_w;

                    // Reset all loop counters
                    oc_cnt <= 16'd0;
                    oh_cnt <= 16'd0;
                    ow_cnt <= 16'd0;
                    ic_cnt <= 16'd0;
                    kh_cnt <= 16'd0;
                    kw_cnt <= 16'd0;

                    // Set vector unit config
                    vec_quant <= q_format;
                    vec_vl    <= 9'd1;
                    vec_clear <= 1'b1;
                    first_iter <= 1'b1;
                end

                // ---------------------------------------------------------
                // INIT cycle 2: output_h/w have settled, compute derived
                S_INIT2: begin
                    output_plane_size <= output_h * output_w;
                    // Keep vector config stable
                    vec_quant <= q_format;
                    vec_vl    <= 9'd1;
                end

                // ---------------------------------------------------------
                // Load input element from DMEM into VRF
                // Address computed COMBINATIONALLY via comb_input_addr
                S_LOAD_INPUT: begin
                    // Do NOT set vec_start here — leave start=0 for 1 cycle
                    // so count_gen can reset before next instruction.
                    // All other signals are set so WAIT state can assert start=1.
                    wait_cnt     <= 4'd0;
                    seen_busy    <= 1'b0;
                end

                // ---------------------------------------------------------
                S_WAIT_LOAD_IN: begin
                    // Hold instruction signals so pipeline can capture them
                    vec_start    <= 1'b1;
                    vec_id       <= 3'd0;
                    vec_vd       <= VR_INPUT;
                    vec_RS1      <= comb_input_addr;
                    vec_dmr      <= 1'b1;
                    vec_reg_we   <= 1'b1;
                    vec_mem_reg  <= 1'b1;
                    vec_mode_lsu <= 2'b00;
                    vec_funct    <= 8'd0;
                    wait_cnt <= wait_cnt + 4'd1;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                end

                // ---------------------------------------------------------
                // Load weight element from DMEM into VRF
                // Address computed COMBINATIONALLY via comb_weight_addr
                S_LOAD_WEIGHT: begin
                    // Do NOT set vec_start here — leave start=0 for 1 cycle
                    // so count_gen can reset before next instruction.
                    wait_cnt     <= 4'd0;
                    seen_busy    <= 1'b0;
                end

                // ---------------------------------------------------------
                S_WAIT_LOAD_WT: begin
                    // Hold instruction signals so pipeline can capture them
                    vec_start    <= 1'b1;
                    vec_id       <= 3'd0;
                    vec_vd       <= VR_WEIGHT;
                    vec_RS1      <= comb_weight_addr;
                    vec_dmr      <= 1'b1;
                    vec_reg_we   <= 1'b1;
                    vec_mem_reg  <= 1'b1;
                    vec_mode_lsu <= 2'b00;
                    vec_funct    <= 8'd0;
                    wait_cnt <= wait_cnt + 4'd1;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                end

                // ---------------------------------------------------------
                // MAC: acc += input * weight (funct=011)
                S_CONV_MAC: begin
                    // Do NOT set vec_start here — leave start=0 for 1 cycle
                    // so count_gen can reset before next instruction.
                    held_funct   <= first_iter ? 8'b00000010 : 8'b00000011; // Save for wait state
                    first_iter   <= 1'b0;
                    wait_cnt     <= 4'd0;
                    seen_busy    <= 1'b0;
                end

                // ---------------------------------------------------------
                S_WAIT_MAC: begin
                    // Hold instruction signals so pipeline can capture them
                    vec_start    <= 1'b1;
                    vec_id       <= 3'd0;
                    vec_vs1      <= VR_INPUT;
                    vec_vs2      <= VR_WEIGHT;
                    vec_vd       <= VR_ACCUM;
                    vec_funct    <= held_funct;
                    vec_ALUSrc   <= 2'b00;
                    vec_reg_we   <= 1'b1;
                    vec_mem_reg  <= 1'b0;
                    vec_dmr      <= 1'b0;
                    vec_dmw      <= 1'b0;
                    wait_cnt <= wait_cnt + 4'd1;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                end

                // ---------------------------------------------------------
                // Advance kernel loop counters: kw → kh → ic
                S_NEXT_KERNEL: begin
                    if (kw_cnt < kernel_w[15:0] - 16'd1) begin
                        kw_cnt <= kw_cnt + 16'd1;
                    end else begin
                        kw_cnt <= 16'd0;
                        if (kh_cnt < kernel_h[15:0] - 16'd1) begin
                            kh_cnt <= kh_cnt + 16'd1;
                        end else begin
                            kh_cnt <= 16'd0;
                            if (ic_cnt < input_c[15:0] - 16'd1) begin
                                ic_cnt <= ic_cnt + 16'd1;
                            end else begin
                                ic_cnt <= 16'd0;
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                // ReLU: acc = max(0, acc) using ALU funct=101
                S_ACTIVATION: begin
                    // Do NOT set vec_start here — leave start=0 for 1 cycle
                    // so count_gen can reset before next instruction.
                    wait_cnt <= 4'd0;
                    seen_busy <= 1'b0;
                end

                // ---------------------------------------------------------
                S_WAIT_ACT: begin
                    // Hold activation instruction so pipeline can capture it
                    if (activation[0]) begin
                        vec_start    <= 1'b1;
                        vec_id       <= 3'd0;
                        vec_vs1      <= VR_ACCUM;
                        vec_vs2      <= VR_ZERO;
                        vec_vd       <= VR_ACCUM;
                        vec_funct    <= 8'b00000101;
                        vec_ALUSrc   <= 2'b00;
                        vec_reg_we   <= 1'b1;
                        vec_mem_reg  <= 1'b0;
                    end
                    wait_cnt <= wait_cnt + 4'd1;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                end

                // ---------------------------------------------------------
                // Store accumulator to output DMEM
                // Address computed COMBINATIONALLY via comb_output_addr
                S_STORE_OUTPUT: begin
                    // Do NOT set vec_start here — leave start=0 for 1 cycle
                    // so count_gen can reset before next instruction.
                    wait_cnt     <= 4'd0;
                    seen_busy    <= 1'b0;
                end

                // ---------------------------------------------------------
                S_WAIT_STORE: begin
                    // Hold store instruction so pipeline can capture it
                    vec_start    <= 1'b1;
                    vec_id       <= 3'd0;
                    vec_vd       <= VR_ACCUM;
                    vec_RS1      <= comb_output_addr;
                    vec_dmw      <= 1'b1;
                    vec_reg_we   <= 1'b0;
                    vec_mode_lsu <= 2'b00;
                    vec_funct    <= 8'd0;
                    wait_cnt <= wait_cnt + 4'd1;
                    if (!vec_done)
                        seen_busy <= 1'b1;
                end

                // ---------------------------------------------------------
                // Advance output pixel loop: ow → oh → oc
                S_NEXT_PIXEL: begin
                    if (ow_cnt < output_w - 16'd1) begin
                        ow_cnt <= ow_cnt + 16'd1;
                    end else begin
                        ow_cnt <= 16'd0;
                        if (oh_cnt < output_h - 16'd1) begin
                            oh_cnt <= oh_cnt + 16'd1;
                        end else begin
                            oh_cnt <= 16'd0;
                            if (oc_cnt < output_c[15:0] - 16'd1) begin
                                oc_cnt <= oc_cnt + 16'd1;
                            end else begin
                                // All done
                            end
                        end
                    end
                    // Reset kernel counters for next output pixel
                    kh_cnt <= 16'd0;
                    kw_cnt <= 16'd0;
                    ic_cnt <= 16'd0;
                    first_iter <= 1'b1;  // Next pixel: first MAC becomes MUL
                end

                // ---------------------------------------------------------
                S_LAYER_DONE: begin
                    layer_busy <= 1'b0;
                    layer_done <= 1'b1;
                end
            endcase
        end
    end

    // =========================================================================
    // FSM: Next state combinational logic
    // =========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:
                if (layer_start)
                    next_state = S_INIT;

            S_INIT:
                next_state = S_INIT2;       // wait 1 cycle for output_h/w to settle

            S_INIT2:
                next_state = S_LOAD_INPUT;  // now output_plane_size is valid

            S_LOAD_INPUT:
                next_state = S_WAIT_LOAD_IN;

            S_WAIT_LOAD_IN: begin
                if ((seen_busy && vec_done) || wait_cnt >= 4'd15)
                    next_state = S_LOAD_WEIGHT;
            end

            S_LOAD_WEIGHT:
                next_state = S_WAIT_LOAD_WT;

            S_WAIT_LOAD_WT: begin
                if ((seen_busy && vec_done) || wait_cnt >= 4'd15)
                    next_state = S_CONV_MAC;
            end

            S_CONV_MAC:
                next_state = S_WAIT_MAC;

            S_WAIT_MAC: begin
                if ((seen_busy && vec_done) || wait_cnt >= 4'd15)
                    next_state = S_NEXT_KERNEL;
            end

            S_NEXT_KERNEL: begin
                if (kw_cnt == kernel_w[15:0] - 16'd1 &&
                    kh_cnt == kernel_h[15:0] - 16'd1 &&
                    ic_cnt == input_c[15:0] - 16'd1)
                    next_state = S_ACTIVATION;
                else
                    next_state = S_LOAD_INPUT;
            end

            S_ACTIVATION:
                next_state = S_WAIT_ACT;

            S_WAIT_ACT: begin
                if (!activation[0])
                    next_state = S_STORE_OUTPUT;
                else if ((seen_busy && vec_done) || wait_cnt >= 4'd15)
                    next_state = S_STORE_OUTPUT;
            end

            S_STORE_OUTPUT:
                next_state = S_WAIT_STORE;

            S_WAIT_STORE: begin
                if ((seen_busy && vec_done) || wait_cnt >= 4'd15)
                    next_state = S_NEXT_PIXEL;
            end

            S_NEXT_PIXEL: begin
                if (ow_cnt == output_w - 16'd1 &&
                    oh_cnt == output_h - 16'd1 &&
                    oc_cnt == output_c[15:0] - 16'd1)
                    next_state = S_LAYER_DONE;
                else
                    next_state = S_LOAD_INPUT;
            end

            S_LAYER_DONE:
                next_state = S_IDLE;
        endcase
    end

endmodule
