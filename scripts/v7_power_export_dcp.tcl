# NEW (2026-11-19). Same as scripts/v7_power_export.tcl (unchanged), for any
# routed checkpoint: funcsim netlist (no timing annotation) + the list of
# hierarchical cells (as scripts/v7_power_hiercells.tcl). Vivado 2026.1.
# Read-only on the checkpoint.
# Usage: vivado -mode batch -source scripts/v7_power_export_dcp.tcl -tclargs <post_route.dcp> <netlist.v> <hier_cells.txt>
lassign $argv dcp net hier
open_checkpoint $dcp
write_verilog -mode funcsim -force $net
puts "PX top=[get_property TOP [current_design]] primitive cells=[llength [get_cells -hier -filter IS_PRIMITIVE]] hierarchical cells=[llength [get_cells -hier -filter {!IS_PRIMITIVE}]] nets=[llength [get_nets -hier]]"
set cells [lsort [get_property NAME [get_cells -hier -filter {!IS_PRIMITIVE}]]]
set fh [open $hier w]; foreach c $cells { puts $fh $c }; close $fh
puts "HC [llength $cells] hierarchical cells -> $hier"
puts "PX_DONE"
