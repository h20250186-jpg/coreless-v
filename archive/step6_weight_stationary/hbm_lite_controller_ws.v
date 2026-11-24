`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: hbm_lite_controller
// Description: Autonomous convolution FSM for ATEE. Reads CNN layer parameters
//              from tensor_config_regs, generates all loop addresses, and drives
//              the v_wrapper (vector execution unit) control signals directly —
//              eliminating instruction decode overhead.
//
// The vector unit is a convoy machine: 8 instruction slots, each sweeping vl
// elements one per cycle, slot j issued j cycles after slot 0. This controller
// vectorizes over OUTPUT CHANNEL with vl=8: one vector = 8 consecutive output
// channels (OUTPUT_C must be a multiple of 8).
//
// Execution flow:
//   IDLE → INIT → INIT2 → ISSUE (one slot per cycle) → WAIT (DONE) → NEXT →
//   ISSUE → ... → LAYER_DONE
//
// WEIGHT-STATIONARY: the 8 weights of a kernel tap are loaded ONCE and reused
// for every output pixel. The 8 partial sums of each pixel live in the output
// region of DMEM between taps (OUTPUT_H*OUTPUT_W x 8 words per OC group).
// (The output-stationary version is frozen in
//  archive/step5_output_stationary/hbm_lite_controller_os.v.)
//
// Weight convoy, once per tap:
//   slot 0  load  v_wt  <- weights     (unit-stride, 8 words)
// Pixel convoy, once per tap per output pixel (one slot per cycle, slot 2
// always left EMPTY so no load sits directly ahead of the MAC that reads it):
//   slot 0  load  v_in  <- input row   (unit-stride, 8 words)
//   slot 1  load  v_acc <- partial sums from the output region
//           (left empty on the first tap: nothing accumulated yet)
//   slot 2  (empty)
//   slot 3  MAC   v_acc += v_in * v_wt (MUL on the first tap)
//   slot 4  ReLU  v_acc = max(v_acc, 0)   (last tap only, only if activation[0])
//   slot 4/5 store v_acc -> output region (unit-stride, 8 words)
//
// Convolution loop order (weight-stationary, 8 output channels at a time):
//   for (ocg = 0; ocg < OUTPUT_C; ocg += 8)
//     for (ic = 0; ic < INPUT_C; ic++)
//       for (kh = 0; kh < KERNEL_H; kh++)
//         for (kw = 0; kw < KERNEL_W; kw++)            // weights loaded here
//           for (oh = 0; oh < OUTPUT_H; oh++)
//             for (ow = 0; ow < OUTPUT_W; ow++)
//               out[oh][ow][ocg+0..7] += input[ic][oh*S+kh][ow*S+kw] * weight[ic][kh][kw][ocg+0..7]
//
// Memory layout (DMEM bank = addr[4:2], row = addr[18:5]; all bases must be
// 32-byte aligned so element e of every vector lands in bank e):
//   input  : each pixel REPLICATED across the 8 banks of its own row
//            addr = input_base  + ((ic*H*W + ih*W + iw) << 5)
//   weight : OC-innermost   addr = weight_base + ((tap*OUTPUT_C + oc) << 2)
//            tap = (ic*KH + kh)*KW + kw
//   output : OC-innermost   addr = output_base + (((oh*OW + ow)*OUTPUT_C + oc) << 2)
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
    // FSM States
    // =========================================================================
    localparam [2:0]
        S_IDLE       = 3'd0,
        S_INIT       = 3'd1,
        S_INIT2      = 3'd2,    // 2nd init cycle: compute derived dimensions
        S_ISSUE      = 3'd3,    // drive convoy slot issue_cnt, one slot per cycle
        S_WAIT       = 3'd4,    // hold last slot until the convoy drains (DONE)
        S_NEXT       = 3'd5,    // advance loop counters (vec_clear is on the wires)
        S_LAYER_DONE = 3'd6;

    reg [2:0] state;

    localparam [8:0] VEC_LEN = 9'd8;   // elements per instruction = OC group size

    // =========================================================================
    // Loop counters
    // =========================================================================
    reg [15:0] oc_cnt;   // First output channel of the current group (steps by 8)
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

    // =========================================================================
    // COMBINATIONAL address computation
    // These wires are valid in the same cycle they're used by vec_RS1.
    // =========================================================================
    wire [31:0] comb_input_addr;
    wire [31:0] comb_weight_addr;
    wire [31:0] comb_output_addr;

    // Input: <<5 because each pixel owns a full 8-word row (replicated).
    assign comb_input_addr = input_base
                             + ((ic_cnt * input_plane_size
                                 + (oh_cnt * stride[15:0] + kh_cnt) * input_w
                                 + (ow_cnt * stride[15:0] + kw_cnt)) << 5);

    // Weights / outputs: natural word addressing, OC is the fastest index.
    assign comb_weight_addr = weight_base
                              + (((ic_cnt * kernel_size
                                   + kh_cnt * kernel_w
                                   + kw_cnt) * output_c[15:0]
                                  + oc_cnt) << 2);

    assign comb_output_addr = output_base
                              + (((oh_cnt * output_w + ow_cnt) * output_c[15:0]
                                  + oc_cnt) << 2);

    wire last_tap   = (kw_cnt == kernel_w[15:0] - 16'd1) &&
                      (kh_cnt == kernel_h[15:0] - 16'd1) &&
                      (ic_cnt == input_c[15:0]  - 16'd1);
    wire last_pixel = (ow_cnt == output_w - 16'd1) &&
                      (oh_cnt == output_h - 16'd1);
    wire last_group = (oc_cnt + 16'd8 >= output_c[15:0]);

    wire first_tap  = (kw_cnt == 16'd0) && (kh_cnt == 16'd0) && (ic_cnt == 16'd0);

    reg       wphase;      // 1: weight convoy for this tap, 0: pixel convoys

    // ReLU only once the sum is complete (last tap); store is the slot after it.
    wire       relu_en    = activation[0] && last_tap;
    wire [2:0] store_slot = relu_en ? 3'd5 : 3'd4;
    wire [2:0] last_slot  = wphase ? 3'd0 : store_slot;

    reg [2:0] issue_cnt;   // Slot being issued this cycle
    reg       seen_busy;   // Set when vec_done goes low (convoy started)

    // VRF register allocation. Never v0: forwarding is disabled for vd=0.
    localparam [4:0] VR_INPUT  = 5'd1;
    localparam [4:0] VR_WEIGHT = 5'd2;
    localparam [4:0] VR_ACCUM  = 5'd3;
    localparam [4:0] VR_ZERO   = 5'd12;   // never written: zero for ReLU max(0,x)

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
    // Drive the instruction for convoy slot s (call after set_vec_idle)
    // =========================================================================
    task drive_slot(input [2:0] s);
    begin
        vec_id <= s;
        if (wphase) begin                       // weight convoy: load 8 weights
            vec_start    <= 1'b1;
            vec_vd       <= VR_WEIGHT;
            vec_RS1      <= comb_weight_addr;
            vec_dmr      <= 1'b1;
            vec_reg_we   <= 1'b1;
            vec_mem_reg  <= 1'b1;
        end else if (s == 3'd0) begin           // load input row
            vec_start    <= 1'b1;
            vec_vd       <= VR_INPUT;
            vec_RS1      <= comb_input_addr;
            vec_dmr      <= 1'b1;
            vec_reg_we   <= 1'b1;
            vec_mem_reg  <= 1'b1;
        end else if (s == 3'd1) begin           // load partial sums (not on first tap)
            if (!first_tap) begin
                vec_start    <= 1'b1;
                vec_vd       <= VR_ACCUM;
                vec_RS1      <= comb_output_addr;
                vec_dmr      <= 1'b1;
                vec_reg_we   <= 1'b1;
                vec_mem_reg  <= 1'b1;
            end
        end else if (s == 3'd3) begin           // MUL (first tap) / MAC
            vec_start    <= 1'b1;
            vec_vs1      <= VR_INPUT;
            vec_vs2      <= VR_WEIGHT;
            vec_vd       <= VR_ACCUM;
            vec_funct    <= first_tap ? 8'b00000010 : 8'b00000011;
            vec_reg_we   <= 1'b1;
        end else if (s == store_slot) begin     // store partial sums / result
            vec_start    <= 1'b1;
            vec_vd       <= VR_ACCUM;
            vec_RS1      <= comb_output_addr;
            vec_dmw      <= 1'b1;
        end else if (s == 3'd4) begin           // ReLU (only when store_slot == 5)
            vec_start    <= 1'b1;
            vec_vs1      <= VR_ACCUM;
            vec_vs2      <= VR_ZERO;
            vec_vd       <= VR_ACCUM;
            vec_funct    <= 8'b00000101;
            vec_reg_we   <= 1'b1;
        end
        // s == 2: slot left empty (start=0) to keep loads off the MAC's back
    end
    endtask

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk) begin
        if (reset) begin
            state             <= S_IDLE;
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
            issue_cnt         <= 3'd0;
            wphase            <= 1'b1;
            seen_busy         <= 1'b0;
            vec_vl            <= VEC_LEN;
            vec_quant         <= 2'b00;
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
                        state      <= S_INIT;
                    end
                end

                // ---------------------------------------------------------
                // INIT cycle 1: compute output dimensions + base sizes
                S_INIT: begin
                    output_h <= (input_h[15:0] + {padding[14:0], 1'b0} - kernel_h[15:0]) / stride[15:0] + 16'd1;
                    output_w <= (input_w[15:0] + {padding[14:0], 1'b0} - kernel_w[15:0]) / stride[15:0] + 16'd1;
                    input_plane_size <= input_h * input_w;
                    kernel_size      <= kernel_h * kernel_w;

                    oc_cnt <= 16'd0;
                    oh_cnt <= 16'd0;
                    ow_cnt <= 16'd0;
                    ic_cnt <= 16'd0;
                    kh_cnt <= 16'd0;
                    kw_cnt <= 16'd0;

                    vec_quant  <= q_format;
                    vec_vl     <= VEC_LEN;
                    vec_clear  <= 1'b1;
                    wphase     <= 1'b1;
                    state      <= S_INIT2;
                end

                // ---------------------------------------------------------
                // INIT cycle 2: output_h/w have settled
                S_INIT2: begin
                    issue_cnt <= 3'd0;
                    seen_busy <= 1'b0;
                    state     <= S_ISSUE;
                end

                // ---------------------------------------------------------
                // Issue one convoy slot per cycle: 0, 1, (2 empty), 3 [, 4 [, 5]]
                S_ISSUE: begin
                    drive_slot(issue_cnt);
                    if (!vec_done)
                        seen_busy <= 1'b1;
                    if (issue_cnt == last_slot)
                        state <= S_WAIT;
                    else
                        issue_cnt <= issue_cnt + 3'd1;
                end

                // ---------------------------------------------------------
                // Keep the last slot loaded until every stage has drained,
                // then clear the instruction bank for the next convoy.
                S_WAIT: begin
                    if (!vec_done)
                        seen_busy <= 1'b1;
                    if (seen_busy && vec_done) begin
                        vec_clear <= 1'b1;
                        state     <= S_NEXT;
                    end else begin
                        drive_slot(last_slot);
                    end
                end

                // ---------------------------------------------------------
                // Advance loop counters: kw → kh → ic, then ow → oh → oc group
                S_NEXT: begin
                    issue_cnt <= 3'd0;
                    seen_busy <= 1'b0;
                    state     <= S_ISSUE;

                    if (wphase) begin
                        // Weights for this tap are in v_wt: sweep the pixels
                        wphase <= 1'b0;
                    end else if (!last_pixel) begin
                        if (ow_cnt < output_w - 16'd1) begin
                            ow_cnt <= ow_cnt + 16'd1;
                        end else begin
                            ow_cnt <= 16'd0;
                            oh_cnt <= oh_cnt + 16'd1;
                        end
                    end else begin
                        // Tap finished for every pixel: next tap needs new weights
                        ow_cnt <= 16'd0;
                        oh_cnt <= 16'd0;
                        wphase <= 1'b1;
                        if (!last_tap) begin
                            if (kw_cnt < kernel_w[15:0] - 16'd1) begin
                                kw_cnt <= kw_cnt + 16'd1;
                            end else begin
                                kw_cnt <= 16'd0;
                                if (kh_cnt < kernel_h[15:0] - 16'd1) begin
                                    kh_cnt <= kh_cnt + 16'd1;
                                end else begin
                                    kh_cnt <= 16'd0;
                                    ic_cnt <= ic_cnt + 16'd1;
                                end
                            end
                        end else begin
                            kw_cnt <= 16'd0;
                            kh_cnt <= 16'd0;
                            ic_cnt <= 16'd0;
                            oc_cnt <= oc_cnt + 16'd8;
                            if (last_group)
                                state <= S_LAYER_DONE;
                        end
                    end
                end

                // ---------------------------------------------------------
                S_LAYER_DONE: begin
                    layer_busy <= 1'b0;
                    layer_done <= 1'b1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
