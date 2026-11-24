# NEW (2026-11-19). xsim batch script (Vivado 2026.1) for the RTL-SAIF power run
# of THEIR cnn_demo (scripts/v7_rtlsaif_iisc_cnn.ps1, testbench
# external/iisc_sim/iisc_tb_bench26.v). The SAIF part is testbench/v7_rtlsaif.tcl
# (unchanged) with window iisc_conv: tb seen_in = 1 until seen_out = 1, which in
# iisc_tb_bench26 is conv2d entry -> layer3 return (the inference). After the
# window the run continues to the testbench's $stop, then the final DMEM and VRF
# contents are read as external/iisc_sim/iisc_bench_dump.tcl does (gate: compared
# with the 2019.1 run of the same image).
set TB /iisc_tb_bench26
proc is_open {} {
    global TB
    return [expr {[get_value $TB/seen_in] eq "1" && [get_value $TB/seen_out] ne "1"}]
}
set n 0
while {![is_open]} {
    run 20ns
    incr n
    if {$n > 3000000} { puts "RS ERROR: window never opened"; quit }
}
puts "RS window iisc_cnn opens at [current_time] (after $n steps of 20 ns)"
open_saif $::env(RS_FILE)
set all [get_objects -r $TB/dut/*]
set nfail 0
if {[catch {log_saif $all} e]} {
    puts "RS log_saif on the whole list failed ($e); logging one by one"
    set ok 0
    foreach o $all { if {[catch {log_saif $o}]} { incr nfail } else { incr ok } }
}
puts "RS logging [expr {[llength $all] - $nfail}] objects (get_objects -r below dut: [llength $all]; $nfail rejected by log_saif)"
set c 0
while {[is_open]} {
    run 20ns
    incr c
}
close_saif
puts "RS window iisc_cnn closes at [current_time]: $c steps of 20 ns"
run -all
puts "DUMP stopped at [current_time]"
set EU $TB/dut/cpu1/fdem/Pipeline/VECTOR_UNIT/VEC_EXE_UNIT/wrapper_vhd/VECTOR_EXE_UNIT_PIPE
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
quit
