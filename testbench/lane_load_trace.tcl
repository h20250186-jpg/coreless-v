# Per-cycle trace of exe_unit internals for lane_load_tb.
# Samples at the falling clock edge (mid-cycle) while trace_en=1.
set TB /lane_load_tb
set P  $TB/dut/wrapper_vhd/VECTOR_EXE_UNIT_PIPE

proc gv {path} { return [get_value -radix unsigned $path] }

set cyc 0
while {[get_value $TB/sim_done] ne "1"} {
    run 20ns
    if {[get_value $TB/trace_en] eq "1"} {
        puts [format "  t=%s id=%s start=%s | counts=%s | DONEs=%s | MEM_WB_DONEs=%s | VREG_WE=%s | DONE=%s" \
            [current_time] [gv $TB/I_id] [gv $TB/I_start] \
            [gv $P/counts] [get_value $P/DONEs_internal] [get_value $P/MEM_WB_DONEs] \
            [get_value $P/VREG_WE] [get_value $TB/DONE_out]]
    }
}
run 100ns
quit
