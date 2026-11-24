# NEW script (2026-11-11), a copy of scripts/synth_atee_ooc.tcl (unchanged) for the
# vl=16 design: atee_top_vl16 (hbm_lite_controller_vl16) and the controller alone.
# OUT-OF-CONTEXT synthesis (+ implementation) of Coreless-V blocks, for method
# consistency with the out-of-context runs of the I2SRV32-V blocks
# (scripts/synth_iisc_ooc.tcl). New script, derived from
# scripts/synth_atee_nodiv.tcl (that script is unchanged).
# Usage: vivado -mode batch -source scripts/synth_atee_vl16_ooc.tcl -tclargs <top>
#   <top> = atee_top_vl16 | hbm_lite_controller_vl16
#
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, NOT the Genesys 2 Kintex-7 part).
# Same generics as the final build: ENABLE_DIV=0 on the tops that have it
# (atee_top, v_wrapper); every other parameter at its RTL default
# (EARLY_CLEAR=1). The controller includes the sequential output-size divider
# (outsize_div). Clock constraint only (clk, 20.000 ns). No exceptions, no tuning.
set top [lindex $argv 0]
if {[lsearch {atee_top_vl16 hbm_lite_controller_vl16} $top] < 0} {
    puts "OOC usage: -tclargs atee_top_vl16|hbm_lite_controller_vl16"; exit 1
}
set root [file normalize [file join [file dirname [info script]] ..]]
set vu   [file join $root rtl vector_unit]
set base [file join $root synth_build atee_ooc_$top]
file mkdir $base
set part xc7a200tfbg676-2
set T "ATEE_OOC [string toupper $top]"

set vhdl {mypack alu count_gen lsu stall_gen dmem_bram dmem_addr_xbar vrf_bank
          div_gen_behav multicycle_ops vminmax xoutreg cpu_inf exe_unit wrapper}
set vlog {v_wrapper tensor_config_regs outsize_div hbm_lite_controller_vl16 atee_top_vl16}
foreach f $vhdl { read_vhdl -library xil_defaultlib [file join $vu $f.vhd] }
foreach f $vlog { read_verilog [file join $vu $f.v] }
set bad [lsearch -all -inline -regexp [get_files] {archive|dma_controller|CPU|cpu\.v|I2SRV32}]
puts "$T SOURCES [llength [get_files]] files; from archive / DMA / CPU / IISc: [llength $bad]"

set xdc [file join $base clock_50mhz.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period 20.000 \[get_ports clk\]"
close $fh
read_xdc -mode out_of_context $xdc

set gen {}
if {$top eq "atee_top_vl16"} { set gen {-generic ENABLE_DIV=0} }
if {[catch {synth_design -top $top -part $part -mode out_of_context {*}$gen} err]} {
    puts "$T SYNTH_FAILED: $err"
    exit
}
puts "$T SYNTH_DONE top=[get_property TOP [current_design]] part=[get_property PART [current_design]] generics={$gen}"
puts "$T black boxes: [llength [get_cells -quiet -hier -filter {IS_BLACKBOX}]]"
write_checkpoint -force [file join $base post_synth.dcp]
report_utilization              -file [file join $base post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $base post_synth_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $base post_synth_timing_summary.rpt]
set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "$T SYNTH WNS = [get_property SLACK $p] ns"
puts "$T SYNTH_REPORTS_WRITTEN"

# implementation, so the numbers can also be set beside the POST-ROUTE
# out-of-context figures of the I2SRV32-V blocks
if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $base post_route.dcp]
    report_utilization              -file [file join $base post_route_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 4 -file [file join $base post_route_utilization_hier.rpt]
    report_timing_summary -max_paths 5 -file [file join $base post_route_timing_summary.rpt]
    report_timing -max_paths 3 -nworst 1 -setup -file [file join $base post_route_worst_paths.rpt]
    report_route_status -file [file join $base post_route_status.rpt]
    set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
    puts "$T ROUTE WNS = [get_property SLACK $p] ns ; datapath [get_property DATAPATH_DELAY $p] ns ; levels [get_property LOGIC_LEVELS $p]"
    puts "$T ROUTE   from [get_property STARTPOINT_PIN $p]"
    puts "$T ROUTE   to   [get_property ENDPOINT_PIN $p]"
    puts "$T IMPL_DONE"
} err]} {
    puts "$T IMPL_FAILED: $err"
}
