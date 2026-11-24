# NEW script (2026-11-12). FULL-CHIP (not out-of-context) synthesis and
# implementation of the vl=16 design (atee_top_vl16 / hbm_lite_controller_vl16),
# clock constraint only, then export of the routed functional-simulation
# netlist for SAIF power. Same flow, part, generics and constraint as the
# vl=8 power build (scripts/synth_atee_nodiv.tcl run 1 "clk_only" +
# scripts/power_export_netlist.tcl); those scripts are unchanged.
# Usage: vivado -mode batch -source scripts/synth_atee_vl16_fullchip.tcl
#
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, NOT the Genesys 2 Kintex-7 part).
# ENABLE_DIV=0, every other parameter at its RTL default (EARLY_CLEAR=1).
# No timing exceptions, no tuning.
set root [file normalize [file join [file dirname [info script]] ..]]
set vu   [file join $root rtl vector_unit]
set base [file join $root synth_build artix7_xc7a200tfbg676-2_vl16]
set out  [file join $base clk_only]
set pw   [file join $root synth_build power_saif_vl16]
file mkdir $base
file mkdir $out
file mkdir $pw
set part xc7a200tfbg676-2
set top  atee_top_vl16
set T    "V16FC"

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
read_xdc $xdc

synth_design -top $top -part $part -generic ENABLE_DIV=0
puts "$T SYNTH_DONE top=[get_property TOP [current_design]] part=[get_property PART [current_design]]"
write_checkpoint -force [file join $base post_synth.dcp]
report_utilization -file [file join $base post_synth_utilization.rpt]
report_timing_summary -max_paths 5 -file [file join $base post_synth_timing_summary.rpt]

if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $out post_route.dcp]
    report_utilization              -file [file join $out post_route_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out post_route_utilization_hier.rpt]
    report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
    report_timing -max_paths 3 -nworst 1 -setup -file [file join $out post_route_worst_paths.rpt]
    report_route_status -file [file join $out post_route_status.rpt]
    report_power -file [file join $out post_route_power.rpt]
    set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
    puts "$T CLK WNS = [get_property SLACK $p] ns ; datapath [get_property DATAPATH_DELAY $p] ns ; levels [get_property LOGIC_LEVELS $p]"
    puts "$T CLK   from [get_property STARTPOINT_PIN $p]"
    puts "$T CLK   to   [get_property ENDPOINT_PIN $p]"
    set h [get_timing_paths -max_paths 1 -nworst 1 -hold]
    puts "$T CLK WHS = [get_property SLACK $h] ns"
    puts "$T CLK IMPL_DONE"
} err]} {
    puts "$T CLK IMPL_FAILED: $err"
    exit
}

write_verilog -mode funcsim -force [file join $pw atee_top_vl16_funcsim.v]
puts "$T NETLIST top=[get_property TOP [current_design]] cells=[llength [get_cells -hier -filter IS_PRIMITIVE]]"
puts "$T ALL_DONE"
