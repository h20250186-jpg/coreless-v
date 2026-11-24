# NEW (2026-11-19, task H step 4). xsim batch script for atee_sc_tb built on a
# tree with THEIR DMEM_WE gating (e.g. sim_build_h/trees/min_vwe). During the
# layer-busy window it samples every cycle and reports each DMEM store that
# THEIR gate enables (DMEM_WE(i) = 1) while OUR gate (exe_unit hunks 14-16:
# dmw and not EXE_MEM_DONEs(i)) would not, i.e. EXE_MEM_DONEs(i) = 1: an
# "extra store", with the slot, its EXE_MEM element count and store address.
set TB /atee_sc_tb
set P  $TB/dut/u_vec_unit/wrapper_vhd/VECTOR_EXE_UNIT_PIPE
proc bits {sig} { return [string map {" " "" "\{" "" "\}" ""} [get_value -radix bin $sig]] }
add_condition -name busy1 "$TB/dut/cfg_layer_busy == 1" {stop}
run -all
remove_conditions busy1
run 10ns
set cyc 0; set nwe 0; set nextra 0; set kinds [dict create]
while {[get_value $TB/dut/cfg_layer_busy] eq "1"} {
    set we [bits $P/DMEM_WE]
    if {[string first 1 $we] >= 0} {
        set emd [bits $P/EXE_MEM_DONEs]; set din [bits $P/DONEs_internal]; set mwd [bits $P/MEM_WB_DONEs]
        for {set i 0} {$i < 8} {incr i} {
            if {[string index $we $i] ne "1"} continue
            incr nwe
            if {[string index $emd $i] eq "1"} {
                incr nextra
                set k [expr {[string index $din $i] eq "0" ? "slot counting (DONEs_internal=0)" : "MEM_WB busy (MEM_WB_DONEs=0)"}]
                dict incr kinds $k
                if {$nextra <= 30} {
                    puts [format "EXTRA cyc %5d slot %d count %2s addr %s | DONEs_internal %s EXE_MEM_DONEs %s MEM_WB_DONEs %s -> %s" \
                        $cyc $i [get_value -radix unsigned "$P/EXE_MEM_counts\[$i\]"] [get_value -radix hex "$P/EXE_MEM_LSU_y\[$i\]"] $din $emd $mwd $k]
                }
            }
        }
    }
    run 20ns
    incr cyc
}
puts "DWE_SUMMARY layer-busy cycles $cyc, slot store enables $nwe, extra (their gate only) $nextra"
dict for {k v} $kinds { puts "DWE_KIND $k : $v" }
run -all
quit
