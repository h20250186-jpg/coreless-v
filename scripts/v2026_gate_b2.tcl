# NEW (2026-11-12). Vivado 2026.1 gate test (b), RE-RUN with init files, plus
# pre-(c) checks 1-3. Approved by the user 2026-11-12: in the COPY only
# (external_2026/iisc_copy/), the 9 IPs whose init file is missing from their
# repo (DMEM_0..7 -> python_scripts/dmem_bankN.coe, mainMem -> code.coe) are
# pointed at conv8_3's own files, copied to external_2026/iisc_copy/conv8_3_coe/.
# The copy's .xcix must be restored from the originals before this runs (the
# first gate-(b) run upgraded them in place).
#   (b)  upgrade + generate all 19 IPs on xc7vx485tffg1761-2
#   chk1 dump every IP's user parameters (compared afterwards with the original
#        .xci by scripts/v2026_compare_ip_params.py)
#   chk2 dump the generated xbip_dsp48_macro_0 module / port list
#   chk3 RTL elaboration of FPGA_WRAPPER, list black boxes / unresolved modules
# Nothing in external/ (the original repo), rtl/ or any existing script is touched.
# Usage: <VIVADO_2026_ROOT>\bin\vivado.bat -mode batch -source scripts/v2026_gate_b2.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set cp   [file join $root external_2026 iisc_copy]
set src  [file join $cp "Source code"]
set coe  [file join $cp conv8_3_coe]
set out  [file join $root synth_build_2026 gate_b2]
file mkdir $out
set part xc7vx485tffg1761-2
puts "GB2 version: [version -short]"

create_project -force iisc_2026 [file join $cp proj_2026] -part $part
foreach f [lsort [glob [file join $src IP *.xcix]]] {
    if {[catch {add_files -norecurse [list $f]} err]} { puts "GB2 ADD_FAILED [file tail $f]: [lindex [split $err \n] 0]" }
}
puts "GB2 IPs in project: [llength [get_ips]]"
report_ip_status -file [file join $out ip_status_before.rpt]

set initmap [dict create mainMem code.coe]
for {set b 0} {$b < 8} {incr b} { dict set initmap DMEM_$b dmem_bank$b.coe }

set ok {}; set fail {}
foreach ip [lsort [get_ips]] {
    set step upgrade
    if {[catch {
        if {[get_property IS_LOCKED $ip] || [llength [get_property UPGRADE_VERSIONS $ip]]} {
            # For the 9 init-file IPs upgrade_ip returns an error after a
            # PARTIAL upgrade (all parameters applied except Load_Init_File,
            # which it resets to false because the COE path does not exist).
            # The error is reported and the init file is set right after.
            if {[catch {upgrade_ip -log [file join $out upgrade_$ip.log] [get_ips $ip]} uerr]} {
                puts "GB2 UPGRADE_ERROR $ip : [lindex [split $uerr \n] 0] -> now [get_property IPDEF [get_ips $ip]] locked=[get_property IS_LOCKED [get_ips $ip]]"
                if {![dict exists $initmap $ip] || [get_property IS_LOCKED [get_ips $ip]]} { error $uerr }
            }
        }
        if {[dict exists $initmap $ip]} {
            set step set_init_file
            set cf [file join $coe [dict get $initmap $ip]]
            set_property -dict [list CONFIG.Load_Init_File true CONFIG.Coe_File $cf] [get_ips $ip]
            puts "GB2 INIT $ip : Load_Init_File=[get_property CONFIG.Load_Init_File [get_ips $ip]] Coe_File=[get_property CONFIG.Coe_File [get_ips $ip]]"
        }
        set step generate
        generate_target all [get_ips $ip]
    } err]} {
        puts "GB2 FAIL $ip at $step: [lindex [split $err \n] 0]"
        lappend fail $ip
    } else {
        set i2 [get_ips $ip]
        puts "GB2 OK $ip : [get_property IPDEF $i2] locked=[get_property IS_LOCKED $i2]"
        lappend ok $ip
    }
}
report_ip_status -file [file join $out ip_status_after.rpt]
puts "GB2 SUMMARY ok=[llength $ok] fail=[llength $fail] {$fail}"

# ---- check 1 data: user parameters of every IP after upgrade/generation
foreach ip [lsort [get_ips]] {
    set fh [open [file join $out params_$ip.txt] w]
    puts $fh "IPDEF=[get_property IPDEF [get_ips $ip]]"
    foreach p [lsort [list_property [get_ips $ip] CONFIG.*]] {
        puts $fh "[string range $p 7 end]=[get_property $p [get_ips $ip]]"
    }
    close $fh
}
# generated files per IP (for check 2 and the step-(c) simulation file list)
foreach ip [lsort [get_ips]] {
    set fh [open [file join $out files_$ip.txt] w]
    foreach f [get_files -quiet -all -of_objects [get_files "*/$ip.xcix"]] {
        puts $fh "[get_property USED_IN $f]\t[get_property FILE_TYPE $f]\t[get_property LIBRARY $f]\t$f"
    }
    close $fh
}
puts "GB2 params/files dumped"

# ---- rest of the project: their RTL (same file set as scripts/synth_iisc.tcl)
set rtl [file join $src rtl]
set vfiles {}
foreach f [glob -nocomplain [file join $rtl *.v] [file join $rtl * *.v] [file join $rtl * * *.v] [file join $rtl * * * *.v]] {
    if {[lsearch {defines.v timescale.v uart_defines.v} [file tail $f]] < 0} { lappend vfiles $f }
}
lappend vfiles [file join $src testbench FPGA_WRAPPER.v]
set standin [file join $cp xbip_dsp48_macro_missing.v]
file copy -force [file join $root external iisc_sim xbip_dsp48_macro_missing.v] $standin
lappend vfiles $standin
add_files -norecurse $vfiles
set vhdl {}
foreach f [glob -nocomplain [file join $rtl FPU fpu *.vhd] [file join $rtl FPU fpu *.vhdl] [file join $rtl vector_unit *.vhd]] { lappend vhdl $f }
add_files -norecurse $vhdl
set_property LIBRARY xil_defaultlib [get_files $vhdl]
puts "GB2 added [llength $vfiles] Verilog files (incl. our xbip_dsp48_macro_1/_2 stand-in file) and [llength $vhdl] VHDL files"
set_property include_dirs [list $rtl] [current_fileset]
set_property verilog_define {itlb_def=1 test_tlb=1 hardware_test=0} [current_fileset]
set_property top FPGA_WRAPPER [current_fileset]
update_compile_order -fileset sources_1

# ---- IP out-of-context synthesis (core-container IPs are always OOC;
# GENERATE_SYNTH_CHECKPOINT is read-only for .xcix). Produces the stubs that
# RTL elaboration of the top needs. Synthesis only, no implementation.
set runs {}
foreach ip $ok {
    if {[catch {create_ip_run [get_ips $ip]} e]} { puts "GB2 IPRUN_CREATE_FAILED $ip: [lindex [split $e \n] 0]" }
    set r [get_runs -quiet ${ip}_synth_1]
    if {[llength $r]} { lappend runs $r }
}
if {[llength $runs]} {
    launch_runs $runs -jobs 2
    foreach r $runs { wait_on_run $r }
    foreach r $runs { puts "GB2 IPSYNTH $r : [get_property STATUS $r] progress=[get_property PROGRESS $r]" }
}

# ---- check 3: RTL elaboration of the full design
if {[catch {synth_design -rtl -name rtl_1 -top FPGA_WRAPPER -part $part} err]} {
    puts "GB2 ELAB FAILED: [lindex [split $err \n] 0]"
} else {
    set bb [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]
    set fh [open [file join $out elab_blackboxes.txt] w]
    set refs [dict create]
    foreach c $bb { dict lappend refs [get_property REF_NAME $c] $c }
    dict for {r cs} $refs { puts $fh "$r\t[llength $cs]\t[lrange $cs 0 3]" ; puts "GB2 BLACKBOX $r x[llength $cs] (e.g. [lindex $cs 0])" }
    close $fh
    puts "GB2 ELAB OK top=[get_property TOP [current_design]] blackbox_cells=[llength $bb] distinct_refs=[dict size $refs]"
    close_design
}
close_project
puts "GB2_DONE"
