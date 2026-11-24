# READ-ONLY check: what does each I2SRV32-V timing exception
# (scripts/iisc_timing_exceptions.xdc) match in the out-of-context `cpu` design?
# Opens the existing checkpoints of synth_build/iisc_ooc_both, applies nothing
# to any recorded run and writes no checkpoint.
#   Part 1: each exception VERBATIM (their paths are rooted at FPGA_WRAPPER).
#   Part 2: the same text with the "cpu1/" prefix removed (ANALYSIS ONLY: this
#           rebases their paths onto top `cpu`; it is an adjustment of their
#           constraints and is not used in any recorded run).
#   Part 3: what-if timing on the EXISTING routed checkpoint with the rebased
#           exceptions applied in memory (placement/routing unchanged).
# Usage: vivado -mode batch -source scripts/check_iisc_exceptions.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set xdc  [file join $root scripts iisc_timing_exceptions.xdc]
set out  [file join $root synth_build iisc_ooc_both exceptions_check]
file mkdir $out

set lines {}
set fh [open $xdc r]
while {[gets $fh l] >= 0} { if {[regexp {^\s*(set_false_path|set_multicycle_path|set\s+_xlnx)} $l]} { lappend lines $l } }
close $fh

# probe procs: Tcl evaluates the get_* arguments, the probe counts the objects
proc count_opts {argl} {
    set res {}
    for {set i 0} {$i < [llength $argl]} {incr i} {
        set a [lindex $argl $i]
        if {[lsearch {-from -to -through} $a] >= 0} {
            incr i
            lappend res "$a=[llength [lindex $argl $i]]"
        }
    }
    return $res
}
proc probe_fp {args} { return [count_opts $args] }
proc probe_mc {args} { return [count_opts $args] }

proc check {tag lines rebase} {
    set n 0; set eff 0
    foreach l $lines {
        if {$rebase} { set l [string map {cpu1/ {}} $l] }
        if {[regexp {^\s*set\s+(_xlnx_shared_i\d)} $l -> v]} {
            uplevel #0 [string map {get_pins {get_pins -quiet}} $l]
            puts "$tag VAR $v = [llength [set ::$v]] pins"
            continue
        }
        incr n
        set kind [expr {[string match *set_false_path* $l] ? "FP" : "MC"}]
        set cmd [string map {set_false_path probe_fp set_multicycle_path probe_mc get_pins {get_pins -quiet} get_cells {get_cells -quiet}} $l]
        set r [uplevel #0 $cmd]
        set ok 1
        foreach x $r { if {[string match *=0 $x]} { set ok 0 } }
        if {$ok} { incr eff }
        set short [string range [regsub -all {\s+} $l " "] 0 110]
        puts "$tag $kind #$n [expr {$ok ? {MATCHES} : {NO MATCH}}] {$r} :: $short"
    }
    puts "$tag SUMMARY $eff of $n exceptions have every -from/-to/-through list non-empty"
}

open_checkpoint [file join $root synth_build iisc_ooc_both post_route.dcp]
puts "CHK design top=[get_property TOP [current_design]]"
check VERBATIM $lines 0
check REBASED  $lines 1

# Part 3: what-if on the existing routed design (rebased exceptions, in memory)
set fh [open [file join $out rebased_exceptions.xdc] w]
foreach l $lines { puts $fh [string map {cpu1/ {}} $l] }
close $fh
puts "CHK BEFORE WNS = [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]"
read_xdc -unmanaged [file join $out rebased_exceptions.xdc]
report_timing_summary -max_paths 5 -file [file join $out whatif_rebased_timing_summary.rpt]
set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "CHK WHATIF WNS = [get_property SLACK $p] ns ; datapath [get_property DATAPATH_DELAY $p] ns ; levels [get_property LOGIC_LEVELS $p]"
puts "CHK WHATIF   from [get_property STARTPOINT_PIN $p]"
puts "CHK WHATIF   to   [get_property ENDPOINT_PIN $p]"
set h [get_timing_paths -max_paths 1 -nworst 1 -hold]
puts "CHK WHATIF WHS = [get_property SLACK $h] ns"
puts "CHK_DONE"
