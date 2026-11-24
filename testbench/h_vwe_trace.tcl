# NEW (2026-11-19, task H step 4). xsim batch script for atee_sc_tb built on a
# tree with THEIR VREG_WE gating (sim_build_h/trees/min). During the layer-busy
# window it samples every cycle (falling edge) and reports each VRF bank write
# that THEIR gate enables but OUR gate (exe_unit hunks 17-19: write only while
# MEM_WB_DONEs(slot) = 0) would not: an "extra write".
# For bank i the routed slot is s = (8 - i + count_mem) mod 8, count_mem =
# MEM_WB_counts(0) mod 8 (their vreg_write_xbar). Read-only.
set TB /atee_sc_tb
set P  $TB/dut/u_vec_unit/wrapper_vhd/VECTOR_EXE_UNIT_PIPE
proc bits {sig} { return [string map {" " "" "\{" "" "\}" ""} [get_value -radix bin $sig]] }
proc arr {sig} { return [string map {"\{" "" "\}" ""} [get_value -radix unsigned $sig]] }
add_condition -name busy1 "$TB/dut/cfg_layer_busy == 1" {stop}
run -all
remove_conditions busy1
run 10ns
set cyc 0; set nwe 0; set nextra 0; set kinds [dict create]
while {[get_value $TB/dut/cfg_layer_busy] eq "1"} {
    set we [bits $P/VREG_WE]
    if {[string first 1 $we] >= 0} {
        set mwd [bits $P/MEM_WB_DONEs]; set din [bits $P/DONEs_internal]; set wbf [bits $P/WB_FIN_DONEs]
        set cnts {}; set vds {}; set dat {}
        for {set j 0} {$j < 8} {incr j} {
            lappend cnts [get_value -radix unsigned "$P/MEM_WB_counts\[$j\]"]
            lappend vds  [get_value -radix unsigned "$P/vd\[$j\]"]
            lappend dat  [get_value -radix hex "$P/REG_DATA_WR\[$j\]"]
        }
        set cm [expr {[lindex $cnts 0] % 8}]
        for {set i 0} {$i < 8} {incr i} {
            if {[string index $we $i] ne "1"} continue
            incr nwe
            set s [expr {(8 - $i + $cm) % 8}]
            if {[string index $mwd $s] eq "1"} {
                incr nextra
                set k [expr {[string index $din $s] eq "0" ? "slot counting (DONEs_internal=0)" : "WB_FIN busy (WB_FIN_DONEs=0)"}]
                dict incr kinds $k
                if {$nextra <= 40} {
                    puts [format "EXTRA cyc %5d bank %d slot %d vd %2s count(slot) %2s data %s | DONEs_internal %s MEM_WB_DONEs %s WB_FIN %s -> %s" \
                        $cyc $i $s [lindex $vds $i] [lindex $cnts $s] [lindex $dat $i] $din $mwd $wbf $k]
                }
            }
        }
    }
    run 20ns
    incr cyc
}
puts "VWE_SUMMARY layer-busy cycles $cyc, VRF bank writes enabled $nwe, extra (their gate only) $nextra"
dict for {k v} $kinds { puts "VWE_KIND $k : $v" }
run -all
quit
