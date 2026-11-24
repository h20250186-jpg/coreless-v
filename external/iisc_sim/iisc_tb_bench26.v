`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: iisc_tb_bench26
//
// NEW testbench (2026-11-19): a COPY of iisc_tb_bench.v (unchanged) for the
// Vivado 2026.1 RTL-SAIF power run of cnn_demo (scripts/v7_rtlsaif_iisc_cnn.ps1).
// Differences from iisc_tb_bench.v, and nothing else:
//   1. no hierarchical preload of the main-memory model (its instance name is
//      version-specific: blk_mem_gen_v8_4_4_inst in 2019.1). The preload words
//      (img_buf[] and pflag) are written into mainMem.mif instead, which the
//      2026.1 model loads at time zero: the memory holds the same words at reset
//      release as in the 2019.1 runs.
//   2. two flags for testbench/v7_rtlsaif_iisc_cnn.tcl: seen_in (window 0 entered
//      = conv2d entry) and seen_out (last window returned = layer3 return): the
//      SAIF window is the inference, conv2d entry -> layer3 return.
//////////////////////////////////////////////////////////////////////////////////
module iisc_tb_bench26;

    reg clk_p = 1'b0;
    always #2.5 clk_p = ~clk_p;

    reg rst_in = 1'b1;
    wire ALU_monitor, stx_pad_o, rts_pad_o;

    FPGA_WRAPPER dut (
        .rst_in(rst_in), .clk_in1_n(~clk_p), .clk_in1_p(clk_p),
        .int_in(3'b000), .ALU_monitor(ALU_monitor),
        .srx_pad_i(1'b1), .stx_pad_o(stx_pad_o), .rts_pad_o(rts_pad_o), .cts_pad_i(1'b0)
    );

    wire        clk  = dut.clk_int;
    wire        rst  = dut.rst;
    wire [31:0] pc   = dut.cpu1.fdem.Pipeline.IF.pc;
    wire [31:0] p_addr = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_addr;
    wire [31:0] p_din  = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_din;
    wire        p_we   = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_we;
    wire [31:0] x10    = dut.cpu1.fdem.Pipeline.RF.MEM[10];

    // ---- parameters
    integer NW, NR, NPRE, VREG, VN, fd, rc, i, k, maxcyc;
    reg [31:0] ent [0:7];
    reg [31:0] ret [0:7];
    reg [31:0] PC_END, A_ERRCNT, ra, rv;
    reg [31:0] oaddr [0:7];
    integer    on [0:7];
    initial begin
        fd = $fopen("bench_params.txt", "r");
        rc = $fscanf(fd, "%d\n", NW);
        for (i = 0; i < NW; i = i + 1) rc = $fscanf(fd, "%h %h\n", ent[i], ret[i]);
        rc = $fscanf(fd, "%h\n%h\n%d\n", PC_END, A_ERRCNT, NR);
        for (i = 0; i < NR; i = i + 1) rc = $fscanf(fd, "%h %d\n", oaddr[i], on[i]);
        rc = $fscanf(fd, "%d %d\n", VREG, VN);
        $fclose(fd);
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 40000000;
        $display("[BENCH] %0d window(s), final pc %h, err_count addr %h, %0d memory output(s), vreg %0d x %0d",
                 NW, PC_END, A_ERRCNT, NR, VREG, VN);
    end

    // ---- windows
    integer cyc, t_end, t_last;
    integer t_in [0:7];
    integer t_out [0:7];
    reg     w_in [0:7];
    reg     w_out [0:7];
    reg [31:0] x10_at_ret [0:7];
    reg [31:0] x10_r1, x10_r5, x10_r10;
    integer errcnt_writes, errcnt_nonzero;
    reg [31:0] errcnt_value;
    reg running, seen_end, done;
    reg seen_in, seen_out;
    initial begin
        cyc = 0; t_end = -1; t_last = -1; running = 0; seen_end = 0; done = 0; seen_in = 0; seen_out = 0;
        errcnt_writes = 0; errcnt_nonzero = 0; errcnt_value = 32'hxxxx_xxxx;
        for (i = 0; i < 8; i = i + 1) begin t_in[i] = -1; t_out[i] = -1; w_in[i] = 0; w_out[i] = 0; end
        repeat (20) @(posedge clk);
        rst_in = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst && !rst_in) running <= 1'b1;
        if (running && !done) begin
            cyc = cyc + 1;
            for (k = 0; k < NW; k = k + 1) begin
                if (!w_in[k] && (k == 0 || w_out[k-1]) && pc == ent[k]) begin
                    w_in[k] = 1; t_in[k] = cyc;  if (k == 0) seen_in = 1;
                    $display("[BENCH] cycle %0d: window %0d entered (pc %h)", cyc, k, pc);
                end
                if (w_in[k] && !w_out[k] && pc == ret[k] && cyc > t_in[k] + 20) begin
                    w_out[k] = 1; t_out[k] = cyc; x10_at_ret[k] = x10;
                    $display("[BENCH] cycle %0d: window %0d returned (pc %h), x10 = %0d", cyc, k, pc, x10);
                    if (k == NW - 1) begin t_last = cyc; seen_out = 1; end
                end
            end
            if (t_last > 0) begin
                if (cyc == t_last + 1)  x10_r1  = x10;
                if (cyc == t_last + 5)  x10_r5  = x10;
                if (cyc == t_last + 10) x10_r10 = x10;
            end
            if (PC_END != 0 && w_out[NW-1] && !seen_end && pc == PC_END) begin
                seen_end = 1; t_end = cyc;
                $display("[BENCH] cycle %0d: main returned (pc %h, final loop)", cyc, pc);
            end
            if (A_ERRCNT != 0 && p_we && p_addr == A_ERRCNT) begin
                errcnt_writes = errcnt_writes + 1;  errcnt_value = p_din;
                if (p_din !== 32'd0) errcnt_nonzero = errcnt_nonzero + 1;
            end
            if ((PC_END != 0 && seen_end && cyc == t_end + 50) ||
                (PC_END == 0 && t_last > 0 && cyc == t_last + 50)) begin
                done = 1;
                report;
            end
            if (cyc % 500000 == 0) $display("[BENCH] cycle %0d: pc = %h", cyc, pc);
            if (cyc >= maxcyc) begin
                $display("[BENCH] TIMEOUT at cycle %0d, pc %h", cyc, pc);
                done = 1;  report;
            end
        end
    end

    // Scratchpad banks and vector registers live under the VHDL vector unit,
    // which Verilog hierarchical references cannot enter in xsim 2019.1: they are
    // read after $stop by external/iisc_sim/iisc_bench_dump.tcl (get_value).

    task report;
        integer of, w, e;
        begin
            $display("");
            $display("  ------------- I2SRV32-V benchmark, their design, their program -------------");
            for (w = 0; w < NW; w = w + 1) begin
                $display("  window %0d (entry %h, return %h): reset -> entry %0d | entry -> return %0d | reset -> return %0d | x10 at return %0d",
                         w, ent[w], ret[w], t_in[w], t_out[w] - t_in[w], t_out[w], x10_at_ret[w]);
            end
            if (NW > 1) $display("  first entry -> last return          : %0d cycles", t_out[NW-1] - t_in[0]);
            $display("  x10 at last return +1 / +5 / +10    : %0d / %0d / %0d", x10_r1, x10_r5, x10_r10);
            if (PC_END != 0) $display("  reset release -> main returns       : %0d cycles", t_end);
            if (A_ERRCNT != 0) begin
                $display("  CPU writes to err_count             : %0d (non-zero values written: %0d), last value = %0d",
                         errcnt_writes, errcnt_nonzero, errcnt_value);
                $display("  err_count == 0                      : %s", (errcnt_writes >= 1 && errcnt_value === 32'd0) ? "YES" : "NO");
            end
            of = $fopen("dump.txt", "w");
            for (w = 0; w < NW; w = w + 1) $fdisplay(of, "W %0d %0d %0d %0d", w, t_in[w], t_out[w], x10_at_ret[w]);
            $fdisplay(of, "E %0d", t_end);
            $fdisplay(of, "X %0d %0d %0d", x10_r1, x10_r5, x10_r10);
            $fdisplay(of, "C %0d %0d %0d", errcnt_writes, errcnt_nonzero, errcnt_value);
            $fclose(of);
            $display("  cycles written to dump.txt; DMEM / VRF are read by iisc_bench_dump.tcl");
            $display("  ----------------------------------------------------------------------------");
            $stop;
        end
    endtask

endmodule

