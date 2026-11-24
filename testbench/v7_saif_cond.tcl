# NEW (2026-11-19). SAIF recording with the window opened and closed by xsim
# CONDITIONS (add_condition ... stop) instead of stepping the simulation 20 ns
# at a time from Tcl (testbench/v7_power_saif_atee.tcl, v7_rtlsaif.tcl,
# v7_rtlsaif_iisc_cnn.tcl: unchanged). Same objects logged, same window
# signals; the simulation runs at kernel speed between the two edges. The
# window then starts and ends at the delta where the signal changes instead of
# at the next 20 ns step (at most one cycle of difference at each edge).
# Validated on conv8_3 against the stepped scripts (RESULTS.md, "Main design ...
# item 2").
# Environment:
#   CS_OPEN   condition that opens the window, e.g. {/atee_sc_tb/dut/cfg_layer_busy == 1}
#   CS_CLOSE  condition that closes it,       e.g. {/atee_sc_tb/dut/cfg_layer_busy == 0}
#   CS_FILE   SAIF file
#   CS_LOG    netlist : every hierarchical cell of CS_HIER, entered with current_scope
#                       (as v7_power_saif_atee.tcl mode new)
#             rtl     : get_objects -r below CS_DUT, minus CS_SKIP (as v7_rtlsaif.tcl)
#   CS_DUT    full path of the DUT, e.g. /atee_sc_tb/dut
#   CS_HIER   (netlist) hierarchical cell list;  CS_SKIP (rtl) regex of excluded objects
#   CS_DUMP   optional: 1 = after the run, read DMEM / VRF of THEIR design as
#             v7_rtlsaif_iisc_cnn.tcl does (CS_EU = path of VECTOR_EXE_UNIT_PIPE)
set dut $::env(CS_DUT)
set tstart [clock seconds]
add_condition -name cs_open $::env(CS_OPEN) {stop}
run -all
remove_conditions cs_open
puts "CS window opens at [current_time] ([expr {[clock seconds] - $tstart}] s wall)"
open_saif $::env(CS_FILE)
if {$::env(CS_LOG) eq "netlist"} {
    set fh [open $::env(CS_HIER) r]; set want [dict create]
    while {[gets $fh l] >= 0} { set l [string trim $l]; if {$l ne ""} { dict set want $l 1 } }
    close $fh
    set queue [list [list $dut ""]]
    set nobj 0; set nscope 0; set found [dict create]
    while {[llength $queue]} {
        lassign [lindex $queue 0] s rel; set queue [lrange $queue 1 end]
        current_scope $s
        set objs [get_objects -quiet *]
        set kids [get_scopes -quiet *]
        current_scope /
        if {[llength $objs]} { log_saif $objs; incr nobj [llength $objs] }
        incr nscope
        if {$rel ne ""} { dict set found $rel 1 }
        foreach k $kids {
            set leaf [string trimright [string trimleft [lindex [split [string range $k [string length $s] end] /] end] \\] " "]
            set krel [expr {$rel eq "" ? $leaf : "$rel/$leaf"}]
            if {[dict exists $want $krel]} { lappend queue [list $k $krel] }
        }
    }
    set miss 0
    dict for {k v} $want { if {![dict exists $found $k]} { incr miss } }
    puts "CS logging (netlist) $nobj nets/ports from $nscope scopes (dut + [expr {$nscope - 1}] of [dict size $want] hierarchical cells; not found: $miss)"
} else {
    set skip [expr {[info exists ::env(CS_SKIP)] ? $::env(CS_SKIP) : {^$}}]
    set all [get_objects -r $dut/*]
    set keep {}; set nskip 0
    foreach o $all { if {[regexp -- $skip $o]} { incr nskip } else { lappend keep $o } }
    set nfail 0
    if {[catch {log_saif $keep} e]} {
        puts "CS log_saif on the whole list failed ($e); logging one by one"
        foreach o $keep { if {[catch {log_saif $o}]} { incr nfail } }
    }
    puts "CS logging (rtl) [expr {[llength $keep] - $nfail}] objects (get_objects -r below dut: [llength $all]; $nskip excluded by CS_SKIP; $nfail rejected)"
}
set t0 [current_time]
add_condition -name cs_close $::env(CS_CLOSE) {stop}
run -all
remove_conditions cs_close
close_saif
puts "CS window closes at [current_time] (opened at $t0; [expr {[clock seconds] - $tstart}] s wall since start)"
run -all
if {[info exists ::env(CS_DUMP)] && $::env(CS_DUMP) eq "1"} {
    set EU $::env(CS_EU)
    proc dumpval {obj fn} {
        set v [get_value -radix hex $obj]
        set f [open $fn w]
        foreach x [split [string map {"\{" " " "\}" " " "," " "} $v] " "] { if {$x ne ""} { puts $f $x } }
        close $f
    }
    if {[catch {
        set_property array_display_limit 65536 [current_sim]
        for {set b 0} {$b < 8} {incr b} {
            current_scope $EU/DMEM$b/inst
            current_scope [lindex [get_scopes] 0]
            dumpval memory "dmem_$b.txt"
        }
        puts "DUMP dmem written"
        set b 0
        foreach i {0 1 2 3 4 5 6 7} {
            current_scope $EU
            set s [lsearch -inline -all [get_scopes] "*GEN_VRFS($i)*"]
            current_scope [lindex $s 0]
            current_scope vrf_gen
            dumpval vec_reg "vrf_$b.txt"
            incr b
        }
        puts "DUMP vrf written ($b banks)"
    } e]} { puts "DUMP FAILED: $e" }
}
quit
