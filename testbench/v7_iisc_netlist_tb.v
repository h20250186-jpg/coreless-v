`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: v7_iisc_netlist_tb
//
// NEW testbench (2026-11-14) for the Task B hybrid power flow: drives the
// ROUTED Virtex-7 FPGA_WRAPPER netlist of the I2SRV32-V design (Run 3,
// `write_verilog -mode funcsim` in 2026.1) in Vivado 2019.1 xsim, on THEIR
// conv8_3 program (xmem.coe compiled into mainMem). Derived from
// external/iisc_sim/iisc_tb_conv.v (unchanged), with the probes moved to
// names that exist in the netlist:
//   - clk_int, rst      : top-level nets of FPGA_WRAPPER (kept)
//   - pc                : net pc[29:0] of the Pipeline (IF_ID_EX) instance,
//                         taken as address bits [31:2] ({pc, 2'b00}); checked
//                         by reproducing the RTL entry cycle (816)
//   - outputs           : the processor-interface nets of the RTL testbench do
//                         not survive cross-boundary optimisation. Instead a
//                         SHADOW of every write into the 8 scratchpad banks is
//                         kept from the DMEM_0..7 IP ports (clka/wea/addra/dina,
//                         kept because the IPs are synthesised out of context).
//                         After main() returns, Y[0..n_out-1] and err_count are
//                         read from the shadow (row = addr[18:5], bank = addr[4:2],
//                         as cpu_inf.vhd / dmem_addr_xbar.vhd).
// Window flags for the SAIF script: win_conv (conv2d entry .. return) and
// win_all (reset release .. main returns).
//////////////////////////////////////////////////////////////////////////////////

module v7_iisc_netlist_tb;

    parameter MAXN = 4096;

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
    wire [31:0] pc   = {dut.cpu1.fdem.Pipeline.pc, 2'b00};

    localparam [31:0] PC_CONV2D = 32'h0000_09d0,
                      PC_RETURN = 32'h0000_0e98,
                      PC_END    = 32'h0000_00ec,
                      PC_OUTER  = 32'h0000_0a7c;

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

    // ---- shadow of the scratchpad writes (8 banks x 16K rows of the repo build)
    `define VP dut.cpu1.fdem.Pipeline.VECTOR_UNIT.VEC_EXE_UNIT.wrapper_vhd.VECTOR_EXE_UNIT_PIPE
    reg [31:0] sh [0:8*16384-1];
    reg        shv [0:8*16384-1];
    integer kk;
    initial for (kk = 0; kk < 8*16384; kk = kk + 1) shv[kk] = 1'b0;
    integer n_wr [0:7];
    initial for (kk = 0; kk < 8; kk = kk + 1) n_wr[kk] = 0;
    integer errcnt_writes;
    reg [31:0] errcnt_value;
    initial begin errcnt_writes = 0; errcnt_value = 32'hxxxx_xxxx; end
    wire [13:0] ERR_ROW  = A_ERRCNT[18:5];
    wire [2:0]  ERR_BANK = A_ERRCNT[4:2];
    always @(posedge `VP.DMEM0.clka) if (`VP.DMEM0.wea[0] === 1'b1) begin
        sh[0*16384 + `VP.DMEM0.addra] <= `VP.DMEM0.dina;  shv[0*16384 + `VP.DMEM0.addra] <= 1'b1;
        n_wr[0] = n_wr[0] + 1;
        if (ERR_BANK == 3'd0 && `VP.DMEM0.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM0.dina; end
    end
    always @(posedge `VP.DMEM1.clka) if (`VP.DMEM1.wea[0] === 1'b1) begin
        sh[1*16384 + `VP.DMEM1.addra] <= `VP.DMEM1.dina;  shv[1*16384 + `VP.DMEM1.addra] <= 1'b1;
        n_wr[1] = n_wr[1] + 1;
        if (ERR_BANK == 3'd1 && `VP.DMEM1.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM1.dina; end
    end
    always @(posedge `VP.DMEM2.clka) if (`VP.DMEM2.wea[0] === 1'b1) begin
        sh[2*16384 + `VP.DMEM2.addra] <= `VP.DMEM2.dina;  shv[2*16384 + `VP.DMEM2.addra] <= 1'b1;
        n_wr[2] = n_wr[2] + 1;
        if (ERR_BANK == 3'd2 && `VP.DMEM2.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM2.dina; end
    end
    always @(posedge `VP.DMEM3.clka) if (`VP.DMEM3.wea[0] === 1'b1) begin
        sh[3*16384 + `VP.DMEM3.addra] <= `VP.DMEM3.dina;  shv[3*16384 + `VP.DMEM3.addra] <= 1'b1;
        n_wr[3] = n_wr[3] + 1;
        if (ERR_BANK == 3'd3 && `VP.DMEM3.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM3.dina; end
    end
    always @(posedge `VP.DMEM4.clka) if (`VP.DMEM4.wea[0] === 1'b1) begin
        sh[4*16384 + `VP.DMEM4.addra] <= `VP.DMEM4.dina;  shv[4*16384 + `VP.DMEM4.addra] <= 1'b1;
        n_wr[4] = n_wr[4] + 1;
        if (ERR_BANK == 3'd4 && `VP.DMEM4.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM4.dina; end
    end
    always @(posedge `VP.DMEM5.clka) if (`VP.DMEM5.wea[0] === 1'b1) begin
        sh[5*16384 + `VP.DMEM5.addra] <= `VP.DMEM5.dina;  shv[5*16384 + `VP.DMEM5.addra] <= 1'b1;
        n_wr[5] = n_wr[5] + 1;
        if (ERR_BANK == 3'd5 && `VP.DMEM5.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM5.dina; end
    end
    always @(posedge `VP.DMEM6.clka) if (`VP.DMEM6.wea[0] === 1'b1) begin
        sh[6*16384 + `VP.DMEM6.addra] <= `VP.DMEM6.dina;  shv[6*16384 + `VP.DMEM6.addra] <= 1'b1;
        n_wr[6] = n_wr[6] + 1;
        if (ERR_BANK == 3'd6 && `VP.DMEM6.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM6.dina; end
    end
    always @(posedge `VP.DMEM7.clka) if (`VP.DMEM7.wea[0] === 1'b1) begin
        sh[7*16384 + `VP.DMEM7.addra] <= `VP.DMEM7.dina;  shv[7*16384 + `VP.DMEM7.addra] <= 1'b1;
        n_wr[7] = n_wr[7] + 1;
        if (ERR_BANK == 3'd7 && `VP.DMEM7.addra == ERR_ROW && running) begin errcnt_writes = errcnt_writes + 1; errcnt_value = `VP.DMEM7.dina; end
    end

    integer cyc, t_conv_in, t_conv_out, t_end, t_loop;
    reg     seen_in, seen_out, seen_end, running;
    reg     win_conv, win_all;
    initial begin
        cyc = 0;  t_conv_in = -1;  t_conv_out = -1;  t_end = -1;  t_loop = -1;
        seen_in = 0;  seen_out = 0;  seen_end = 0;  running = 0;  win_conv = 0;  win_all = 0;
        repeat (20) @(posedge clk);
        rst_in = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst && !rst_in) running <= 1'b1;
        if (running) begin
            cyc = cyc + 1;
            win_all = !seen_end;
            if (!seen_in && pc == PC_CONV2D) begin
                seen_in = 1;  t_conv_in = cyc;  win_conv = 1;
                $display("[IISC-NL] cycle %0d: conv2d entered (PC = 0x9d0)", cyc);
            end
            if (seen_in && t_loop < 0 && pc == PC_OUTER) t_loop = cyc;
            if (seen_in && !seen_out && pc == PC_RETURN && cyc > t_conv_in + 20) begin
                seen_out = 1;  t_conv_out = cyc;  win_conv = 0;
                $display("[IISC-NL] cycle %0d: conv2d returned (PC = 0xe98)", cyc);
            end
            if (seen_out && !seen_end && pc == PC_END) begin
                seen_end = 1;  t_end = cyc;  win_all = 0;
                $display("[IISC-NL] cycle %0d: main returned (PC = 0xec, final loop)", cyc);
            end
        end
    end

    integer exT, exG, cov, mxT, ad, a, b, r;
    reg signed [31:0] df;
    reg done_rep = 0;
    always @(posedge clk) begin
        if (seen_end && cyc > t_end + 50 && !done_rep) begin
            done_rep = 1;
            exT = 0; exG = 0; cov = 0; mxT = 0;
            for (kk = 0; kk < n_out; kk = kk + 1) begin
                a = A_Y + 4*kk;  b = (a >> 2) & 7;  r = (a >> 5) & 16'h3fff;
                if (shv[b*16384 + r]) cov = cov + 1;
                if (shv[b*16384 + r] && sh[b*16384 + r] === theirs[kk]) exT = exT + 1;
                if (shv[b*16384 + r] && sh[b*16384 + r] === golden[kk]) exG = exG + 1;
                df = $signed(sh[b*16384 + r]) - $signed(theirs[kk]);  ad = (df < 0) ? -df : df;
                if (ad > mxT) mxT = ad;
            end
            $display("");
            $display("  ------ I2SRV32-V conv%0d_3, ROUTED Virtex-7 NETLIST (2026.1), 2019.1 xsim ------", img_size);
            $display("  outputs                            : %0d (%0dx%0dx%0d)", n_out, out_size, out_size, n_filt);
            $display("  reset release -> conv2d entry      : %0d cycles", t_conv_in);
            $display("  conv2d entry  -> conv2d return     : %0d cycles", t_conv_out - t_conv_in);
            $display("    of which entry -> OUTER_LOOP     : %0d cycles", t_loop - t_conv_in);
            $display("  reset release -> main returns      : %0d cycles", t_end);
            $display("  scratchpad writes per bank         : %0d %0d %0d %0d %0d %0d %0d %0d", n_wr[0], n_wr[1], n_wr[2], n_wr[3], n_wr[4], n_wr[5], n_wr[6], n_wr[7]);
            $display("  writes to err_count                : %0d, last value written = %0d", errcnt_writes, errcnt_value);
            $display("  err_count == 0                     : %s", (errcnt_writes >= 1 && errcnt_value === 32'd0) ? "YES" : "NO");
            $display("  Y written (shadow)                 : %0d / %0d", cov, n_out);
            $display("  Y exact vs THEIR expected_output   : %0d / %0d (max |diff| %0d)", exT, n_out, mxT);
            $display("  Y exact vs Python reference        : %0d / %0d", exG, n_out);
            $display("  STATUS                             : %s", (exT == n_out && exG == n_out && errcnt_writes >= 1 && errcnt_value === 32'd0) ? "** PASS **" : "** FAIL **");
            $display("  -------------------------------------------------------------------------------");
            $finish;
        end
    end

    initial begin
        #(20 * 2_000_000);
        $display("[IISC-NL] TIMEOUT: seen_in=%b seen_out=%b seen_end=%b cyc=%0d pc=%h", seen_in, seen_out, seen_end, cyc, pc);
        $finish;
    end

    always @(posedge clk)
        if (running && (cyc % 5000 == 0) && cyc != 0)
            $display("[IISC-NL] cycle %0d: pc = %h", cyc, pc);

endmodule
