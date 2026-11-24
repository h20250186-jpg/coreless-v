# NEW (2026-11-13). READ-ONLY analysis of the routed Virtex-7 IISc checkpoint
# (synth_build_2026/v7_xc7vx485t/iisc_fpga_wrapper/post_route.dcp). Changes no
# constraint, placement or routing and writes no checkpoint. Reports where the
# failing endpoints of clk_out1 are, and the worst path outside their divider IP.
# Usage (2026.1): vivado -mode batch -source scripts/v7_iisc_analyze.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set d [file join $root synth_build_2026 v7_xc7vx485t iisc_fpga_wrapper]
open_checkpoint [file join $d post_route.dcp]
set paths [get_timing_paths -setup -group clk_out1_clk_wiz_0 -slack_lesser_than 0 -max_paths 100000 -nworst 1 -unique_pins]
puts "AN failing setup paths (1 per endpoint) in clk_out1: [llength $paths]"
set cat [dict create]
foreach p $paths {
    set e [get_property ENDPOINT_PIN $p]
    if {[string match *GEN_DIVIDERs* $e]} { set k divider_ip } \
    elseif {[string match *VECTOR_UNIT* $e]} { set k vector_unit_other } \
    elseif {[string match *FP_EX* $e] || [string match *Floating_point* $e]} { set k scalar_fpu } \
    else { set k scalar_other }
    dict incr cat $k
}
dict for {k v} $cat { puts "AN endpoints $k : $v" }
set nd [get_timing_paths -setup -group clk_out1_clk_wiz_0 -max_paths 1 -nworst 1 \
        -through [get_pins -hier -filter {NAME !~ *GEN_DIVIDERs*} -quiet] -to [get_cells -hier -filter {IS_SEQUENTIAL && NAME !~ *GEN_DIVIDERs*}]]
foreach p $nd {
    puts "AN worst path ending outside the divider IP: slack [get_property SLACK $p] ns, datapath [get_property DATAPATH_DELAY $p] ns, levels [get_property LOGIC_LEVELS $p]"
    puts "AN   from [get_property STARTPOINT_PIN $p]"
    puts "AN   to   [get_property ENDPOINT_PIN $p]"
}
report_timing -setup -group clk_out1_clk_wiz_0 -max_paths 1 -to [get_cells -hier -filter {IS_SEQUENTIAL && NAME !~ *GEN_DIVIDERs*}] -file [file join $d analysis_worst_non_divider_path.rpt]
puts "AN_DONE"
