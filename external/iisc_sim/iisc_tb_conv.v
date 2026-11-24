`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: iisc_tb_conv
//
// NEW testbench (2026-11-11), a copy of iisc_tb_dtlb.v (unchanged) generalised
// to THEIR CONV2D 3x3 benchmarks at any image size (conv8_3 .. conv64_3).
// Runs the I2SRV32-V repo's OWN design (top FPGA_WRAPPER) on its OWN program.
// Their code addresses are the same at every size (conv2d 0x9d0, return 0xe98,
// main returns to 0xec); per-size data addresses come from conv_params.txt
// (written by scripts/gen_conv_sizes.py from their riscv-spike.dump).
//
// Measured (cycles of the 50 MHz core clock):
//   reset release -> conv2d entry, conv2d entry -> return, reset -> return,
//   reset -> main returns; err_count from the CPU's own writes.
// Stand-in check: ITLB and DTLB replacement logic, per phase (as iisc_tb_dtlb).
//
// EXACTNESS: after conv2d returns, main()'s check loop reads Y[i] and
// expected_output[i] through the vector unit's processor interface. Every
// cycle, proc_dout is recorded against the address presented L = 0..3 cycles
// earlier. The latency L is CALIBRATED on the expected_output[] reads (known
// values, conv_theirs.hex); the Y values captured at that L are then compared
// element by element with their expected outputs and with the Python reference.
//////////////////////////////////////////////////////////////////////////////////

module iisc_tb_conv;

    parameter MAXN = 61504;

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
    wire [31:0] p_dout = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_dout;
    wire        p_we   = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_we;

    localparam [31:0] PC_CONV2D = 32'h0000_09d0,
                      PC_RETURN = 32'h0000_0e98,
                      PC_END    = 32'h0000_00ec,
                      PC_OUTER  = 32'h0000_0a7c;

    // ---- per-size parameters
    integer img_size, ker_size, n_filt, out_size, in_words, n_out, distinct, fd, rc;
    reg [31:0] A_Y, A_EXP, A_ERRCNT;
    reg [31:0] theirs [0:MAXN-1];
    reg [31:0] golden [0:MAXN-1];
    initial begin
        fd = $fopen("conv_params.txt", "r");
        rc = $fscanf(fd, "%d\n%d\n%d\n%d\n%d\n%d\n%h\n%h\n%h\n%d\n",
                     img_size, ker_size, n_filt, out_size, in_words, n_out, A_Y, A_EXP, A_ERRCNT, distinct);
        $fclose(fd);
        $readmemh("conv_theirs.hex", theirs, 0, n_out - 1);
        $readmemh("conv_golden.hex", golden, 0, n_out - 1);
    end

    // ---- ITLB / DTLB replacement logic (the only place the stand-ins are used)
    wire        r_we   = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.we;
    wire        r_miss = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.miss;
    wire        r_en   = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.EVA_en;
    wire        r_upd  = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.update_EVA;
    wire [4:0]  r_addr = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.EVA_addr;
    wire [47:0] s_p12  = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.EVA.eva_dsp_R.P;
    wire [47:0] s_p13  = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.EVA.eva_dsp_NR.P;
    wire [47:0] s_p15  = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.EVA.diff_classe_R.P;
    wire [47:0] s_p16  = dut.cpu1.fdem.mh.icache1.itlb.i_replacement_algo.EVA.diff_classe_NR.P;
    reg  [47:0] q_p12, q_p13, q_p15, q_p16;  reg [4:0] q_addr;
    wire        d_we   = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.we;
    wire        d_miss = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.miss;
    wire        d_en   = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.EVA_en;
    wire        d_upd  = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.update_EVA;
    wire [4:0]  d_addr = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.EVA_addr;
    wire [47:0] d_p12  = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.EVA.eva_dsp_R.P;
    wire [47:0] d_p13  = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.EVA.eva_dsp_NR.P;
    wire [47:0] d_p15  = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.EVA.diff_classe_R.P;
    wire [47:0] d_p16  = dut.cpu1.fdem.db1.dt1.dd.dtlb.d_replacement_algo.EVA.diff_classe_NR.P;
    reg  [47:0] dq_p12, dq_p13, dq_p15, dq_p16;  reg [4:0] dq_addr;
    integer n_we [0:2], n_miss [0:2], n_en [0:2], n_upd [0:2], n_addr [0:2], n_std [0:2];
    integer dn_we [0:2], dn_miss [0:2], dn_en [0:2], dn_upd [0:2], dn_addr [0:2], dn_std [0:2];
    integer ph, kk;
    initial for (kk = 0; kk < 3; kk = kk + 1) begin
        n_we[kk]=0; n_miss[kk]=0; n_en[kk]=0; n_upd[kk]=0; n_addr[kk]=0; n_std[kk]=0;
        dn_we[kk]=0; dn_miss[kk]=0; dn_en[kk]=0; dn_upd[kk]=0; dn_addr[kk]=0; dn_std[kk]=0;
    end

    // ---- capture of the check loop's reads: value now vs address L cycles ago
    reg [31:0] capY [0:4*MAXN-1];
    reg [31:0] capE [0:4*MAXN-1];
    reg        hasY [0:4*MAXN-1];
    reg        hasE [0:4*MAXN-1];
    reg [31:0] ah1, ah2, ah3, aL;
    integer    L, idx;
    initial for (kk = 0; kk < 4*MAXN; kk = kk + 1) begin hasY[kk] = 0; hasE[kk] = 0; end

    integer cyc, t_conv_in, t_conv_out, t_end, t_loop;
    integer errcnt_writes, errcnt_nonzero;
    reg [31:0] errcnt_value;
    reg        seen_in, seen_out, seen_end, running;

    initial begin
        cyc = 0;  t_conv_in = -1;  t_conv_out = -1;  t_end = -1;  t_loop = -1;
        errcnt_writes = 0;  errcnt_nonzero = 0;  errcnt_value = 32'hxxxx_xxxx;
        seen_in = 0;  seen_out = 0;  seen_end = 0;  running = 0;
        repeat (20) @(posedge clk);
        rst_in = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst && !rst_in) running <= 1'b1;
        if (running) begin
            cyc = cyc + 1;
            if (!seen_in && pc == PC_CONV2D) begin
                seen_in = 1;  t_conv_in = cyc;
                $display("[IISC] cycle %0d: conv2d entered (PC = 0x9d0)", cyc);
            end
            if (seen_in && t_loop < 0 && pc == PC_OUTER) t_loop = cyc;
            if (seen_in && !seen_out && pc == PC_RETURN && cyc > t_conv_in + 20) begin
                seen_out = 1;  t_conv_out = cyc;
                $display("[IISC] cycle %0d: conv2d returned (PC = 0xe98)", cyc);
            end
            if (seen_out && !seen_end && pc == PC_END) begin
                seen_end = 1;  t_end = cyc;
                $display("[IISC] cycle %0d: main returned (PC = 0xec, final loop)", cyc);
            end
            ph = seen_out ? 2 : (seen_in ? 1 : 0);
            if (r_we)   n_we[ph]   = n_we[ph] + 1;
            if (r_miss) n_miss[ph] = n_miss[ph] + 1;
            if (r_en)   n_en[ph]   = n_en[ph] + 1;
            if (r_upd)  n_upd[ph]  = n_upd[ph] + 1;
            if (r_addr !== q_addr) n_addr[ph] = n_addr[ph] + 1;
            if (s_p12 !== q_p12 || s_p13 !== q_p13 || s_p15 !== q_p15 || s_p16 !== q_p16) n_std[ph] = n_std[ph] + 1;
            q_addr = r_addr;  q_p12 = s_p12;  q_p13 = s_p13;  q_p15 = s_p15;  q_p16 = s_p16;
            if (d_we)   dn_we[ph]   = dn_we[ph] + 1;
            if (d_miss) dn_miss[ph] = dn_miss[ph] + 1;
            if (d_en)   dn_en[ph]   = dn_en[ph] + 1;
            if (d_upd)  dn_upd[ph]  = dn_upd[ph] + 1;
            if (d_addr !== dq_addr) dn_addr[ph] = dn_addr[ph] + 1;
            if (d_p12 !== dq_p12 || d_p13 !== dq_p13 || d_p15 !== dq_p15 || d_p16 !== dq_p16) dn_std[ph] = dn_std[ph] + 1;
            dq_addr = d_addr;  dq_p12 = d_p12;  dq_p13 = d_p13;  dq_p15 = d_p15;  dq_p16 = d_p16;
            if (p_we && p_addr == A_ERRCNT) begin
                errcnt_writes = errcnt_writes + 1;
                errcnt_value  = p_din;
                if (p_din !== 32'd0) errcnt_nonzero = errcnt_nonzero + 1;
            end
            // read capture, only in main()'s check loop (after conv2d returned)
            if (seen_out && !seen_end) begin
                for (L = 0; L < 4; L = L + 1) begin
                    aL = (L == 0) ? p_addr : (L == 1) ? ah1 : (L == 2) ? ah2 : ah3;
                    if (aL >= A_Y && aL < A_Y + 4*n_out && aL[1:0] == 2'b00) begin
                        idx = L*MAXN + ((aL - A_Y) >> 2);  capY[idx] = p_dout;  hasY[idx] = 1;
                    end
                    if (aL >= A_EXP && aL < A_EXP + 4*n_out && aL[1:0] == 2'b00) begin
                        idx = L*MAXN + ((aL - A_EXP) >> 2);  capE[idx] = p_dout;  hasE[idx] = 1;
                    end
                end
            end
            ah3 = ah2;  ah2 = ah1;  ah1 = p_addr;
        end
    end

    // ---- report
    integer covE, matE, covY, exT, exG, mxT, mxG, bestL, bestM, ad;
    reg signed [31:0] df;
    always @(posedge clk) begin
        if (seen_end && cyc > t_end + 50) begin
            $display("");
            $display("  ------------- I2SRV32-V conv%0d_3, their design, their program -------------", img_size);
            $display("  outputs                            : %0d (%0dx%0dx%0d)", n_out, out_size, out_size, n_filt);
            $display("  reset release -> conv2d entry      : %0d cycles", t_conv_in);
            $display("  conv2d entry  -> conv2d return     : %0d cycles", t_conv_out - t_conv_in);
            $display("    of which entry -> OUTER_LOOP     : %0d cycles", t_loop - t_conv_in);
            $display("  reset release -> conv2d return     : %0d cycles", t_conv_out);
            $display("  reset release -> main returns      : %0d cycles", t_end);
            $display("  CPU writes to err_count            : %0d (non-zero values written: %0d), last value written = %0d",
                     errcnt_writes, errcnt_nonzero, errcnt_value);
            $display("  err_count == 0                     : %s", (errcnt_writes >= 1 && errcnt_value === 32'd0) ? "YES" : "NO");
            $display("  ITLB, cycles high / with a change  : before conv2d | inside conv2d window | after");
            $display("    replacement we   : %0d | %0d | %0d", n_we[0], n_we[1], n_we[2]);
            $display("    miss             : %0d | %0d | %0d", n_miss[0], n_miss[1], n_miss[2]);
            $display("    EVA_en           : %0d | %0d | %0d", n_en[0], n_en[1], n_en[2]);
            $display("    update_EVA       : %0d | %0d | %0d", n_upd[0], n_upd[1], n_upd[2]);
            $display("    EVA_addr changes : %0d | %0d | %0d", n_addr[0], n_addr[1], n_addr[2]);
            $display("    stand-in P output changes : %0d | %0d | %0d", n_std[0], n_std[1], n_std[2]);
            $display("  DTLB, cycles high / with a change  : before conv2d | inside conv2d window | after");
            $display("    DTLB replacement we   : %0d | %0d | %0d", dn_we[0], dn_we[1], dn_we[2]);
            $display("    DTLB miss             : %0d | %0d | %0d", dn_miss[0], dn_miss[1], dn_miss[2]);
            $display("    DTLB EVA_en           : %0d | %0d | %0d", dn_en[0], dn_en[1], dn_en[2]);
            $display("    DTLB update_EVA       : %0d | %0d | %0d", dn_upd[0], dn_upd[1], dn_upd[2]);
            $display("    DTLB EVA_addr changes : %0d | %0d | %0d", dn_addr[0], dn_addr[1], dn_addr[2]);
            $display("    DTLB stand-in P output changes : %0d | %0d | %0d", dn_std[0], dn_std[1], dn_std[2]);
            $display("  READ CAPTURE (latency L calibrated on expected_output[] reads):");
            bestL = -1;  bestM = -1;
            for (L = 0; L < 4; L = L + 1) begin
                covE = 0;  matE = 0;  covY = 0;  exT = 0;  exG = 0;  mxT = 0;  mxG = 0;
                for (kk = 0; kk < n_out; kk = kk + 1) begin
                    if (hasE[L*MAXN+kk]) begin
                        covE = covE + 1;
                        if (capE[L*MAXN+kk] === theirs[kk]) matE = matE + 1;
                    end
                    if (hasY[L*MAXN+kk]) begin
                        covY = covY + 1;
                        if (capY[L*MAXN+kk] === theirs[kk]) exT = exT + 1;
                        if (capY[L*MAXN+kk] === golden[kk]) exG = exG + 1;
                        df = $signed(capY[L*MAXN+kk]) - $signed(theirs[kk]);  ad = (df < 0) ? -df : df;
                        if (ad > mxT) mxT = ad;
                        df = $signed(capY[L*MAXN+kk]) - $signed(golden[kk]);  ad = (df < 0) ? -df : df;
                        if (ad > mxG) mxG = ad;
                    end
                end
                $display("    L=%0d: expected_output[] covered %0d/%0d, captured value == file %0d | Y covered %0d/%0d, exact vs THEIR expected %0d (max |diff| %0d), exact vs Python ref %0d (max |diff| %0d)",
                         L, covE, n_out, matE, covY, n_out, exT, mxT, exG, mxG);
                if (matE > bestM) begin bestM = matE; bestL = L; end
            end
            $display("  calibrated latency: L=%0d (%0d of %0d expected_output[] reads reproduce the file)", bestL, bestM, n_out);
            $display("  --------------------------------------------------------------------------");
            $finish;
        end
    end

    initial begin
        #(20 * 40_000_000);   // 40M core cycles
        $display("[IISC] TIMEOUT: seen_in=%b seen_out=%b seen_end=%b cyc=%0d pc=%h", seen_in, seen_out, seen_end, cyc, pc);
        $finish;
    end

    always @(posedge clk)
        if (running && (cyc % 500000 == 0) && cyc != 0)
            $display("[IISC] cycle %0d: pc = %h", cyc, pc);

endmodule
