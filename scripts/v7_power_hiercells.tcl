# NEW (2026-11-14). Writes the names of all hierarchical (non-primitive) cells
# of a routed checkpoint, one per line, for testbench/v7_power_saif_*.tcl.
# Read-only on the checkpoint.
# Usage: vivado -mode batch -source scripts/v7_power_hiercells.tcl -tclargs <post_route.dcp> <out.txt>
lassign $argv dcp outf
open_checkpoint $dcp
set cells [lsort [get_property NAME [get_cells -hier -filter {!IS_PRIMITIVE}]]]
set fh [open $outf w]; foreach c $cells { puts $fh $c }; close $fh
puts "HC [llength $cells] hierarchical cells -> $outf"
puts "HC nets in design: [llength [get_nets -hier]]"
puts "HC_DONE"
