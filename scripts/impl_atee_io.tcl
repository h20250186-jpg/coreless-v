# Re-implementation of the live design WITH I/O timing constraints, starting
# from the existing post-synthesis checkpoint (same netlist as the first run).
# Usage: vivado -mode batch -source scripts/impl_atee_io.tcl
# Part: xc7a200tfbg676-2 (Artix-7 stand-in, NOT the Genesys 2 Kintex-7 part).
#
# Constraints: 20.000 ns clock (already in the checkpoint) plus 5.000 ns
# (25% of the period) input delay on every input except clk and 5.000 ns output
# delay on every output. No divider exception: the divider is reachable from
# the top-level I_funct port, so no false path is applied.
set root [file normalize [file join [file dirname [info script]] ..]]
set base [file join $root synth_build artix7_xc7a200tfbg676-2]
set out  [file join $base io_constrained]
file mkdir $out
open_checkpoint [file join $base post_synth.dcp]

set xdc [file join $out io_delays.xdc]
set fh [open $xdc w]
puts $fh {set_input_delay  -clock clk 5.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
puts $fh {set_output_delay -clock clk 5.000 [get_ports -filter {DIRECTION == OUT}]}
close $fh
read_xdc $xdc
puts "IO_CONSTRAINED inputs=[llength [get_ports -filter {DIRECTION == IN && NAME != clk}]] outputs=[llength [get_ports -filter {DIRECTION == OUT}]]"

if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $out post_route_io.dcp]
    report_utilization -file [file join $out post_route_io_utilization.rpt]
    report_timing_summary -max_paths 5 -file [file join $out post_route_io_timing_summary.rpt]
    report_route_status -file [file join $out post_route_io_status.rpt]
    report_power -file [file join $out post_route_io_power.rpt]
    set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
    puts "IO_RESULT overall WNS = [get_property SLACK $p] ns from [get_property STARTPOINT_PIN $p] to [get_property ENDPOINT_PIN $p]"
    foreach {tag from to} {in2reg all_inputs all_registers reg2out all_registers all_outputs in2out all_inputs all_outputs reg2reg all_registers all_registers} {
        set q [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -from [$from] -to [$to]]
        if {[llength $q]} {
            puts "IO_RESULT $tag worst slack = [get_property SLACK $q] ns (datapath [get_property DATAPATH_DELAY $q] ns) from [get_property STARTPOINT_PIN $q] to [get_property ENDPOINT_PIN $q]"
        } else {
            puts "IO_RESULT $tag : no paths"
        }
    }
    puts "IO_IMPL_DONE"
} err]} {
    puts "IO_IMPL_FAILED: $err"
}
