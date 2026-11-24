# Per-cycle trace of exe_unit internals for convoy_tb.
# Samples at the falling clock edge (mid-cycle) while trace_en=1.
# Bit/array order is slot 0 first (leftmost).
#   cnt      = per-slot element counters (RD stage)
#   act      = slots whose RD stage is processing an element this cycle (NOT DONEs_internal)
#   wb       = slots with an element in MEM_WB this cycle (NOT MEM_WB_DONEs)
#   VREG_WE  = per-VRF-bank write enable, MEMW = per-slot DMEM write enable
#   s2/s3    = EXE-stage ALU operands op1*op2+op3 of slot 2 / slot 3 (the MAC slot in V1 / V2)
set TB /convoy_tb
set P  $TB/dut/wrapper_vhd/VECTOR_EXE_UNIT_PIPE

proc inv8 {hex} { return [format %02x [expr {(~[scan $hex %x]) & 0xff}]] }
proc ops {P s} {
    return [format "%s*%s+%s" [get_value -radix unsigned "$P/op1\[$s\]"] \
        [get_value -radix unsigned "$P/op2\[$s\]"] [get_value -radix unsigned "$P/op3\[$s\]"]]
}

while {[get_value $TB/sim_done] ne "1"} {
    run 20ns
    if {[get_value $TB/trace_en] eq "1"} {
        puts [format "  t=%-8s id=%s st=%s stall=%s | cnt=%-22s | act=%s wb=%s | VREG_WE=%s MEMW=%s | s2:%-12s s3:%-12s | DONE=%s" \
            [current_time] [get_value -radix unsigned $TB/I_id] [get_value $TB/I_start] \
            [get_value $TB/stall_out] [get_value -radix unsigned $P/counts] \
            [inv8 [get_value $P/DONEs_internal]] [inv8 [get_value $P/MEM_WB_DONEs]] \
            [get_value $P/VREG_WE] [get_value $P/DMEM_WE] [ops $P 2] [ops $P 3] [get_value $TB/DONE_out]]
    }
}
run 100ns
quit
