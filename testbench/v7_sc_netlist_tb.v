`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: v7_sc_netlist_tb
// NEW testbench (2026-11-19): a COPY of atee_sc_tb.v (unchanged) for the
// netlist-SAIF power flow of the scalar-operand design (funcsim netlist of the
// routed Virtex-7 checkpoint, Vivado 2019.1 xsim; scripts/v7_power_atee_sc.ps1).
// Differences from atee_sc_tb.v, and nothing else:
//   1. no parameter override on the DUT (the netlist has no ENABLE_DIV; the
//      checkpoint was built with ENABLE_DIV = 0);
//   2. no count of the controller's convoy states (the netlist has no `state`
//      register by that name); conv_cyc stays 0, so the per-layer line prints
//      "convoy states 0" and other = the whole layer: ignore those two fields.
// Same files (cnn_params.txt, cnn_load.txt), same sequence, same printout.
//////////////////////////////////////////////////////////////////////////////////
module v7_sc_netlist_tb;

    parameter CLK_PERIOD = 20;

    reg clk, reset;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg  [31:0] proc_addr, proc_din;
    wire [31:0] proc_dout;
    reg         proc_we;
    wire        ALU_mon, stall_out, DONE_out, cfg_error;
    wire [3:0]  cur_layer, cnn_class;
    wire [4:0]  XRF_ADDR;
    wire [31:0] XRF_DATAWR;
    wire        XRF_WE;

    atee_top_sc dut (
        .clk(clk), .reset(reset),
        .vl(9'd8), .vcsr_quant(2'b00), .I_clear(1'b0), .I_id(3'd0),
        .ALU_mon(ALU_mon), .stall(stall_out), .DONE(DONE_out),
        .proc_addr(proc_addr), .proc_din(proc_din), .proc_dout(proc_dout), .proc_we(proc_we),
        .XRF_ADDR(XRF_ADDR), .XRF_DATAWR(XRF_DATAWR), .XRF_WE(XRF_WE),
        .I_start(1'b0), .I_vs1(5'd0), .I_vs2(5'd0), .I_vd(5'd0),
        .I_RS1(32'd0), .I_RS2(32'd0), .I_uimm5(5'd0), .I_funct(8'd0),
        .I_permute(2'd0), .I_mask_en(1'b0), .I_ALUSrc(2'b00),
        .I_dmr(1'b0), .I_dmw(1'b0), .I_reg_we(1'b0), .I_mem_reg(1'b0),
        .I_Xout(1'b0), .I_mode_lsu(2'b00),
        .cfg_error(cfg_error), .cur_layer(cur_layer), .cnn_class(cnn_class)
    );

    localparam CFG_BASE        = 32'h0020_0000;
    localparam CFG_INPUT_C     = CFG_BASE + 32'h08;
    localparam CFG_INPUT_BASE  = CFG_BASE + 32'h2C;
    localparam CFG_LAYER_START = CFG_BASE + 32'h38;
    localparam CFG_CYCLE_CNT   = CFG_BASE + 32'h40;

    task proc_write(input [31:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        proc_addr <= addr;  proc_din <= data;  proc_we <= 1'b1;
        @(posedge clk);
        proc_we <= 1'b0;
    end
    endtask

    // ---- cycle counter and per-layer timestamps
    integer cyc;
    always @(posedge clk) cyc <= reset ? 0 : cyc + 1;
    integer t_busy_rise, t_busy_fall, n_host_we_busy;
    integer t_layer [0:15];
    // cycles the controller spends in its convoy states (S_ISSUE 5, S_WAIT 6,
    // S_NEXT 7), per layer: the part the slot-rule model predicts
    integer conv_cyc [0:15];
    integer li;
    initial for (li = 0; li < 16; li = li + 1) conv_cyc[li] = 0;
    reg [3:0] last_layer;
    reg       busy_q;
    always @(posedge clk) begin
        if (reset) begin
            busy_q <= 1'b0;  last_layer <= 4'd0;  n_host_we_busy <= 0;
        end else begin
            busy_q <= dut.cfg_layer_busy;
            if (dut.cfg_layer_busy && !busy_q) begin
                t_busy_rise <= cyc;  t_layer[0] <= cyc;  last_layer <= 4'd0;
            end
            if (!dut.cfg_layer_busy && busy_q)
                t_busy_fall <= cyc;
            if (dut.cfg_layer_busy && cur_layer != last_layer) begin
                t_layer[cur_layer] <= cyc;  last_layer <= cur_layer;
            end
            if (dut.cfg_layer_busy && proc_we)
                n_host_we_busy <= n_host_we_busy + 1;
        end
    end

    integer fd, rc, i, j, n_layers, n_load, n_reg;
    reg [31:0] desc_base, a, d, cycle_count;
    reg [31:0] reg_addr [0:7];
    integer    reg_n    [0:7];
    integer    fo;

    initial begin
        proc_addr = 32'd0;  proc_din = 32'd0;  proc_we = 1'b0;  cyc = 0;
        reset = 1'b1;
        #(CLK_PERIOD * 20);
        reset = 1'b0;
        #(CLK_PERIOD * 5);

        fd = $fopen("cnn_params.txt", "r");
        rc = $fscanf(fd, "%h\n%d\n%d\n%d\n", desc_base, n_layers, n_load, n_reg);
        for (i = 0; i < n_reg; i = i + 1)
            rc = $fscanf(fd, "%h %d\n", reg_addr[i], reg_n[i]);
        $fclose(fd);

        // ---- load DMEM, 1 word per cycle
        fd = $fopen("cnn_load.txt", "r");
        for (i = 0; i < n_load; i = i + 1) begin
            rc = $fscanf(fd, "%h %h\n", a, d);
            @(posedge clk);
            proc_addr <= a;  proc_din <= d;  proc_we <= 1'b1;
        end
        @(posedge clk);
        proc_we <= 1'b0;
        $fclose(fd);

        $display("");
        $display("================================================================");
        $display("  Coreless-V scalar-operand controller (vl=16), %0d layer(s), %0d DMEM words loaded", n_layers, n_load);
        $display("================================================================");

        // ---- ONE start
        proc_write(CFG_INPUT_BASE, desc_base);
        proc_write(CFG_INPUT_C, n_layers);
        proc_write(CFG_LAYER_START, 32'd1);
        @(posedge clk);
        wait (dut.cfg_layer_busy == 1'b1);
        wait (dut.cfg_layer_busy == 1'b0);
        repeat (4) @(posedge clk);

        @(posedge clk);  proc_addr <= CFG_CYCLE_CNT;  proc_we <= 1'b0;
        @(negedge clk);  cycle_count = proc_dout;

        $display("  layer-busy cycles (CYCLE_COUNT)   : %0d", cycle_count);
        $display("  busy rise -> fall (testbench)     : %0d", t_busy_fall - t_busy_rise);
        for (i = 0; i < n_layers; i = i + 1)
            $display("  layer %0d: start at +%0d, cycles %0d (convoy states %0d, other %0d)", i + 1, t_layer[i] - t_busy_rise,
                     ((i + 1 < n_layers) ? t_layer[i + 1] : t_busy_fall) - t_layer[i], conv_cyc[i],
                     ((i + 1 < n_layers) ? t_layer[i + 1] : t_busy_fall) - t_layer[i] - conv_cyc[i]);
        $display("  cfg_error                         : %0d", cfg_error);
        $display("  cnn_class                         : %0d", cnn_class);
        $display("  host writes while busy            : %0d", n_host_we_busy);

        // ---- dump regions, 1 word per cycle (data 1 cycle after the address edge, sampled at negedge)
        fo = $fopen("cnn_dump.txt", "w");
        for (j = 0; j < n_reg; j = j + 1) begin
            for (i = 0; i <= reg_n[j]; i = i + 1) begin
                @(posedge clk);
                if (i < reg_n[j]) proc_addr <= reg_addr[j] + (i << 2);
                @(negedge clk);
                if (i >= 1) $fwrite(fo, "%08x %08x\n", reg_addr[j] + ((i - 1) << 2), proc_dout);
            end
        end
        $fclose(fo);
        $display("  DUMP written: cnn_dump.txt");
        $display("CNN_DONE cycles %0d class %0d err %0d hostwe %0d", cycle_count, cnn_class, cfg_error, n_host_we_busy);
        #(CLK_PERIOD * 10);
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 3_000_000);
        $display("ERROR: Simulation timeout after 3M cycles");
        $finish;
    end

endmodule

