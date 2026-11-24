# Non-project synthesis + implementation of the LIVE Coreless-V design.
# Usage: vivado -mode batch -source scripts/synth_atee.tcl
#
# Part: xc7a200tfbg676-2 (Artix-7). This is a STAND-IN chosen because it is the
# largest part this WebPACK install supports. It is NOT the Genesys 2 part
# (Kintex-7 XC7K325T). Every number produced here is "measured on Artix-7
# xc7a200t, not the literal Genesys 2 target".
#
# Sources: only the live files in rtl/vector_unit that atee_top reaches.
# Nothing from archive/ (no DMA controller, no scalar CPU) is read.

set root [file normalize [file join [file dirname [info script]] ..]]
set vu   [file join $root rtl vector_unit]
set out  [file join $root synth_build artix7_xc7a200tfbg676-2]
file mkdir $out
set part xc7a200tfbg676-2
set top  atee_top

puts "PARTCHECK xc7a200tfbg676-2 : [get_parts -quiet xc7a200tfbg676-2]"
puts "PARTCHECK xc7k325t*        : [get_parts -quiet xc7k325t*]"
puts "PARTCHECK kintex7 family   : [llength [get_parts -quiet -filter {FAMILY == kintex7}]] parts"
puts "PARTCHECK artix7 family    : [llength [get_parts -quiet -filter {FAMILY == artix7}]] parts"

set vhdl {mypack alu count_gen lsu stall_gen dmem_bram dmem_addr_xbar vrf_bank
          div_gen_behav multicycle_ops vminmax xoutreg cpu_inf exe_unit wrapper}
set vlog {v_wrapper tensor_config_regs outsize_div hbm_lite_controller atee_top}
foreach f $vhdl { read_vhdl -library xil_defaultlib [file join $vu $f.vhd] }
foreach f $vlog { read_verilog [file join $vu $f.v] }

puts "SOURCES read ([llength [get_files]] files):"
foreach f [get_files] { puts "  SRC $f" }
set bad [lsearch -all -inline -regexp [get_files] {archive|dma_controller|CPU|cpu\.v}]
puts "SOURCES from archive / DMA / CPU: [llength $bad] $bad"

# 50 MHz clock
set xdc [file join $out clock_50mhz.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period 20.000 \[get_ports clk\]"
close $fh
read_xdc $xdc

# ---------------------------------------------------------------- synthesis
synth_design -top $top -part $part
puts "SYNTH_DONE top=[get_property TOP [current_design]] design=[current_design] part=[get_property PART [current_design]]"
write_checkpoint -force [file join $out post_synth.dcp]
report_utilization              -file [file join $out post_synth_utilization.rpt]
report_utilization -hierarchical -file [file join $out post_synth_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $out post_synth_timing_summary.rpt]
puts "SYNTH_REPORTS_WRITTEN"

# ----------------------------------------------------------- implementation
if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $out post_route.dcp]
    report_utilization              -file [file join $out post_route_utilization.rpt]
    report_utilization -hierarchical -file [file join $out post_route_utilization_hier.rpt]
    report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
    report_route_status -file [file join $out post_route_status.rpt]
    report_power -file [file join $out post_route_power.rpt]
    puts "IMPL_DONE"
} err]} {
    puts "IMPL_FAILED: $err"
}
