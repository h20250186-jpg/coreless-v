# Per-cycle trace of exe_unit internals for convoy_4tap_tb (operands printed as SIGNED decimal).
# Samples at the falling clock edge (mid-cycle) while trace_en=1.
# Bit/array order is slot 0 first (leftmost).
#   clr      = I_clear on the wires this cycle
#   cnt      = per-slot element counters (RD stage)
#   act      = slots whose RD stage is processing an element this cycle
#   wb       = slots with an element in MEM_WB this cycle
#   VREG_WE  = per-VRF-bank write enable, MEMW = per-slot DMEM write enable
#   sN:(a,b,c) = EXE-stage ALU operands (op1,op2,op3) of slot N: MAC = c+a*b, ReLU = max(a,b), for the slots
#              selected by trace_slots
set TB /convoy_4tap_tb
set P  $TB/dut/wrapper_vhd/VECTOR_EXE_UNIT_PIPE

proc inv8 {hex} { return [format %02x [expr {(~[scan $hex %x]) & 0xff}]] }
proc ops {P s} {
    return [format "s%d:(%s,%s,%s)" $s [get_value -radix dec "$P/op1\[$s\]"] \
        [get_value -radix dec "$P/op2\[$s\]"] [get_value -radix dec "$P/op3\[$s\]"]]
}

while {[get_value $TB/sim_done] ne "1"} {
    run 20ns
    if {[get_value $TB/trace_print] eq "1"} {
        set mask [get_value -radix unsigned $TB/trace_slots]
        set o ""
        for {set s 0} {$s < 8} {incr s} {
            if {$mask & (1 << $s)} { append o [ops $P $s] " " }
        }
        puts [format "  t=%-9s id=%s st=%s clr=%s stall=%s | cnt=%-24s | act=%s wb=%s | VREG_WE=%s MEMW=%s | DONE=%s | %s" \
            [current_time] [get_value -radix unsigned $TB/I_id] [get_value $TB/I_start] \
            [get_value $TB/I_clear] [get_value $TB/stall_out] [get_value -radix unsigned $P/counts] \
            [inv8 [get_value $P/DONEs_internal]] [inv8 [get_value $P/MEM_WB_DONEs]] \
            [get_value $P/VREG_WE] [get_value $P/DMEM_WE] [get_value $TB/DONE_out] $o]
    }
}
run 100ns
quit
