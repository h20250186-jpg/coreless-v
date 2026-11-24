`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: iisc_tb_bench   (FILE iisc_tb_cnn_probe.v)
//
// NEW (2026-11-16): COPY of iisc_tb_bench.v (unchanged) with two additions for
// the cnn_demo checks; the module name is kept so iisc_bench_dump.tcl works
// unchanged. Compile EITHER this file OR iisc_tb_bench.v, never both.
//  1. PROBES (always on) of the two assumed-function stand-ins
//     xbip_dsp48_macro_1/_2 (4 instances in each of the ITLB and the DTLB
//     replacement logic): enables of the replacement logic, every stand-in
//     input and output, counted per phase (0 before conv2d, 1 conv2d, 2 between,
//     3 layer2, 4 between, 5 layer3, 6 after), summary in probe.txt, every
//     change logged in probe_events.txt.
//  2. `define UART_FEED: the image is NOT preloaded; it is sent on srx_pad_i as
//     real UART frames (8N1 + 2 idle bit times between bytes), header AA 55 BB
//     66 then the 784 pixel bytes (= preload.txt value >> 16). The bit time is
//     MEASURED on their own first transmitted start bit ('C'); sending starts
//     at the first fetch of the pflag poll loop (plusarg POLL_PC, default 117c).
//     pflag is not preloaded either.
//
// Original header of iisc_tb_bench.v follows.
// NEW testbench (2026-11-15), a copy of iisc_tb_conv.v (unchanged) generalised
// to ANY of THEIR benchmark programs. Runs the I2SRV32-V repo's OWN design
// (top FPGA_WRAPPER) on its OWN program image (files written by
// scripts/iisc_bench_prep.py into the run directory):
//   bench_params.txt : number of windows W; W lines "entry_pc return_pc" (hex);
//                      final-loop pc (0 = main never returns); err_count addr
//                      (0 = none); number of memory outputs R; R lines
//                      "addr nwords"; "vreg nelem" (0 0 = none)
//   preload.txt      : N; N lines "mainMem_word_index value" (hex) written into
//                      the main-memory model before reset release. Used ONLY for
//                      cnn_demo: it replaces the UART reception of one image
//                      (img_buf[] and pflag, which their boot code does not clear).
// Measured (cycles of the 50 MHz core clock): per window, reset release ->
// entry, entry -> return; reset release -> main returns.
// At the end: cycles and x10 (scalar register file) go to dump.txt, then $stop;
// external/iisc_sim/iisc_bench_dump.tcl then reads the 8 DMEM bank models and
// the 8 VRF banks with get_value (needs xelab -debug typical) and quits.
//////////////////////////////////////////////////////////////////////////////////

module iisc_tb_bench;

    reg clk_p = 1'b0;
    always #2.5 clk_p = ~clk_p;

    reg rst_in = 1'b1;
    reg srx = 1'b1;
    wire ALU_monitor, stx_pad_o, rts_pad_o;

    FPGA_WRAPPER dut (
        .rst_in(rst_in), .clk_in1_n(~clk_p), .clk_in1_p(clk_p),
        .int_in(3'b000), .ALU_monitor(ALU_monitor),
        .srx_pad_i(srx), .stx_pad_o(stx_pad_o), .rts_pad_o(rts_pad_o), .cts_pad_i(1'b0)
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
    reg [31:0] pre_idx [0:1023];
    reg [31:0] pre_val [0:1023];

    // ---- preload of the main-memory model (after its own init at time 0)
    initial begin
        #50;
        fd = $fopen("preload.txt", "r");
        rc = $fscanf(fd, "%d\n", NPRE);
        for (i = 0; i < NPRE; i = i + 1) begin
            rc = $fscanf(fd, "%h %h\n", ra, rv);
            pre_idx[i] = ra;  pre_val[i] = rv;
`ifndef UART_FEED
            dut.em1.Main.inst.native_mem_mapped_module.blk_mem_gen_v8_4_4_inst.memory[ra] = rv;
`endif
        end
        $fclose(fd);
`ifndef UART_FEED
        if (NPRE > 0) $display("[BENCH] preloaded %0d main-memory words before reset release", NPRE);
`else
        $display("[UART] UART_FEED: %0d preload words read, NOT written; the image goes over srx_pad_i", NPRE);
`endif
    end

`ifdef UART_FEED
    // ---- UART feed: measure their bit time on the first TX start bit, then send
    integer bit_cyc, t_fall, nsent, b, ub, poll_pc, gap_bits;
    reg     poll_seen;
    reg [7:0] tx_byte;
    initial begin
        bit_cyc = 0; nsent = 0; poll_seen = 0; gap_bits = 2;
        if (!$value$plusargs("POLL_PC=%h", poll_pc)) poll_pc = 32'h117c;
        @(negedge stx_pad_o);  @(posedge clk);  t_fall = cyc;
        @(posedge stx_pad_o);  @(posedge clk);  bit_cyc = cyc - t_fall;
        $display("[UART] cycle %0d: their first TX start bit lasted %0d core cycles (= bit time used for RX)", cyc, bit_cyc);
        wait (poll_seen);
        $display("[UART] cycle %0d: pflag poll loop reached, sending header + 784 bytes", cyc);
        for (b = 0; b < 788; b = b + 1) begin
            tx_byte = (b == 0) ? 8'hAA : (b == 1) ? 8'h55 : (b == 2) ? 8'hBB : (b == 3) ? 8'h66
                    : pre_val[b - 4][23:16];
            srx = 1'b0;  repeat (bit_cyc) @(posedge clk);
            for (ub = 0; ub < 8; ub = ub + 1) begin srx = tx_byte[ub]; repeat (bit_cyc) @(posedge clk); end
            srx = 1'b1;  repeat (bit_cyc * (1 + gap_bits)) @(posedge clk);
            nsent = nsent + 1;
            if (nsent % 100 == 0) $display("[UART] cycle %0d: %0d bytes sent", cyc, nsent);
        end
        $display("[UART] cycle %0d: all %0d bytes sent", cyc, nsent);
    end
    always @(posedge clk) if (running && !poll_seen && pc == poll_pc) poll_seen = 1;
`endif

    // ---- PROBES of the assumed-function stand-ins (ITLB t=0, DTLB t=1)
    `define RI dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo
    `define RD dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo
    wire [1:0] pr_re   = {`RD.re, `RI.re};
    wire [1:0] pr_we   = {`RD.we, `RI.we};
    wire [1:0] pr_hit  = {`RD.hit, `RI.hit};
    wire [1:0] pr_miss = {`RD.miss, `RI.miss};
    wire [1:0] pr_en   = {`RD.EVA_en, `RI.EVA_en};
    wire [1:0] pr_upd  = {`RD.update_EVA, `RI.update_EVA};
    wire [4:0]  pr_addr [0:1];
    wire [63:0] pr_sort [0:1];
    wire [255:0] pr_in  [0:1];    // in18 in19 in20 in21 pac in24 .. in29 (packed)
    wire [191:0] pr_out [0:1];    // op12 op13 op15 op16
    assign pr_addr[0] = `RI.EVA_addr;  assign pr_addr[1] = `RD.EVA_addr;
    assign pr_sort[0] = `RI.EVA.sorted_index_1D;  assign pr_sort[1] = `RD.EVA.sorted_index_1D;
    assign pr_in[0] = {`RI.EVA.in18, `RI.EVA.in19, `RI.EVA.in20, `RI.EVA.in21, `RI.EVA.pac,
                      `RI.EVA.in24, `RI.EVA.in25, `RI.EVA.in26, `RI.EVA.in27, `RI.EVA.in28, `RI.EVA.in29};
    assign pr_in[1] = {`RD.EVA.in18, `RD.EVA.in19, `RD.EVA.in20, `RD.EVA.in21, `RD.EVA.pac,
                      `RD.EVA.in24, `RD.EVA.in25, `RD.EVA.in26, `RD.EVA.in27, `RD.EVA.in28, `RD.EVA.in29};
    assign pr_out[0] = {`RI.EVA.op12, `RI.EVA.op13, `RI.EVA.op15, `RI.EVA.op16};
    assign pr_out[1] = {`RD.EVA.op12, `RD.EVA.op13, `RD.EVA.op15, `RD.EVA.op16};
    reg [255:0] q_in [0:1];  reg [191:0] q_out [0:1];  reg [63:0] q_sort [0:1];  reg [4:0] q_addr [0:1];
    integer c_re [0:13], c_we [0:13], c_hit [0:13], c_miss [0:13], c_en [0:13], c_upd [0:13];
    integer c_in [0:13], c_out [0:13], c_sort [0:13], c_addr [0:13];   // index = 7*t + phase
    integer pfd, nev, ph7, t, j;
    initial begin
        for (j = 0; j < 14; j = j + 1) begin c_re[j]=0; c_we[j]=0; c_hit[j]=0; c_miss[j]=0; c_en[j]=0;
            c_upd[j]=0; c_in[j]=0; c_out[j]=0; c_sort[j]=0; c_addr[j]=0; end
        nev = 0;
        pfd = $fopen("probe_events.txt", "w");
        $fdisplay(pfd, "# cycle phase tlb(0=ITLB,1=DTLB) what: re we hit miss EVA_en update_EVA EVA_addr | stand-in inputs (in18 in19 in20 in21 pac in24..in29) | outputs (op12 op13 op15 op16) | sorted_index");
    end
    always @(posedge clk) if (running && !done) begin
        ph7 = 0;
        for (j = 0; j < NW; j = j + 1) ph7 = ph7 + w_in[j] + w_out[j];
        for (t = 0; t < 2; t = t + 1) begin
            if (pr_re[t])   c_re[7*t+ph7]   = c_re[7*t+ph7] + 1;
            if (pr_we[t])   c_we[7*t+ph7]   = c_we[7*t+ph7] + 1;
            if (pr_hit[t])  c_hit[7*t+ph7]  = c_hit[7*t+ph7] + 1;
            if (pr_miss[t]) c_miss[7*t+ph7] = c_miss[7*t+ph7] + 1;
            if (pr_en[t])   c_en[7*t+ph7]   = c_en[7*t+ph7] + 1;
            if (pr_upd[t])  c_upd[7*t+ph7]  = c_upd[7*t+ph7] + 1;
            if (pr_in[t]   !== q_in[t])   c_in[7*t+ph7]   = c_in[7*t+ph7] + 1;
            if (pr_out[t]  !== q_out[t])  c_out[7*t+ph7]  = c_out[7*t+ph7] + 1;
            if (pr_sort[t] !== q_sort[t]) c_sort[7*t+ph7] = c_sort[7*t+ph7] + 1;
            if (pr_addr[t] !== q_addr[t]) c_addr[7*t+ph7] = c_addr[7*t+ph7] + 1;
            if ((pr_in[t] !== q_in[t] || pr_out[t] !== q_out[t] || pr_sort[t] !== q_sort[t] || pr_addr[t] !== q_addr[t]
                 || pr_miss[t] || pr_we[t] || pr_en[t] || pr_upd[t]) && nev < 20000) begin
                $fdisplay(pfd, "%0d %0d %0d %b %b %b %b %b %b %0d | %h | %h | %h", cyc, ph7, t, pr_re[t], pr_we[t], pr_hit[t],
                          pr_miss[t], pr_en[t], pr_upd[t], pr_addr[t], pr_in[t], pr_out[t], pr_sort[t]);
                nev = nev + 1;
            end
            q_in[t] = pr_in[t];  q_out[t] = pr_out[t];  q_sort[t] = pr_sort[t];  q_addr[t] = pr_addr[t];
        end
    end
    task probe_report;
        integer f2, tt, pp;
        begin
            f2 = $fopen("probe.txt", "w");
            $fdisplay(f2, "phases: 0 before conv2d | 1 conv2d | 2 between | 3 layer2 | 4 between | 5 layer3 | 6 after layer3");
            for (tt = 0; tt < 2; tt = tt + 1) begin
                $fdisplay(f2, "%s replacement logic, cycles high / cycles with a change, per phase 0..6:", tt ? "DTLB" : "ITLB");
                $fdisplay(f2, "  re            : %0d %0d %0d %0d %0d %0d %0d", c_re[7*tt], c_re[7*tt+1], c_re[7*tt+2], c_re[7*tt+3], c_re[7*tt+4], c_re[7*tt+5], c_re[7*tt+6]);
                $fdisplay(f2, "  we            : %0d %0d %0d %0d %0d %0d %0d", c_we[7*tt], c_we[7*tt+1], c_we[7*tt+2], c_we[7*tt+3], c_we[7*tt+4], c_we[7*tt+5], c_we[7*tt+6]);
                $fdisplay(f2, "  hit           : %0d %0d %0d %0d %0d %0d %0d", c_hit[7*tt], c_hit[7*tt+1], c_hit[7*tt+2], c_hit[7*tt+3], c_hit[7*tt+4], c_hit[7*tt+5], c_hit[7*tt+6]);
                $fdisplay(f2, "  miss          : %0d %0d %0d %0d %0d %0d %0d", c_miss[7*tt], c_miss[7*tt+1], c_miss[7*tt+2], c_miss[7*tt+3], c_miss[7*tt+4], c_miss[7*tt+5], c_miss[7*tt+6]);
                $fdisplay(f2, "  EVA_en        : %0d %0d %0d %0d %0d %0d %0d", c_en[7*tt], c_en[7*tt+1], c_en[7*tt+2], c_en[7*tt+3], c_en[7*tt+4], c_en[7*tt+5], c_en[7*tt+6]);
                $fdisplay(f2, "  update_EVA    : %0d %0d %0d %0d %0d %0d %0d", c_upd[7*tt], c_upd[7*tt+1], c_upd[7*tt+2], c_upd[7*tt+3], c_upd[7*tt+4], c_upd[7*tt+5], c_upd[7*tt+6]);
                $fdisplay(f2, "  stand-in inputs change : %0d %0d %0d %0d %0d %0d %0d", c_in[7*tt], c_in[7*tt+1], c_in[7*tt+2], c_in[7*tt+3], c_in[7*tt+4], c_in[7*tt+5], c_in[7*tt+6]);
                $fdisplay(f2, "  stand-in outputs change: %0d %0d %0d %0d %0d %0d %0d", c_out[7*tt], c_out[7*tt+1], c_out[7*tt+2], c_out[7*tt+3], c_out[7*tt+4], c_out[7*tt+5], c_out[7*tt+6]);
                $fdisplay(f2, "  sorted_index change    : %0d %0d %0d %0d %0d %0d %0d", c_sort[7*tt], c_sort[7*tt+1], c_sort[7*tt+2], c_sort[7*tt+3], c_sort[7*tt+4], c_sort[7*tt+5], c_sort[7*tt+6]);
                $fdisplay(f2, "  EVA_addr change        : %0d %0d %0d %0d %0d %0d %0d", c_addr[7*tt], c_addr[7*tt+1], c_addr[7*tt+2], c_addr[7*tt+3], c_addr[7*tt+4], c_addr[7*tt+5], c_addr[7*tt+6]);
            end
            $fdisplay(f2, "events logged in probe_events.txt: %0d (cap 20000)", nev);
`ifdef UART_FEED
            $fdisplay(f2, "UART: bit time %0d cycles, bytes sent %0d", bit_cyc, nsent);
`endif
            // img_buf as it stands in the main-memory model (stores may still sit in the D-cache)
            pp = 0;
            for (tt = 0; tt < NPRE; tt = tt + 1)
                if (dut.em1.Main.inst.native_mem_mapped_module.blk_mem_gen_v8_4_4_inst.memory[pre_idx[tt]] === pre_val[tt]) pp = pp + 1;
            $fdisplay(f2, "preload words equal in the main-memory model at the end: %0d of %0d", pp, NPRE);
            $fclose(f2);  $fclose(pfd);
        end
    endtask

    // ---- windows (declarations moved above the probes)
    initial begin
        cyc = 0; t_end = -1; t_last = -1; running = 0; seen_end = 0; done = 0;
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
                    w_in[k] = 1; t_in[k] = cyc;
                    $display("[BENCH] cycle %0d: window %0d entered (pc %h)", cyc, k, pc);
                end
                if (w_in[k] && !w_out[k] && pc == ret[k] && cyc > t_in[k] + 20) begin
                    w_out[k] = 1; t_out[k] = cyc; x10_at_ret[k] = x10;
                    $display("[BENCH] cycle %0d: window %0d returned (pc %h), x10 = %0d", cyc, k, pc, x10);
                    if (k == NW - 1) t_last = cyc;
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
            probe_report;
            $display("  probe summary written to probe.txt, events to probe_events.txt");
            $display("  cycles written to dump.txt; DMEM / VRF are read by iisc_bench_dump.tcl");
            $display("  ----------------------------------------------------------------------------");
            $stop;
        end
    endtask

endmodule
