# NEW (2026-11-14). Exports a functional-simulation netlist (no timing
# annotation) of a ROUTED Virtex-7 checkpoint (Runs 1-3, repo-build size),
# for SAIF-based power. Vivado 2026.1. Changes nothing in the checkpoint.
# Usage: vivado -mode batch -source scripts/v7_power_export.tcl -tclargs atee_vl16|atee_vl8|iisc
set root [file normalize [file join [file dirname [info script]] ..]]
set d [lindex $argv 0]
switch -- $d {
    atee_vl16 { set run atee_vl16 }
    atee_vl8  { set run atee_vl8 }
    iisc      { set run iisc_fpga_wrapper }
    default   { puts "PX ERROR: argument must be atee_vl16, atee_vl8 or iisc"; exit 1 }
}
set dcp [file join $root synth_build_2026 v7_xc7vx485t $run post_route.dcp]
set out [file join $root synth_build_2026 v7_power $d]
file mkdir $out
open_checkpoint $dcp
write_verilog -mode funcsim -force [file join $out ${d}_funcsim.v]
puts "PX $d top=[get_property TOP [current_design]] primitive cells=[llength [get_cells -hier -filter IS_PRIMITIVE]] hierarchical cells=[llength [get_cells -hier -filter {!IS_PRIMITIVE}]] nets=[llength [get_nets -hier]]"
puts "PX_DONE"
