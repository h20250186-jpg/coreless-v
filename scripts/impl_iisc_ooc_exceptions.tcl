# IMPLEMENTATION of the I2SRV32-V `cpu` (scalar + vector) out-of-context design
# WITH their own timing exceptions, re-rooted to this top
# (scripts/iisc_timing_exceptions_ooc.xdc: leading "cpu1/" removed, values
# unchanged, 23 of 34 active, 11 commented out as outside this scope).
# Starts from the SAME post-synthesis netlist as the 86,235-LUT run
# (synth_build/iisc_ooc_both/post_synth.dcp, produced by
# scripts/synth_iisc_ooc.tcl -tclargs both); same part, same top, same clocks
# (clk 20 ns, clk_x2 10 ns, saved in that checkpoint). The exceptions are read
# BEFORE opt/place/route, so implementation sees them. Nothing existing is
# modified; outputs go to synth_build/iisc_ooc_both_exceptions/.
# Usage: vivado -mode batch -source scripts/impl_iisc_ooc_exceptions.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set dcp  [file join $root synth_build iisc_ooc_both post_synth.dcp]
set xdc  [file join $root scripts iisc_timing_exceptions_ooc.xdc]
set out  [file join $root synth_build iisc_ooc_both_exceptions]
file mkdir $out
set T IISC_EXC

open_checkpoint $dcp
puts "$T design top=[get_property TOP [current_design]] part=[get_property PART [current_design]] from $dcp"
foreach c [get_clocks] { puts "$T clock [get_property NAME $c] period=[get_property PERIOD $c] source=[get_property SOURCE_PINS $c]" }

# ---- match check BEFORE applying: every -from/-to/-through list must be non-empty
proc count_opts {argl} {
    set res {}
    for {set i 0} {$i < [llength $argl]} {incr i} {
        set a [lindex $argl $i]
        if {[lsearch {-from -to -through} $a] >= 0} { incr i; lappend res "$a=[llength [lindex $argl $i]]" }
    }
    return $res
}
proc probe_fp {args} { return [count_opts $args] }
proc probe_mc {args} { return [count_opts $args] }
set fh [open $xdc r]; set n 0; set ok 0
while {[gets $fh l] >= 0} {
    if {[regexp {^\s*set\s+(_xlnx_shared_i\d)} $l -> v]} {
        uplevel #0 [string map {get_pins {get_pins -quiet}} $l]
        puts "$T VAR $v = [llength [set ::$v]] pins"; continue
    }
    if {![regexp {^\s*(set_false_path|set_multicycle_path)} $l]} continue
    incr n
    set r [uplevel #0 [string map {set_false_path probe_fp set_multicycle_path probe_mc get_pins {get_pins -quiet} get_cells {get_cells -quiet}} $l]]
    set m 1; foreach x $r { if {[string match *=0 $x]} { set m 0 } }
    if {$m} { incr ok }
    puts "$T CHECK #$n [expr {$m ? {MATCHES} : {NO MATCH}}] {$r} :: [string range [regsub -all {\s+} $l { }] 0 100]"
}
close $fh
puts "$T CHECK SUMMARY $ok of $n active exceptions match"

# ---- apply them for implementation
read_xdc $xdc
report_exceptions -file [file join $out exceptions_after_read.rpt]
report_exceptions -ignored -file [file join $out exceptions_ignored_after_read.rpt]

if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $out post_route.dcp]
    report_utilization              -file [file join $out post_route_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 4 -file [file join $out post_route_utilization_hier.rpt]
    report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
    report_timing -max_paths 3 -nworst 1 -setup -file [file join $out post_route_worst_paths.rpt]
    report_route_status -file [file join $out post_route_status.rpt]
    report_exceptions -file [file join $out exceptions_post_route.rpt]
    report_exceptions -ignored -file [file join $out exceptions_ignored_post_route.rpt]
    foreach g {clk clk_x2} {
        set p [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -group $g]
        if {[llength $p]} {
            puts "$T SETUP $g WNS = [get_property SLACK $p] ns ; datapath [get_property DATAPATH_DELAY $p] ns ; levels [get_property LOGIC_LEVELS $p]"
            puts "$T SETUP $g   from [get_property STARTPOINT_PIN $p]"
            puts "$T SETUP $g   to   [get_property ENDPOINT_PIN $p]"
        }
        set h [get_timing_paths -quiet -max_paths 1 -nworst 1 -hold -group $g]
        if {[llength $h]} { puts "$T HOLD $g WHS = [get_property SLACK $h] ns" }
    }
    puts "$T IMPL_DONE"
} err]} {
    puts "$T IMPL_FAILED: $err"
}
