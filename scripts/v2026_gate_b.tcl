# NEW (2026-11-12). Vivado 2026.1 gate test (b): their ORIGINAL Vivado 2020.2
# IP containers (.xcix) in 2026.1. Works ONLY on the copy in
# external_2026/iisc_copy/ (external/I2SRV32-V-v1-master is not touched; no
# .xpr exists in their repo, so a NEW 2026.1 project is created around the
# copied sources). Part: xc7vx485tffg1761-2 (their VC707 target).
# Per IP: report_ip_status, upgrade_ip if needed, generate_target all.
# Their RTL and our xbip_dsp48_macro_1/_2 stand-ins are added so the project
# is complete; no synthesis or implementation is run here.
# Usage: <VIVADO_2026_ROOT>\bin\vivado.bat -mode batch -source scripts/v2026_gate_b.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set cp   [file join $root external_2026 iisc_copy]
set src  [file join $cp "Source code"]
set out  [file join $root synth_build_2026 gate_b]
file mkdir $out
set part xc7vx485tffg1761-2
puts "GB version: [version -short]"

create_project -force iisc_2026 [file join $cp proj_2026] -part $part
set xcix [lsort [glob [file join $src IP *.xcix]]]
puts "GB adding [llength $xcix] original .xcix containers from the copy"
foreach f $xcix {
    if {[catch {add_files -norecurse [list $f]} err]} { puts "GB ADD_FAILED [file tail $f]: [lindex [split $err \n] 0]" }
}
puts "GB IPs in project: [llength [get_ips]]"
report_ip_status -file [file join $out ip_status_before.rpt]
foreach ip [lsort [get_ips]] {
    puts "GB BEFORE $ip : vlnv=[get_property IPDEF $ip] locked=[get_property IS_LOCKED $ip] upgrade_available=[get_property UPGRADE_VERSIONS $ip] locked_reason=[get_property LOCK_DETAILS $ip]"
}

set ok {}; set fail {}
foreach ip [lsort [get_ips]] {
    set step upgrade
    if {[catch {
        if {[get_property IS_LOCKED $ip] || [llength [get_property UPGRADE_VERSIONS $ip]]} {
            upgrade_ip -log [file join $out upgrade_$ip.log] $ip
        }
        set ip2 [get_ips $ip]
        set step generate
        generate_target all $ip2
    } err]} {
        puts "GB FAIL $ip at $step: [lindex [split $err \n] 0]"
        lappend fail $ip
    } else {
        set ip2 [get_ips $ip]
        puts "GB OK $ip : now [get_property IPDEF $ip2] locked=[get_property IS_LOCKED $ip2]"
        lappend ok $ip
    }
}
report_ip_status -file [file join $out ip_status_after.rpt]
puts "GB SUMMARY ok=[llength $ok] fail=[llength $fail] {$fail}"

# rest of the project (their RTL + our stand-ins), for later use
set rtl [file join $src rtl]
set vfiles {}
foreach f [glob -nocomplain [file join $rtl *.v] [file join $rtl * *.v] [file join $rtl * * *.v]] {
    if {[lsearch {defines.v timescale.v uart_defines.v} [file tail $f]] < 0} { lappend vfiles $f }
}
lappend vfiles [file join $src testbench FPGA_WRAPPER.v]
set standin [file join $cp xbip_dsp48_macro_missing.v]
file copy -force [file join $root external iisc_sim xbip_dsp48_macro_missing.v] $standin
lappend vfiles $standin
add_files -norecurse $vfiles
puts "GB added [llength $vfiles] Verilog files (incl. our stand-in file for xbip_dsp48_macro_1/_2)"
close_project
puts "GB_DONE"
