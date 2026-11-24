# NEW (2026-11-13). Virtex-7 XC7VX485T implementation of the I2SRV32-V FULL
# SYSTEM, Vivado 2026.1, part xc7vx485tffg1761-2 (their VC707 part).
# Top FPGA_WRAPPER, their constraints.xdc EXACTLY as written (pins included),
# no re-rooting, not out of context, main memory included.
# Sources: the 2026.1 COPY only (external_2026/iisc_copy/): their RTL,
# FPGA_WRAPPER.v, constraints.xdc, the 19 upgraded .xcix, and OUR stand-ins
# for xbip_dsp48_macro_1/_2 (not shipped in their repo).
# Defines as in every earlier IISc run: itlb_def=1 test_tlb=1 hardware_test=0
# (only itlb_def is tested by their RTL).
# Stage ipprep (user decision 2026-11-13): mainMem init file -> xmem.coe (the
# 2019.1 baseline program image), regenerate + synthesize that IP.
# A checkpoint is written after EVERY stage (synth, opt, place, phys_opt,
# route); stage.txt records each stage as it completes.
# Usage (2026.1): vivado -mode batch -source scripts/v7_impl_iisc.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set cp   [file join $root external_2026 iisc_copy]
set src  [file join $cp "Source code"]
set rtl  [file join $src rtl]
set part xc7vx485tffg1761-2
set out  [file join $root synth_build_2026 v7_xc7vx485t iisc_fpga_wrapper]
file mkdir $out
set T "V7I"
set stagef [file join $out stage.txt]
proc stamp {} { clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S} }
proc note {line} {
    global stagef T
    set fh [open $stagef a]; puts $fh "$line [stamp]"; close $fh
    puts "$T $line"
}
set fh [open $stagef w]; puts $fh "START [stamp] version [version -short] part $part top FPGA_WRAPPER"; close $fh
set_part $part

# ---- IP (all 19 from the copy)
foreach f [lsort [glob [file join $src IP *.xcix]]] { read_ip [list $f] }
puts "$T IPs read: [llength [get_ips]]"

# ---- stage ipprep: mainMem -> xmem.coe
set xmem [file join $cp conv8_3_coe xmem.coe]
file copy -force [file join $root external I2SRV32-V-v1-master benchmarks benchmarks conv conv8_3 Outputfiles xmem.coe] $xmem
if {[catch {
    set_property -dict [list CONFIG.Load_Init_File true CONFIG.Coe_File $xmem] [get_ips mainMem]
    generate_target -force all [get_ips mainMem]
    synth_ip -force [get_ips mainMem]
} err]} { note "ipprep FAILED: [lindex [split $err \n] 0]"; exit 1 }
note "ipprep DONE (mainMem Coe_File=[get_property CONFIG.Coe_File [get_ips mainMem]])"
foreach ip [lsort [get_ips]] {
    if {[catch {synth_ip [get_ips $ip]} err]} { note "ip_synth $ip FAILED: [lindex [split $err \n] 0]"; exit 1 }
}
note "ip_synth_check DONE (synth_ip on all 19: existing OOC results reused or rebuilt)"

# ---- their RTL (same file set as scripts/synth_iisc.tcl) + our stand-ins
set vfiles {}
foreach f [glob -nocomplain [file join $rtl *.v] [file join $rtl * *.v] [file join $rtl * * *.v] [file join $rtl * * * *.v]] {
    if {[lsearch {defines.v timescale.v uart_defines.v} [file tail $f]] < 0} { lappend vfiles $f }
}
lappend vfiles [file join $src testbench FPGA_WRAPPER.v]
lappend vfiles [file join $cp xbip_dsp48_macro_missing.v]
read_verilog $vfiles
set vhdl [glob [file join $rtl FPU fpu *.vhd] [file join $rtl FPU fpu *.vhdl] [file join $rtl vector_unit *.vhd]]
read_vhdl -library xil_defaultlib $vhdl
puts "$T sources: [llength $vfiles] Verilog, [llength $vhdl] VHDL"
set xdc [file join $src constraints constraints.xdc]
read_xdc [list $xdc]
puts "$T constraints: $xdc"

proc stage {name body} {
    global out T
    if {[catch {uplevel 1 $body} err]} {
        note "$name FAILED: [lindex [split $err \n] 0]"
        exit 1
    }
    write_checkpoint -force [file join $out post_$name.dcp]
    note "$name DONE"
}

stage synth {
    synth_design -top FPGA_WRAPPER -part $part -include_dirs [list $rtl] \
        -verilog_define itlb_def=1 -verilog_define test_tlb=1 -verilog_define hardware_test=0
}
report_utilization -file [file join $out post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file [file join $out post_synth_utilization_hier.rpt]

# ---- which of their exceptions match the synthesized netlist (read-only probe)
proc count_opts {argl} {
    set res {}
    for {set i 0} {$i < [llength $argl]} {incr i} {
        set a [lindex $argl $i]
        if {[lsearch {-from -to -through} $a] >= 0} { incr i; lappend res "$a=[llength [lindex $argl $i]]" }
    }
    return $res
}
proc probe_fp {args} { return [count_opts $args] }
proc probe_mc {args} { return [count_opts $args] }
proc probe_exceptions {tag} {
    global xdc out T
    set fh [open $xdc r]; set lines {}
    while {[gets $fh l] >= 0} { if {[regexp {^\s*(set_false_path|set_multicycle_path|set\s+_xlnx)} $l]} { lappend lines $l } }
    close $fh
    set ofh [open [file join $out exceptions_match_$tag.txt] w]
    set n 0; set eff 0
    foreach l $lines {
        if {[regexp {^\s*set\s+(_xlnx_shared_i\d)} $l -> v]} {
            uplevel #0 [string map {get_pins {get_pins -quiet}} $l]
            puts $ofh "VAR $v = [llength [set ::$v]] pins"; continue
        }
        incr n
        set kind [expr {[string match *set_false_path* $l] ? "FP" : "MC"}]
        set r [uplevel #0 [string map {set_false_path probe_fp set_multicycle_path probe_mc get_pins {get_pins -quiet} get_cells {get_cells -quiet}} $l]]
        set ok 1; foreach x $r { if {[string match *=0 $x]} { set ok 0 } }
        if {$ok} { incr eff }
        puts $ofh "$kind #$n [expr {$ok ? {MATCHES} : {NO MATCH}}] {$r} :: [string range [regsub -all {\s+} $l { }] 0 160]"
    }
    puts $ofh "SUMMARY $eff of $n exceptions have every -from/-to/-through list non-empty"
    close $ofh
    puts "$T EXCEPTIONS $tag: $eff of $n match"
}
probe_exceptions post_synth
catch {report_exceptions -file [file join $out post_synth_report_exceptions.rpt]} e_rx

stage opt      { opt_design }
stage place    { place_design }
stage phys_opt { phys_opt_design }
stage route    { route_design }

probe_exceptions post_route
catch {report_exceptions -file [file join $out post_route_report_exceptions.rpt]} e_rx
catch {report_exceptions -ignored -file [file join $out post_route_report_exceptions_ignored.rpt]} e_rx
report_utilization -file [file join $out post_route_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file [file join $out post_route_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
report_timing -max_paths 3 -nworst 1 -setup -file [file join $out post_route_worst_paths.rpt]
report_route_status -file [file join $out post_route_status.rpt]
report_clocks -file [file join $out post_route_clocks.rpt]
foreach c [get_clocks] {
    set p [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -group $c]
    set h [get_timing_paths -quiet -max_paths 1 -nworst 1 -hold  -group $c]
    puts "$T CLOCK [get_property NAME $c] period [get_property PERIOD $c] : WNS [expr {[llength $p] ? [get_property SLACK $p] : {none}}] WHS [expr {[llength $h] ? [get_property SLACK $h] : {none}}]"
}
note "reports DONE"
puts "$T ALL_DONE"
