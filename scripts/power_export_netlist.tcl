# Export a functional-simulation netlist of the ROUTED divider-removed,
# sequential-output-size-divider build, for SAIF-based power estimation.
# Usage: vivado -mode batch -source scripts/power_export_netlist.tcl
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, not the Genesys 2 Kintex-7 part).
set root [file normalize [file join [file dirname [info script]] ..]]
set dir  [file join $root synth_build artix7_xc7a200tfbg676-2_nodiv_seqdiv clk_only]
set out  [file join $root synth_build power_saif]
file mkdir $out
open_checkpoint [file join $dir post_route.dcp]
write_verilog -mode funcsim -force [file join $out atee_top_funcsim.v]
puts "PX top=[get_property TOP [current_design]] cells=[llength [get_cells -hier -filter IS_PRIMITIVE]]"
puts "PX nets named *layer_busy*: [get_nets -quiet -hier -filter {NAME =~ *layer_busy*}]"
puts "PX_DONE"
