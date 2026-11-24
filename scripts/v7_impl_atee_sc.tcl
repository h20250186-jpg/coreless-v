# NEW (2026-11-17, scalar-operand variant). Virtex-7 XC7VX485T full-chip
# implementation of atee_top_sc (hbm_lite_controller_sc + ibuf_ram), Vivado 2026.1.
# A COPY of scripts/v7_impl_atee_cnn.tcl (unchanged); only top, controller and
# the added ibuf_ram source differ.
# A COPY of scripts/v7_impl_atee.tcl (Run 1 / Run 2, unchanged) with the same
# settings: part xc7vx485tffg1761-2, 20 ns clock on port clk only, no I/O
# delays, no timing exceptions, ENABLE_DIV=0, default directives, a checkpoint
# after every stage. Only the top and controller files differ (no outsize_div:
# the CNN controller has no output-size divider).
# Usage (2026.1): vivado -mode batch -source scripts/v7_impl_atee_cnn.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set vu   [file join $root rtl vector_unit]
set top  atee_top_sc
set ctl  hbm_lite_controller_sc
set part xc7vx485tffg1761-2
set out  [file join $root synth_build_2026 v7_xc7vx485t atee_sc]
file mkdir $out
set T "V7A_sc"
set stagef [file join $out stage.txt]
proc stage_done {name} {
    global stagef T
    set fh [open $stagef a]; puts $fh "$name DONE [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"; close $fh
    puts "$T STAGE $name DONE"
}
set fh [open $stagef w]; puts $fh "START [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] version [version -short] part $part top $top"; close $fh
puts "$T version [version -short] part $part top $top"

set vhdl {mypack alu count_gen lsu stall_gen dmem_bram dmem_addr_xbar vrf_bank
          div_gen_behav multicycle_ops vminmax xoutreg cpu_inf exe_unit wrapper}
set vlog [list v_wrapper tensor_config_regs ibuf_ram $ctl $top]
foreach f $vhdl { read_vhdl -library xil_defaultlib [file join $vu $f.vhd] }
foreach f $vlog { read_verilog [file join $vu $f.v] }
set bad [lsearch -all -inline -regexp [get_files] {archive|dma_controller|CPU|cpu\.v|I2SRV32}]
puts "$T SOURCES [llength [get_files]] files; from archive / DMA / CPU / IISc: [llength $bad]"

set xdc [file join $out clock_50mhz.xdc]
set fh [open $xdc w]; puts $fh "create_clock -name clk -period 20.000 \[get_ports clk\]"; close $fh
read_xdc $xdc

proc stage {name body} {
    global out T
    if {[catch {uplevel 1 $body} err]} {
        puts "$T STAGE $name FAILED: $err"
        set fh [open [file join $out stage.txt] a]; puts $fh "$name FAILED: [lindex [split $err \n] 0]"; close $fh
        exit 1
    }
    write_checkpoint -force [file join $out post_$name.dcp]
    stage_done $name
}

stage synth { synth_design -top $top -part $part -generic ENABLE_DIV=0 }
report_utilization -file [file join $out post_synth_utilization.rpt]
stage opt      { opt_design }
stage place    { place_design }
stage phys_opt { phys_opt_design }
stage route    { route_design }

report_utilization -file [file join $out post_route_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out post_route_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
report_timing -max_paths 3 -nworst 1 -setup -file [file join $out post_route_worst_paths.rpt]
report_route_status -file [file join $out post_route_status.rpt]
report_clock_utilization -file [file join $out post_route_clock_utilization.rpt]
set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "$T WNS = [get_property SLACK $p] ns ; datapath [get_property DATAPATH_DELAY $p] ns ; levels [get_property LOGIC_LEVELS $p]"
puts "$T   from [get_property STARTPOINT_PIN $p]"
puts "$T   to   [get_property ENDPOINT_PIN $p]"
set h [get_timing_paths -max_paths 1 -nworst 1 -hold]
puts "$T WHS = [get_property SLACK $h] ns"
stage_done reports
puts "$T ALL_DONE"
