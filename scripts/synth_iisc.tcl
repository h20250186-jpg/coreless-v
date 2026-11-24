# Synthesis + implementation of the I2SRV32-V repo's OWN design (top
# FPGA_WRAPPER) with the same flow used for Coreless-V, for a same-device,
# same-method comparison. Nothing from this project's rtl/ is read.
# Usage: vivado -mode batch -source scripts/synth_iisc.tcl
#
# Part: xc7a200tfbg676-2 (Artix-7 STAND-IN chosen for availability; their own
# target is a VC707, Virtex-7 xc7vx485t). Core clock 20 ns (clk_wiz_0 from a
# 5 ns / 200 MHz input, as in their IP configuration). Clock constraints only.
#
# IP: their .xcix containers are from Vivado 2020.2 and cannot be opened here.
# Each IP is RE-CREATED in this Vivado version from the user parameters stored
# in its .xci (external/iisc_sim/ip_config.tcl). Parameters this version
# rejects are printed. xbip_dsp48_macro_1 / _2 are instantiated by their RTL
# but not shipped: assumed-function stand-ins are used and reported as such.
set root [file normalize [file join [file dirname [info script]] ..]]
set repo [file join $root external I2SRV32-V-v1-master]
set rtl  [file join $repo "Source code" rtl]
set glue [file join $root external iisc_sim]
set out  [file join $root synth_build iisc_xc7a200tfbg676-2]
file mkdir $out
set part xc7a200tfbg676-2

create_project -in_memory -part $part
set ipdir [file join $out ip]
file mkdir $ipdir

set ip_fail 0
proc mkip {name ipname params} {
    global ipdir ip_fail
    if {[catch {create_ip -name $ipname -vendor xilinx.com -library ip -module_name $name -dir $ipdir} err]} {
        puts "IISC_IP $name ($ipname): CREATE FAILED: $err"
        incr ip_fail
        return
    }
    set ip [get_ips $name]
    # all parameters in ONE call, so interdependent ones are validated together
    # Repeated because a parameter that is disabled until another one changes
    # (e.g. port B options before Memory_Type) is silently skipped the first time.
    set status "joint config ok"
    set first -1
    foreach pass {1 2 3 4} {
        set d {}
        set unknown {}
        foreach {p v} $params {
            if {[catch {set cur [get_property CONFIG.$p $ip]}]} { lappend unknown $p; continue }
            if {$p eq "Coe_File" && [file tail $cur] eq [file tail $v]} continue
            if {$cur ne $v} { lappend d CONFIG.$p $v }
        }
        if {$first < 0} { set first [llength $d] }
        if {![llength $d]} break
        if {[catch {set_property -dict $d $ip} err]} {
            set status "JOINT CONFIG REJECTED (pass $pass): [lindex [split $err \n] 0]"
        }
    }
    set d [list x $first]
    set diff {}
    foreach {p v} $params {
        if {[catch {set cur [get_property CONFIG.$p $ip]}]} continue
        if {$p eq "Coe_File" && [file tail $cur] eq [file tail $v]} continue
        if {$cur ne $v} { lappend diff "${p}=${cur} (wanted ${v})" }
    }
    if {[llength $diff]} { incr ip_fail }
    puts "IISC_IP $name ($ipname [get_property VERSION [get_ipdefs -of_objects $ip]]): [expr {[llength $params]/2}] parameters, [expr {$first/2}] non-default, $status; unknown here: [llength $unknown] {$unknown}; differing after config: [llength $diff] {$diff}"
    set_property generate_synth_checkpoint false [get_files [get_property IP_FILE $ip]]
    generate_target all $ip
}
source [file join $glue ip_config.tcl]
puts "IISC_IP created [llength [get_ips]] IPs, $ip_fail not matching their .xci parameters"
if {[info exists ::env(IISC_IP_ONLY)]} { puts "IISC_IP_ONLY set: stopping after IP regeneration"; exit }

# ---- sources
set vfiles {}
foreach f [glob -nocomplain [file join $rtl *.v] [file join $rtl * *.v] [file join $rtl * * *.v]] {
    if {[lsearch {defines.v timescale.v uart_defines.v} [file tail $f]] < 0} { lappend vfiles $f }
}
lappend vfiles [file join $repo "Source code" testbench FPGA_WRAPPER.v]
lappend vfiles [file join $glue xbip_dsp48_macro_missing.v]   ;# STAND-INS, not their IP
read_verilog $vfiles
set vhdl {}
foreach f [glob -nocomplain [file join $rtl FPU fpu *.vhd] [file join $rtl FPU fpu *.vhdl] [file join $rtl vector_unit *.vhd]] { lappend vhdl $f }
read_vhdl -library xil_defaultlib $vhdl
puts "IISC_SRC [llength $vfiles] Verilog files, [llength $vhdl] VHDL files; from this project's rtl/: [llength [lsearch -all -glob [get_files] "$root/rtl/*"]]"

set xdc [file join $out clock.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk_in1 -period 5.000 \[get_ports clk_in1_p\]"
close $fh
read_xdc $xdc

# ---- synthesis (same defines as their simulation: itlb_def=1 test_tlb=1 hardware_test=0)
if {[catch {
    synth_design -top FPGA_WRAPPER -part $part -include_dirs [list $rtl] \
        -verilog_define itlb_def=1 -verilog_define test_tlb=1 -verilog_define hardware_test=0
} err]} {
    puts "IISC_SYNTH_FAILED: $err"
    exit
}
puts "IISC_SYNTH_DONE top=[get_property TOP [current_design]] part=[get_property PART [current_design]]"
write_checkpoint -force [file join $out post_synth.dcp]
report_utilization              -file [file join $out post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file [file join $out post_synth_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $out post_synth_timing_summary.rpt]
report_clocks -file [file join $out post_synth_clocks.rpt]
puts "IISC_SYNTH_REPORTS_WRITTEN"

# ---- implementation
if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $out post_route.dcp]
    report_utilization              -file [file join $out post_route_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 6 -file [file join $out post_route_utilization_hier.rpt]
    report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
    report_timing -max_paths 3 -nworst 1 -setup -file [file join $out post_route_worst_paths.rpt]
    report_route_status -file [file join $out post_route_status.rpt]
    report_power -file [file join $out post_route_power_vectorless.rpt]
    puts "IISC_IMPL_DONE"
} err]} {
    puts "IISC_IMPL_FAILED: $err"
}
