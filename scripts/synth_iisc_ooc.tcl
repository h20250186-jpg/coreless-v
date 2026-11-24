# OUT-OF-CONTEXT synthesis + implementation of ONE compute block of the
# I2SRV32-V repo's own design, on the stand-in part xc7a200tfbg676-2.
# Nothing from this project's rtl/ is read.
# Usage: vivado -mode batch -source scripts/synth_iisc_ooc.tcl -tclargs vector|scalar|both
#
#   vector : top = vector_top (their vector unit incl. its 8 DMEM banks and
#            the div_gen IP). Clock: clk 20 ns.
#   scalar : top = cpu (pipeline + caches + branch predictor + ITLB), with
#            vector_top as a BLACK BOX (external/iisc_sim/vector_top_blackbox.v).
#            No mainMem, no UART / peripherals (those sit in FPGA_WRAPPER).
#            Clocks: clk 20 ns, clk_x2 10 ns (the two clk_wiz_0 outputs).
#            xbip_dsp48_macro_1/_2 (ITLB replacement logic) are NOT shipped by
#            the repo: hand-written ASSUMED-function stand-ins are synthesized.
#            A design holding a black box cannot be implemented (opt_design
#            DRC INBB-3), so this mode gives post-SYNTHESIS numbers only.
#   both   : top = cpu with the REAL vector unit inside (no black box), still
#            without mainMem and peripherals. This is the run that can be
#            placed and routed; its hierarchical report splits the scalar
#            logic from fdem/Pipeline/VECTOR_UNIT.
#
# IP is re-created in this Vivado version from their .xci parameters
# (external/iisc_sim/ip_config.tcl); only the IPs the block needs are built.
set block [lindex $argv 0]
if {[lsearch {vector scalar both} $block] < 0} { puts "IISC_OOC usage: -tclargs vector|scalar|both"; exit 1 }
set root [file normalize [file join [file dirname [info script]] ..]]
set repo [file join $root external I2SRV32-V-v1-master]
set rtl  [file join $repo "Source code" rtl]
set glue [file join $root external iisc_sim]
set out  [file join $root synth_build iisc_ooc_$block]
file mkdir $out
set part xc7a200tfbg676-2
set T IISC_OOC_[string toupper $block]

set want_vec {DMEM_0 DMEM_1 DMEM_2 DMEM_3 DMEM_4 DMEM_5 DMEM_6 DMEM_7 div_gen_0 div_gen_1}
set want_sca {blk_mem_gen_v7_3 blk_mem_gen_v7_3_2 BTB_mem PHT_mem dcache tag_ram xbip_dsp48_macro_0}
if {$block eq "vector"} {
    set top vector_top
    set want $want_vec
} elseif {$block eq "scalar"} {
    set top cpu
    set want $want_sca
} else {
    set top cpu
    set want [concat $want_sca $want_vec]
}

create_project -in_memory -part $part
set ipdir [file join $out ip]
file mkdir $ipdir
proc mkip {name ipname params} {
    global ipdir want T
    if {[lsearch $want $name] < 0} return
    create_ip -name $ipname -vendor xilinx.com -library ip -module_name $name -dir $ipdir
    set ip [get_ips $name]
    foreach pass {1 2 3 4} {
        set d {}
        foreach {p v} $params {
            if {[catch {set cur [get_property CONFIG.$p $ip]}]} continue
            if {$p eq "Coe_File" && [file tail $cur] eq [file tail $v]} continue
            if {$cur ne $v} { lappend d CONFIG.$p $v }
        }
        if {![llength $d]} break
        catch {set_property -dict $d $ip}
    }
    set diff {}
    foreach {p v} $params {
        if {[catch {set cur [get_property CONFIG.$p $ip]}]} continue
        if {$p eq "Coe_File" && [file tail $cur] eq [file tail $v]} continue
        if {$cur ne $v} { lappend diff "${p}=${cur} (wanted ${v})" }
    }
    puts "$T IP $name ($ipname): differing from their .xci after config: [llength $diff] {$diff}"
    set_property generate_synth_checkpoint false [get_files [get_property IP_FILE $ip]]
    generate_target all $ip
}
source [file join $glue ip_config.tcl]
puts "$T created [llength [get_ips]] of [llength $want] IPs"

# ---- sources
set vfiles {}
set vhdl {}
set vu [file join $rtl vector_unit]
if {$block eq "vector"} {
    foreach f [glob -nocomplain [file join $vu *.v]] { lappend vfiles $f }
    foreach f [glob -nocomplain [file join $vu *.vhd]] { lappend vhdl $f }
} else {
    foreach f [glob -nocomplain [file join $rtl *.v] [file join $rtl * *.v] [file join $rtl * * *.v]] {
        if {[lsearch {defines.v timescale.v uart_defines.v} [file tail $f]] >= 0} continue
        if {$block eq "scalar" && [file dirname $f] eq $vu} continue
        lappend vfiles $f
    }
    if {$block eq "scalar"} { lappend vfiles [file join $glue vector_top_blackbox.v] }   ;# black box, no logic
    lappend vfiles [file join $glue xbip_dsp48_macro_missing.v]   ;# STAND-INS, not their IP
    foreach f [glob -nocomplain [file join $rtl FPU fpu *.vhd] [file join $rtl FPU fpu *.vhdl]] { lappend vhdl $f }
    if {$block eq "both"} { foreach f [glob -nocomplain [file join $vu *.vhd]] { lappend vhdl $f } }
}
read_verilog $vfiles
if {[llength $vhdl]} { read_vhdl -library xil_defaultlib $vhdl }
puts "$T sources: [llength $vfiles] Verilog, [llength $vhdl] VHDL; from this project's rtl/: [llength [lsearch -all -glob [get_files] "$root/rtl/*"]]"

set xdc [file join $out clock.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period 20.000 \[get_ports clk\]"
if {$block ne "vector"} { puts $fh "create_clock -name clk_x2 -period 10.000 \[get_ports clk_x2\]" }
close $fh
read_xdc -mode out_of_context $xdc

if {[catch {
    synth_design -top $top -part $part -mode out_of_context -include_dirs [list $rtl] \
        -verilog_define itlb_def=1 -verilog_define test_tlb=1 -verilog_define hardware_test=0
} err]} {
    puts "$T SYNTH_FAILED: $err"
    exit
}
puts "$T SYNTH_DONE top=[get_property TOP [current_design]] part=[get_property PART [current_design]]"
puts "$T black boxes: [llength [get_cells -hier -filter {IS_BLACKBOX}]] {[get_cells -hier -filter {IS_BLACKBOX}]}"
write_checkpoint -force [file join $out post_synth.dcp]
report_utilization              -file [file join $out post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $out post_synth_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $out post_synth_timing_summary.rpt]
puts "$T SYNTH_REPORTS_WRITTEN"

if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $out post_route.dcp]
    report_utilization              -file [file join $out post_route_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 4 -file [file join $out post_route_utilization_hier.rpt]
    report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
    report_timing -max_paths 3 -nworst 1 -setup -file [file join $out post_route_worst_paths.rpt]
    report_route_status -file [file join $out post_route_status.rpt]
    puts "$T IMPL_DONE"
} err]} {
    puts "$T IMPL_FAILED: $err"
}
