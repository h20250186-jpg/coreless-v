# Divider-removed variant (atee_top generic ENABLE_DIV=0): synthesis, then two
# implementations of the same netlist: (1) clock constraint only, (2) clock +
# 5.000 ns input/output delays. Same flow and part as scripts/synth_atee.tcl.
# Usage: vivado -mode batch -source scripts/synth_atee_nodiv.tcl
#
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN, NOT the Genesys 2 Kintex-7 part).
# No timing exceptions, no tuning.
set root [file normalize [file join [file dirname [info script]] ..]]
set vu   [file join $root rtl vector_unit]
# optional -tclargs <suffix> keeps the reports of different RTL revisions apart
set base [file join $root synth_build artix7_xc7a200tfbg676-2_nodiv[lindex $argv 0]]
file mkdir $base
set part xc7a200tfbg676-2
set top  atee_top

set vhdl {mypack alu count_gen lsu stall_gen dmem_bram dmem_addr_xbar vrf_bank
          div_gen_behav multicycle_ops vminmax xoutreg cpu_inf exe_unit wrapper}
set vlog {v_wrapper tensor_config_regs outsize_div hbm_lite_controller atee_top}
foreach f $vhdl { read_vhdl -library xil_defaultlib [file join $vu $f.vhd] }
foreach f $vlog { read_verilog [file join $vu $f.v] }
set bad [lsearch -all -inline -regexp [get_files] {archive|dma_controller|CPU|cpu\.v}]
puts "ND SOURCES [llength [get_files]] files; from archive / DMA / CPU: [llength $bad]"

set xdc [file join $base clock_50mhz.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period 20.000 \[get_ports clk\]"
close $fh
read_xdc $xdc

synth_design -top $top -part $part -generic ENABLE_DIV=0
puts "ND SYNTH_DONE top=[get_property TOP [current_design]] part=[get_property PART [current_design]]"
puts "ND cells with 'divider' or 'GEN_DIVIDERs' in the name: [llength [get_cells -quiet -hier -filter {NAME =~ *divider* || NAME =~ *GEN_DIVIDERs*}]]"
puts "ND SRL primitives: [llength [get_cells -quiet -hier -filter {REF_NAME =~ SRL*}]]"
write_checkpoint -force [file join $base post_synth.dcp]
report_utilization -file [file join $base post_synth_utilization.rpt]
report_timing_summary -max_paths 5 -file [file join $base post_synth_timing_summary.rpt]
puts "ND SYNTH_REPORTS_WRITTEN"

proc implement {tag out} {
    file mkdir $out
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
        puts "ND $tag overall WNS = [get_property SLACK $p] ns ; datapath [get_property DATAPATH_DELAY $p] ns ; levels [get_property LOGIC_LEVELS $p]"
        puts "ND $tag   from [get_property STARTPOINT_PIN $p]"
        puts "ND $tag   to   [get_property ENDPOINT_PIN $p]"
        foreach {cls from to} {in2reg all_inputs all_registers reg2out all_registers all_outputs in2out all_inputs all_outputs reg2reg all_registers all_registers} {
            set q [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -from [$from] -to [$to]]
            if {[llength $q]} {
                puts "ND $tag $cls worst slack = [get_property SLACK $q] ns (datapath [get_property DATAPATH_DELAY $q] ns) from [get_property STARTPOINT_PIN $q] to [get_property ENDPOINT_PIN $q]"
            } else {
                puts "ND $tag $cls : no constrained paths"
            }
        }
        puts "ND $tag top-level LUT primitives: [llength [get_cells -quiet -filter {IS_PRIMITIVE && REF_NAME =~ LUT*}]]"
        puts "ND $tag IMPL_DONE"
    } err]} {
        puts "ND $tag IMPL_FAILED: $err"
    }
}

# ---- run 1: clock constraint only
implement CLK [file join $base clk_only]
close_design

# ---- run 2: clock + I/O delays, same post-synthesis netlist
open_checkpoint [file join $base post_synth.dcp]
set ioxdc [file join $base io_delays.xdc]
set fh [open $ioxdc w]
puts $fh {set_input_delay  -clock clk 5.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
puts $fh {set_output_delay -clock clk 5.000 [get_ports -filter {DIRECTION == OUT}]}
close $fh
read_xdc $ioxdc
implement IO [file join $base io_constrained]
puts "ND ALL_DONE"
