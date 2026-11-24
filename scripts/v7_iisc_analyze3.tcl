# NEW (2026-11-14). READ-ONLY follow-up to v7_iisc_analyze2.tcl on the routed
# Virtex-7 IISc checkpoint. Writes no checkpoint, changes nothing.
#  1. DMEM block-RAM primitives per bank: count, type, width, cascade use
#  2. LUT primitives directly in exe_unit (not in a child instance), grouped
#     by the RTL signal/instance name they carry (crossbars, LSUs, ...)
# Usage (2026.1): vivado -mode batch -source scripts/v7_iisc_analyze3.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set d [file join $root synth_build_2026 v7_xc7vx485t iisc_fpga_wrapper]
open_checkpoint [file join $d post_route.dcp]
set P cpu1/fdem/Pipeline/VECTOR_UNIT/VEC_EXE_UNIT/wrapper_vhd/VECTOR_EXE_UNIT_PIPE

puts "A3 primitive groups present: [lsort -unique [get_property PRIMITIVE_GROUP [get_cells -hier -filter {IS_PRIMITIVE && REF_NAME =~ RAMB*}]]]"
for {set b 0} {$b < 8} {incr b} {
    set prims [get_cells -hier -filter "REF_NAME =~ RAMB* && NAME =~ $P/DMEM$b/*"]
    set desc {}
    set casc 0
    foreach p $prims {
        lappend desc "[get_property REF_NAME $p]:RW_A=[get_property READ_WIDTH_A $p]:EXT_A=[get_property -quiet RAM_EXTENSION_A $p]"
        foreach pin [get_pins -quiet -of_objects $p -filter {REF_PIN_NAME =~ CASCADEOUT* || REF_PIN_NAME =~ CASCADEIN*}] {
            set n [get_nets -quiet -of_objects $pin]
            if {[llength $n] && [get_property TYPE $n] ne "GROUND" && [get_property TYPE $n] ne "POWER"} { incr casc }
        }
    }
    set s {}
    foreach x [lsort -unique $desc] { lappend s "[llength [lsearch -all -exact $desc $x]]x $x" }
    puts "A3 DMEM$b block-RAM primitives [llength $prims] : [join $s {, }] ; connected cascade pins $casc"
}

# LUT primitives owned directly by exe_unit, keyed by the leading name token
set own {}
foreach c [get_cells -hier -filter "PRIMITIVE_GROUP == LUT && NAME =~ $P/*"] {
    set n [get_property NAME $c]
    set rest [string range $n [expr {[string length $P] + 1}] end]
    if {[llength [split $rest /]] == 1} { lappend own $rest }
}
puts "A3 LUT primitives owned directly by exe_unit: [llength $own]"
set cnt [dict create]
foreach n $own {
    regsub {(_i_\d+.*|_i__\d+.*|\[.*|__\d+.*|_\d+$)} $n {} k
    dict incr cnt $k
}
set fh [open [file join $d analysis3_exe_unit_own_luts.txt] w]
foreach {k v} [lsort -stride 2 -index 1 -integer -decreasing [dict get $cnt]] { puts $fh [format "%-50s %6d" $k $v] }
close $fh
set i 0
foreach {k v} [lsort -stride 2 -index 1 -integer -decreasing [dict get $cnt]] { if {[incr i] > 25} break; puts "A3 OWN $k $v" }
puts "A3_DONE"
