# NEW (2026-11-14). EXPERIMENT, "paper configuration": Coreless-V vl=16 full
# chip with the vector scratchpad at 4K x 32 per bank (128 KB). Does NOT
# replace Run 1 (scripts/v7_impl_atee.tcl vl16).
# Sources: external_2026/atee_paper_cfg/vector_unit/ (copy of rtl/vector_unit
# with VMEM_ADDR_WIDTH / ADDR_WIDTH 14 -> 12 on 8 lines, see RESULTS.md).
# Settings as Run 1: xc7vx485tffg1761-2, Vivado 2026.1, 20 ns clock on clk
# only, no exceptions, ENABLE_DIV=0, checkpoints per stage.
# Usage (2026.1): vivado -mode batch -source scripts/v7_impl_atee_papercfg.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set vu   [file join $root external_2026 atee_paper_cfg vector_unit]
set top atee_top_vl16; set ctl hbm_lite_controller_vl16
set part xc7vx485tffg1761-2
set out  [file join $root synth_build_2026 v7_xc7vx485t atee_vl16_paper_cfg_experiment]
file mkdir $out
set T "V7AP"
set stagef [file join $out stage.txt]
proc stage_done {name} {
    global stagef T
    set fh [open $stagef a]; puts $fh "$name DONE [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"; close $fh
    puts "$T STAGE $name DONE"
}
set fh [open $stagef w]; puts $fh "START [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] version [version -short] part $part top $top (EXPERIMENT paper cfg)"; close $fh

set vhdl {mypack alu count_gen lsu stall_gen dmem_bram dmem_addr_xbar vrf_bank
          div_gen_behav multicycle_ops vminmax xoutreg cpu_inf exe_unit wrapper}
set vlog [list v_wrapper tensor_config_regs outsize_div $ctl $top]
foreach f $vhdl { read_vhdl -library xil_defaultlib [file join $vu $f.vhd] }
foreach f $vlog { read_verilog [file join $vu $f.v] }
puts "$T SOURCES [llength [get_files]] files, all from $vu: [expr {[llength [lsearch -all -inline -not -glob [get_files] $vu/*]] == 0}]"

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
set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "$T WNS = [get_property SLACK $p] ns ; datapath [get_property DATAPATH_DELAY $p] ns ; levels [get_property LOGIC_LEVELS $p]"
puts "$T   from [get_property STARTPOINT_PIN $p]"
puts "$T   to   [get_property ENDPOINT_PIN $p]"
set h [get_timing_paths -max_paths 1 -nworst 1 -hold]
puts "$T WHS = [get_property SLACK $h] ns"
stage_done reports
puts "$T ALL_DONE"
