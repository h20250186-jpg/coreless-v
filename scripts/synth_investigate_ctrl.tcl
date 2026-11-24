# Analysis only: what is the worst path of the divider-removed build made of,
# and which controller arithmetic is near-critical?
# Usage: vivado -mode batch -source scripts/synth_investigate_ctrl.tcl -tclargs <checkpoint dir>
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, not the Genesys 2 Kintex-7 part).
set root [file normalize [file join [file dirname [info script]] ..]]
set dir  [lindex $argv 0]
open_checkpoint [file join $root synth_build $dir post_route.dcp]

proc base {n} {
    regsub -all {\[[0-9]+\]} $n {[*]} n
    regsub -all {_i_[0-9]+(__[0-9]+)?} $n {_i_*} n
    regsub -all {__[0-9]+} $n {} n
    regsub -all {_psdsp(_[0-9]+)?} $n {_psdsp} n
    regsub -all {_replica(_[0-9]+)?} $n {} n
    return $n
}
proc hist {tag items {top 12}} {
    array unset h
    foreach i $items { incr h([base $i]) }
    set l {}
    foreach k [array names h] { lappend l [list $h($k) $k] }
    foreach e [lrange [lsort -integer -decreasing -index 0 $l] 0 [expr {$top-1}]] { puts "$tag   [lindex $e 0]  [lindex $e 1]" }
}

set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "CT worst path: slack [get_property SLACK $p] ns, datapath [get_property DATAPATH_DELAY $p] ns, levels [get_property LOGIC_LEVELS $p]"
puts "CT   from [get_property STARTPOINT_PIN $p]"
puts "CT   to   [get_property ENDPOINT_PIN $p]"
set cells [get_cells -of_objects $p]
puts "CT cells on the worst path: [llength $cells]; by instance: [llength [lsearch -all -glob $cells u_hbm_lite/*]] in u_hbm_lite, [llength [lsearch -all -glob $cells u_config/*]] in u_config, [llength [lsearch -all -glob $cells u_vec_unit/*]] in u_vec_unit"
puts "CT cell name groups on the worst path:"
hist CT $cells
puts "CT net name groups on the worst path:"
hist CT [get_nets -of_objects $p]

# failing endpoints grouped by register
set fail [get_timing_paths -quiet -max_paths 20000 -nworst 1 -setup -slack_lesser_than 0]
puts "CT failing setup endpoints: [llength $fail]"
array unset w; array unset c
foreach q $fail {
    set b [base [get_property NAME [get_cells -of_objects [get_property ENDPOINT_PIN $q]]]]
    incr c($b)
    set s [get_property SLACK $q]
    if {![info exists w($b)] || $s < $w($b)} { set w($b) $s }
}
set l {}
foreach k [array names c] { lappend l [list $w($k) $c($k) $k] }
puts "CT failing endpoint groups (worst slack, count, register), worst 25:"
foreach e [lrange [lsort -real -increasing -index 0 $l] 0 24] { puts "CT   [lindex $e 0]  [lindex $e 1]  [lindex $e 2]" }

# worst slack into the registers fed by each arithmetic operator of the controller
foreach {tag pat} {
    "output_h/output_w  ( .. / stride + 1 )"            {u_hbm_lite/output_[hw]_reg*}
    "input_plane_size   ( input_h * input_w )"          {u_hbm_lite/input_plane_size_reg*}
    "kernel_size        ( kernel_h * kernel_w )"        {u_hbm_lite/kernel_size_reg*}
    "taps_total         ( input_c * kernel_size )"      {u_hbm_lite/taps_total_reg*}
    "vec_RS1            ( comb_*_addr multiplies )"     {u_hbm_lite/vec_RS1_reg*}
    "oh_cnt / ow_cnt    ( last_pixel compares )"        {u_hbm_lite/o[hw]_cnt_reg*}
    "tensor_config_regs registers"                      {u_config/*_reg*}
} {
    set ep [get_cells -quiet -hier -regexp -filter "NAME =~ [string map {* .* [ \\[ ] \\]} $pat]"]
    if {![llength $ep]} { set ep [get_cells -quiet -hier -filter "NAME =~ $pat"] }
    if {![llength $ep]} { puts "CT to $tag : no such register cells in the netlist"; continue }
    set q [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -to $ep]
    if {[llength $q]} {
        puts "CT to $tag : [llength $ep] cells, worst slack [get_property SLACK $q] ns, datapath [get_property DATAPATH_DELAY $q] ns, levels [get_property LOGIC_LEVELS $q], from [get_property STARTPOINT_PIN $q]"
    } else { puts "CT to $tag : [llength $ep] cells, no timed path" }
}
puts "CT DSP48 in u_hbm_lite: [llength [get_cells -quiet -hier -filter {NAME =~ u_hbm_lite/* && REF_NAME == DSP48E1}]]"
puts "CT_DONE"
