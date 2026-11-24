# NEW (2026-11-14). xsim batch script (Vivado 2019.1 xsim, Task B hybrid flow)
# recording SAIF of the ROUTED Virtex-7 I2SRV32-V netlist (testbench
# v7_iisc_netlist_tb). Logging as testbench/v7_power_saif_atee.tcl mode "new":
# every hierarchical cell listed by Vivado (SAIF_HIER), entered with current_scope.
#   SAIF_WIN  conv : conv2d() entry -> return (tb flag win_conv)
#             all  : reset release -> main returns (tb flag win_all)
#   SAIF_FILE output SAIF; SAIF_HIER hierarchical-cell list
set TB /v7_iisc_netlist_tb
set flag [expr {$::env(SAIF_WIN) eq "conv" ? "$TB/win_conv" : "$TB/win_all"}]
set n 0
while {[get_value $flag] ne "1"} {
    run 20ns
    incr n
    if {$n > 2000000} { puts "SAIF ERROR: window never opened"; quit }
}
puts "SAIF window ($::env(SAIF_WIN)) opens at [current_time]"
open_saif $::env(SAIF_FILE)
set fh [open $::env(SAIF_HIER) r]; set want [dict create]
while {[gets $fh l] >= 0} { set l [string trim $l]; if {$l ne ""} { dict set want $l 1 } }
close $fh
set queue [list [list $TB/dut ""]]
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
set miss {}
dict for {k v} $want { if {![dict exists $found $k]} { lappend miss $k } }
puts "SAIF logging $nobj nets/ports from $nscope scopes (dut + [expr {$nscope - 1}] of [dict size $want] hierarchical cells listed by Vivado; not found: [llength $miss])"
foreach m [lrange $miss 0 9] { puts "SAIF   not found: $m" }
set c 0
while {[get_value $flag] eq "1"} {
    run 20ns
    incr c
}
close_saif
puts "SAIF window ($::env(SAIF_WIN)) closes at [current_time]: $c steps of 20 ns"
run -all
quit
