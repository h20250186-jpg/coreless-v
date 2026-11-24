# NEW (2026-11-19). Per-layer SAIF files in ONE simulation run: a copy of
# testbench/v7_saif_cond.tcl (same logging, same condition-triggered edges)
# that, after CS_OPEN, records consecutive segments, each into its own SAIF:
# segment i runs from the end of segment i-1 (or CS_OPEN) to CS_SEG<i>, i = 1..n.
# Environment: as v7_saif_cond.tcl, plus
#   CS_NSEG   number of segments
#   CS_SEG1.. condition that ends segment i, e.g. {/atee_sc_tb/dut/cur_layer == 1}
#   CS_FILE   base name; segment i is written to <CS_FILE>_seg<i>.saif
# The object list is built once (before segment 1) and logged again into each file.
set dut $::env(CS_DUT)
set tstart [clock seconds]
add_condition -name cs_open $::env(CS_OPEN) {stop}
run -all
remove_conditions cs_open
puts "CS window opens at [current_time] ([expr {[clock seconds] - $tstart}] s wall)"
proc build_list {} {
    global dut
    set out {}
    if {$::env(CS_LOG) eq "netlist"} {
        set fh [open $::env(CS_HIER) r]; set want [dict create]
        while {[gets $fh l] >= 0} { set l [string trim $l]; if {$l ne ""} { dict set want $l 1 } }
        close $fh
        set queue [list [list $dut ""]]
        while {[llength $queue]} {
            lassign [lindex $queue 0] s rel; set queue [lrange $queue 1 end]
            current_scope $s
            set objs [get_objects -quiet *]
            set kids [get_scopes -quiet *]
            current_scope /
            if {[llength $objs]} { lappend out $objs }
            foreach k $kids {
                set leaf [string trimright [string trimleft [lindex [split [string range $k [string length $s] end] /] end] \\] " "]
                set krel [expr {$rel eq "" ? $leaf : "$rel/$leaf"}]
                if {[dict exists $want $krel]} { lappend queue [list $k $krel] }
            }
        }
    } else {
        set skip [expr {[info exists ::env(CS_SKIP)] ? $::env(CS_SKIP) : {^$}}]
        set keep {}
        foreach o [get_objects -r $dut/*] { if {![regexp -- $skip $o]} { lappend keep $o } }
        lappend out $keep
    }
    return $out
}
set groups [build_list]
set nobj 0; foreach g $groups { incr nobj [llength $g] }
puts "CS logging ($::env(CS_LOG)) $nobj objects in [llength $groups] group(s), into every segment file"
for {set i 1} {$i <= $::env(CS_NSEG)} {incr i} {
    set f "$::env(CS_FILE)_seg$i.saif"
    open_saif $f
    foreach g $groups { log_saif $g }
    set t0 [current_time]
    add_condition -name cs_seg $::env(CS_SEG$i) {stop}
    run -all
    remove_conditions cs_seg
    close_saif
    puts "CS segment $i -> $f : $t0 .. [current_time] ([expr {[clock seconds] - $tstart}] s wall)"
}
run -all
quit
