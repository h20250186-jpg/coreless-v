# report_power on the routed design with the simulation activity recorded by
# testbench/power_saif.tcl. Run from scripts/run_power_saif.ps1.
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, not the Genesys 2 Kintex-7 part).
set root [file normalize [file join [file dirname [info script]] ..]]
set dir  [file join $root synth_build artix7_xc7a200tfbg676-2_nodiv_seqdiv clk_only]
set out  [file join $root synth_build power_saif]
open_checkpoint [file join $dir post_route.dcp]
puts "PW reading SAIF"
read_saif -strip_path atee_conv8_3_tb/dut [file join $out conv8_3_busy.saif]
report_power -file [file join $out post_route_power_saif.rpt]
report_power -hierarchical_depth 4 -file [file join $out post_route_power_saif_hier.rpt]
puts "PW_DONE"
