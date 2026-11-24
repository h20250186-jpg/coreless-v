# Analysis-only session on the routed checkpoint (no re-synthesis, no re-route).
# Usage: vivado -mode batch -source scripts/synth_investigate.tcl
# Part: xc7a200tfbg676-2 (Artix-7 stand-in, NOT the Genesys 2 Kintex-7 part).
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root synth_build artix7_xc7a200tfbg676-2]
open_checkpoint [file join $out post_route.dcp]

# ------------------------------------------------------------------ INV 1
puts "INV1 ==== where are the LUTs ===="
set lutf {REF_NAME =~ LUT* || REF_NAME =~ SRL*}
set all_luts [get_cells -hier -filter $lutf]
puts "INV1 all LUT/SRL primitive cells in design      : [llength $all_luts]"
puts "INV1 top-level cells (hierarchical instances)   : [get_cells -filter {!IS_PRIMITIVE}]"
puts "INV1 top-level PRIMITIVE cells (not in any inst): [llength [get_cells -filter {IS_PRIMITIVE}]]"
set top_luts [get_cells -filter "IS_PRIMITIVE && ($lutf)"]
puts "INV1 top-level LUT/SRL primitives               : [llength $top_luts]"
foreach inst {u_config u_hbm_lite u_vec_unit} {
    puts "INV1 LUT/SRL primitives under $inst : [llength [get_cells -hier -filter "NAME =~ $inst/* && ($lutf)"]]"
}
# histogram of top-level primitive types
array unset h
foreach c [get_cells -filter {IS_PRIMITIVE}] { incr h([get_property REF_NAME $c]) }
foreach k [lsort [array names h]] { puts "INV1 top-level primitive $k : $h($k)" }
# name histogram of top-level LUTs (strip indices and trailing synthesis suffixes)
array unset n
foreach c $top_luts {
    set b [get_property NAME $c]
    regsub -all {\[[0-9]+\]} $b {[*]} b
    regsub -all {_i_[0-9]+(__[0-9]+)?$} $b {_i_*} b
    regsub -all {__[0-9]+} $b {} b
    regsub -all {[0-9]+} $b {#} b
    incr n($b)
}
set pairs {}
foreach k [array names n] { lappend pairs [list $n($k) $k] }
set pairs [lsort -integer -decreasing -index 0 $pairs]
puts "INV1 top-level LUT name groups (count name), largest 40 of [llength $pairs]:"
foreach p [lrange $pairs 0 39] { puts "INV1   [lindex $p 0]  [lindex $p 1]" }
# what do the top-level LUTs connect to: count those whose output net loads sit under each instance
array unset d
foreach c [lrange $top_luts 0 1999] {
    set loads [get_cells -quiet -of [get_pins -quiet -leaf -of [get_nets -quiet -of [get_pins -quiet -of $c -filter {DIRECTION == OUT}]] -filter {DIRECTION == IN}]]
    set where top
    foreach l $loads { set nm [get_property NAME $l]; if {[string match */* $nm]} { set where [lindex [split $nm /] 0]; break } }
    incr d($where)
}
foreach k [array names d] { puts "INV1 first 2000 top-level LUTs: first load is under '$k' : $d($k)" }
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out post_route_utilization_hier_depth8.rpt]
puts "INV1 synth flatten setting used: synth_design default (-flatten_hierarchy rebuilt)"

# ------------------------------------------------------------------ INV 2
puts "INV2 ==== timing with and without the divider registers ===="
proc worst {tag} {
    set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
    puts "INV2 $tag WNS = [get_property SLACK $p] ns ; datapath = [get_property DATAPATH_DELAY $p] ns ; levels = [get_property LOGIC_LEVELS $p]"
    puts "INV2 $tag   from [get_property STARTPOINT_PIN $p]"
    puts "INV2 $tag   to   [get_property ENDPOINT_PIN $p]"
}
worst "AS-IS (clock constraint only)"
set divregs [get_cells -hier -filter {NAME =~ *GEN_DIVIDERs*/* && IS_SEQUENTIAL}]
puts "INV2 sequential cells inside GEN_DIVIDERs\[*\] : [llength $divregs]"
puts "INV2 failing setup endpoints as-is : [llength [get_timing_paths -quiet -max_paths 100000 -nworst 1 -setup -slack_lesser_than 0]]"
# WHAT-IF ONLY (in memory, not written to any XDC): ignore paths that start or
# end at a register inside the dividers.
set_false_path -from $divregs
set_false_path -to   $divregs
worst "WHAT-IF (divider registers excluded)"
set fail [get_timing_paths -quiet -max_paths 100000 -nworst 1 -setup -slack_lesser_than 0]
puts "INV2 WHAT-IF failing setup endpoints : [llength $fail]"
report_timing_summary -max_paths 3 -file [file join $out whatif_no_divider_timing_summary.rpt]
report_timing -max_paths 3 -nworst 1 -setup -file [file join $out whatif_no_divider_worst_paths.rpt]
puts "INVESTIGATE_DONE"
