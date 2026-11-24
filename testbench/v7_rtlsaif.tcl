# NEW (2026-11-14). xsim batch script for the "RTL-SAIF" power method:
# behavioural RTL simulation, SAIF over the window, for read_saif onto the
# routed Virtex-7 checkpoint. Settings from environment variables:
#   RS_TB    testbench top (atee_conv_vl16_tb | atee_conv8_3_tb | iisc_tb_conv)
#   RS_WIN   atee      : dut/cfg_layer_busy high
#            iisc_conv : tb seen_in = 1 until seen_out = 1 (conv2d entry -> return)
#            iisc_all  : tb running = 1 until seen_end = 1 (reset release -> main returns)
#   RS_FILE  SAIF file
#   RS_SKIP  regex: objects whose full path matches are not logged (memory arrays)
#   RS_NODESCEND regex: scopes whose full path matches are logged (their own
#            objects, i.e. ports of an IP wrapper's core) but not descended into
# Logging: breadth-first over EVERY scope below dut, entered with current_scope
# (escaped / generate names resolve), get_objects * per scope.
set TB /$::env(RS_TB)
set win $::env(RS_WIN)
set skip [expr {[info exists ::env(RS_SKIP)] ? $::env(RS_SKIP) : {^$}}]
set nodesc [expr {[info exists ::env(RS_NODESCEND)] ? $::env(RS_NODESCEND) : {^$}}]
proc is_open {} {
    global TB win
    switch -- $win {
        atee      { return [expr {[get_value $TB/dut/cfg_layer_busy] eq "1"}] }
        iisc_conv { return [expr {[get_value $TB/seen_in] eq "1" && [get_value $TB/seen_out] ne "1"}] }
        iisc_all  { return [expr {[get_value $TB/running] eq "1" && [get_value $TB/seen_end] ne "1"}] }
    }
}
set n 0
while {![is_open]} {
    run 20ns
    incr n
    if {$n > 3000000} { puts "RS ERROR: window never opened"; quit }
}
puts "RS window $win opens at [current_time] (after $n steps of 20 ns)"
open_saif $::env(RS_FILE)
# Full DUT hierarchy, as the user specified: get_objects -r below dut. (A
# breadth-first walk with current_scope was tried first: it did not reach the
# VHDL generate scopes, 21 SAIF instances against 101 with -r.)
set all [get_objects -r $TB/dut/*]
set keep {}; set nskip 0
foreach o $all { if {[regexp -- $skip $o] || [regexp -- $nodesc $o]} { incr nskip } else { lappend keep $o } }
set nfail 0
if {[catch {log_saif $keep} e]} {
    puts "RS log_saif on the whole list failed ($e); logging one by one"
    set ok 0
    foreach o $keep { if {[catch {log_saif $o}]} { incr nfail } else { incr ok } }
    set keep [lrange $keep 0 [expr {$ok - 1}]]
}
puts "RS logging [expr {[llength $keep] - $nfail}] objects (get_objects -r below dut: [llength $all]; $nskip excluded by RS_SKIP/RS_NODESCEND; $nfail rejected by log_saif)"
set c 0
while {[is_open]} {
    run 20ns
    incr c
}
close_saif
puts "RS window $win closes at [current_time]: $c steps of 20 ns"
run -all
quit
