`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: iisc_tb
//
// Runs the I2SRV32-V repo's OWN design (top = FPGA_WRAPPER) on its own conv8_3
// program image. Nothing from the Coreless-V project is in this build.
//
// Measured, in cycles of the 50 MHz core clock (clk_int):
//   - reset release -> first fetch of conv2d (0x9d0)
//   - conv2d entry  -> fetch of its return address in main (0xe98)
//   - reset release -> the `j .` loop after main returns (0xec)
// err_count (0x001014a0, in the vector scratchpad) is tracked from the CPU's
// own writes on the vector unit's processor interface.
//
// Speculative fetches: 0xe98 is the instruction after the `jal conv2d` and 0xec
// the one after `jal main`, so each is fetched once on the wrong path right
// after its call. A fetch is only counted once conv2d has been entered and at
// least 20 cycles have passed (0xe98), or after conv2d has returned (0xec).
//////////////////////////////////////////////////////////////////////////////////

module iisc_tb;

    reg clk_p = 1'b0;
    always #2.5 clk_p = ~clk_p;          // 200 MHz board clock (the clock model ignores it)

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

    // vector unit processor interface (scalar core <-> scratchpad / vector registers)
    wire [31:0] p_addr = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_addr;
    wire [31:0] p_din  = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_din;
    wire        p_we   = dut.cpu1.fdem.Pipeline.VECTOR_UNIT.proc_we;

    localparam [31:0] PC_CONV2D = 32'h0000_09d0,
                      PC_RETURN = 32'h0000_0e98,
                      PC_END    = 32'h0000_00ec,
                      A_ERRCNT  = 32'h0010_14a0,
                      A_Y_FIRST = 32'h0010_0b80,
                      A_Y_LAST  = 32'h0010_147c;

    // ---- ITLB replacement logic (the only place the assumed-function stand-ins
    // xbip_dsp48_macro_1/_2 are used; the data TLB is not instantiated) ----
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
    // [0] = before conv2d, [1] = inside the conv2d window, [2] = after it
    integer n_we [0:2], n_miss [0:2], n_en [0:2], n_upd [0:2], n_addr [0:2], n_std [0:2];
    integer ph, kk;
    initial for (kk = 0; kk < 3; kk = kk + 1) begin n_we[kk]=0; n_miss[kk]=0; n_en[kk]=0; n_upd[kk]=0; n_addr[kk]=0; n_std[kk]=0; end

    // ---- main memory port (ext_emulator em1 -> mainMem, byte addresses) ----
    wire        m_en   = ~dut.em1.ena;           // the instance is enabled when ena is low
    wire [3:0]  m_we   = dut.em1.wea;
    wire [31:0] m_addr = dut.em1.addra;
    integer m_acc = 0, m_wr = 0, m_hi_acc = 0, m_hi_wr = 0;      // counts; "hi" = at or above 0x40000
    reg [31:0] m_max = 0, m_wmax = 0, m_wmin = 32'hffff_ffff;    // highest access, highest / lowest write
    reg [31:0] m_lo_max = 0;                                    // highest access BELOW 0x40000
    reg [31:0] m_hi_min = 32'hffff_ffff;                        // lowest access at or above 0x40000
    always @(posedge clk) if (!rst && !rst_in && m_en) begin
        m_acc = m_acc + 1;
        if (m_addr > m_max) m_max = m_addr;
        if (m_addr >= 32'h0004_0000) begin
            m_hi_acc = m_hi_acc + 1;
            if (m_addr < m_hi_min) m_hi_min = m_addr;
        end else if (m_addr > m_lo_max) m_lo_max = m_addr;
        if (|m_we) begin
            m_wr = m_wr + 1;
            if (m_addr >= 32'h0004_0000) m_hi_wr = m_hi_wr + 1;
            if (m_addr > m_wmax) m_wmax = m_addr;
            if (m_addr < m_wmin) m_wmin = m_addr;
        end
    end

    // ---- stack pointer (x2 in the scalar register file) ----
    wire [31:0] sp_now = dut.cpu1.fdem.Pipeline.RF.MEM[2];
    reg  [31:0] sp_max = 0, sp_min = 32'hffff_ffff;
    always @(posedge clk) if (!rst && !rst_in && sp_now !== 32'd0 && ^sp_now !== 1'bx) begin
        if (sp_now > sp_max) sp_max = sp_now;
        if (sp_now < sp_min) sp_min = sp_now;
    end

    integer cyc;            // core clock cycles since reset release
    integer t_conv_in, t_conv_out, t_end;
    integer t_loop = -1;                       // first fetch of conv2d's OUTER_LOOP label
    localparam [31:0] PC_OUTER = 32'h0000_0a7c;
    integer errcnt_writes, y_writes;
    reg [31:0] errcnt_value;
    reg        seen_in, seen_out, seen_end, running;

    initial begin
        cyc = 0;  t_conv_in = -1;  t_conv_out = -1;  t_end = -1;
        errcnt_writes = 0;  y_writes = 0;  errcnt_value = 32'hxxxx_xxxx;
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
            if (seen_in && t_loop < 0 && pc == PC_OUTER) begin
                t_loop = cyc;
                $display("[IISC] cycle %0d: conv2d OUTER_LOOP first fetched (PC = 0xa7c)", cyc);
            end
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
            if (p_we && p_addr == A_ERRCNT) begin
                errcnt_writes = errcnt_writes + 1;
                errcnt_value  = p_din;
            end
            if (p_we && p_addr >= A_Y_FIRST && p_addr <= A_Y_LAST && seen_in && !seen_out)
                y_writes = y_writes + 1;
        end
    end

    // finish a little after the final loop is reached
    always @(posedge clk) begin
        if (seen_end && cyc > t_end + 50) begin
            $display("");
            $display("  ------------- I2SRV32-V conv8_3, their design, their program -------------");
            $display("  reset release -> conv2d entry      : %0d cycles", t_conv_in);
            $display("  conv2d entry  -> conv2d return     : %0d cycles", t_conv_out - t_conv_in);
            $display("    of which entry -> OUTER_LOOP     : %0d cycles (register saves, kernel/bias loads)", t_loop - t_conv_in);
            $display("    of which OUTER_LOOP -> return    : %0d cycles", t_conv_out - t_loop);
            $display("  reset release -> main returns      : %0d cycles", t_end);
            $display("  CPU writes to err_count            : %0d, last value written = %0d", errcnt_writes, errcnt_value);
            $display("  err_count == 0                     : %s", (errcnt_writes >= 1 && errcnt_value === 32'd0) ? "YES" : "NO");
            $display("  ITLB replacement logic, cycles with the signal high / cycles with a change:");
            $display("    phase            : before conv2d | inside conv2d window | after");
            $display("    replacement we   : %0d | %0d | %0d", n_we[0], n_we[1], n_we[2]);
            $display("    miss             : %0d | %0d | %0d", n_miss[0], n_miss[1], n_miss[2]);
            $display("    EVA_en           : %0d | %0d | %0d", n_en[0], n_en[1], n_en[2]);
            $display("    update_EVA       : %0d | %0d | %0d", n_upd[0], n_upd[1], n_upd[2]);
            $display("    EVA_addr changes : %0d | %0d | %0d", n_addr[0], n_addr[1], n_addr[2]);
            $display("    stand-in P output changes (macro_1 x2, macro_2 x2) : %0d | %0d | %0d", n_std[0], n_std[1], n_std[2]);
            $display("  stack pointer x2 (non-zero values) : highest 0x%08h, lowest 0x%08h", sp_max, sp_min);
            $display("  mainMem port, reset release -> 50 cycles after main returns (byte addresses):");
            $display("    enabled cycles                   : %0d, of which with write enable: %0d", m_acc, m_wr);
            $display("    highest address accessed         : 0x%08h (word index %0d of 262144)", m_max, m_max >> 2);
            $display("    highest / lowest address written : 0x%08h / 0x%08h", m_wmax, m_wmin);
            $display("    highest address below 0x40000    : 0x%08h", m_lo_max);
            $display("    accesses at or above 0x40000     : %0d (writes %0d), lowest such address 0x%08h", m_hi_acc, m_hi_wr, m_hi_min);
            $display("  --------------------------------------------------------------------------");
            $finish;
        end
    end

    initial begin
        #(20 * 20_000_000);   // 20M core cycles
        $display("[IISC] TIMEOUT: seen_in=%b seen_out=%b seen_end=%b cyc=%0d pc=%h", seen_in, seen_out, seen_end, cyc, pc);
        $finish;
    end

    // heartbeat
    always @(posedge clk)
        if (running && (cyc % 20000 == 0) && cyc != 0)
            $display("[IISC] cycle %0d: pc = %h", cyc, pc);

endmodule
