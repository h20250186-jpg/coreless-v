# NEW (2026-11-12), a copy of scripts/power_report_saif.tcl (unchanged) for
# the vl=16 design. report_power on the routed full-chip atee_top_vl16 with
# the activity recorded by testbench/power_saif_vl16.tcl.
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, not the Genesys 2 Kintex-7 part).
set root [file normalize [file join [file dirname [info script]] ..]]
set dir  [file join $root synth_build artix7_xc7a200tfbg676-2_vl16 clk_only]
set out  [file join $root synth_build power_saif_vl16]
open_checkpoint [file join $dir post_route.dcp]
puts "PW reading SAIF"
read_saif -strip_path atee_conv_vl16_tb/dut [file join $out conv8_3_vl16_busy.saif]
report_power -file [file join $out post_route_power_saif.rpt]
report_power -hierarchical_depth 4 -file [file join $out post_route_power_saif_hier.rpt]
puts "PW_DONE"
