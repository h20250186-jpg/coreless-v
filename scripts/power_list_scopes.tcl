set root [file normalize [file join [file dirname [info script]] ..]]
open_checkpoint [file join $root synth_build artix7_xc7a200tfbg676-2_nodiv_seqdiv clk_only post_route.dcp]
set fh [open [file join $root synth_build power_saif hier_cells.txt] w]
foreach c [lsort [get_cells -hier -filter {!IS_PRIMITIVE}]] { puts $fh $c }
close $fh
puts "HC [llength [get_cells -hier -filter {!IS_PRIMITIVE}]] hierarchical cells, [llength [get_nets -hier]] nets"
