# NEW (2026-11-14). EXPERIMENT, "paper configuration": the I2SRV32-V full
# system with its vector scratchpad at the paper's size (16 KB per bank,
# 128 KB total). Does NOT replace Run 3 (scripts/v7_impl_iisc.tcl).
# Same flow as Run 3: Vivado 2026.1, xc7vx485tffg1761-2, top FPGA_WRAPPER,
# their constraints.xdc unchanged, main memory included, checkpoints per stage.
# Sources: external_2026/iisc_paper_cfg/ (a copy of iisc_copy with
# VMEM_ADDR_WIDTH 14 -> 12 in the vector-unit VHDL, see RESULTS.md).
# ipprep: mainMem -> xmem.coe (as Run 3); DMEM_0..7 Write_Depth_A 16384 ->
# 4096, init files dmem_bankN.coe (165-166 words, fit in 4096).
# Usage (2026.1): vivado -mode batch -source scripts/v7_impl_iisc_papercfg.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set cp   [file join $root external_2026 iisc_paper_cfg]
set src  [file join $cp "Source code"]
set rtl  [file join $src rtl]
set part xc7vx485tffg1761-2
set out  [file join $root synth_build_2026 v7_xc7vx485t iisc_paper_cfg_experiment]
file mkdir $out
set T "V7P"
set stagef [file join $out stage.txt]
proc stamp {} { clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S} }
proc note {line} {
    global stagef T
    set fh [open $stagef a]; puts $fh "$line [stamp]"; close $fh
    puts "$T $line"
}
set fh [open $stagef w]; puts $fh "START [stamp] version [version -short] part $part top FPGA_WRAPPER (EXPERIMENT paper cfg)"; close $fh
set_part $part

foreach f [lsort [glob [file join $src IP *.xcix]]] { read_ip [list $f] }
puts "$T IPs read: [llength [get_ips]]"

# ---- stage ipprep
set xmem [file join $cp conv8_3_coe xmem.coe]
file copy -force [file join $root external I2SRV32-V-v1-master benchmarks benchmarks conv conv8_3 Outputfiles xmem.coe] $xmem
if {[catch {
    set_property -dict [list CONFIG.Load_Init_File true CONFIG.Coe_File $xmem] [get_ips mainMem]
    generate_target -force all [get_ips mainMem]
    synth_ip -force [get_ips mainMem]
} err]} { note "ipprep mainMem FAILED: [lindex [split $err \n] 0]"; exit 1 }
for {set b 0} {$b < 8} {incr b} {
    set ip [get_ips DMEM_$b]
    set coe [file join $cp conv8_3_coe dmem_bank$b.coe]
    if {[catch {
        set_property -dict [list CONFIG.Write_Depth_A 4096 CONFIG.Load_Init_File true CONFIG.Coe_File $coe] $ip
        generate_target -force all $ip
        synth_ip -force $ip
    } err]} { note "ipprep DMEM_$b FAILED: [lindex [split $err \n] 0]"; exit 1 }
    puts "$T DMEM_$b Write_Depth_A=[get_property CONFIG.Write_Depth_A $ip] Write_Width_A=[get_property CONFIG.Write_Width_A $ip] Coe=[file tail [get_property CONFIG.Coe_File $ip]]"
}
note "ipprep DONE (mainMem Coe_File=[file tail [get_property CONFIG.Coe_File [get_ips mainMem]]]; DMEM_0..7 depth 4096)"
foreach ip [lsort [get_ips]] {
    if {[catch {synth_ip [get_ips $ip]} err]} { note "ip_synth $ip FAILED: [lindex [split $err \n] 0]"; exit 1 }
}
note "ip_synth_check DONE"

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

proc stage {name body} {
    global out T
    if {[catch {uplevel 1 $body} err]} { note "$name FAILED: [lindex [split $err \n] 0]"; exit 1 }
    write_checkpoint -force [file join $out post_$name.dcp]
    note "$name DONE"
}

stage synth {
    synth_design -top FPGA_WRAPPER -part $part -include_dirs [list $rtl] \
        -verilog_define itlb_def=1 -verilog_define test_tlb=1 -verilog_define hardware_test=0
}
report_utilization -file [file join $out post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file [file join $out post_synth_utilization_hier.rpt]

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

stage opt      { opt_design }
stage place    { place_design }
stage phys_opt { phys_opt_design }
stage route    { route_design }

probe_exceptions post_route
report_utilization -file [file join $out post_route_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file [file join $out post_route_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $out post_route_timing_summary.rpt]
report_timing -max_paths 3 -nworst 1 -setup -file [file join $out post_route_worst_paths.rpt]
report_route_status -file [file join $out post_route_status.rpt]
foreach c [get_clocks] {
    set p [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -group $c]
    set h [get_timing_paths -quiet -max_paths 1 -nworst 1 -hold  -group $c]
    puts "$T CLOCK [get_property NAME $c] period [get_property PERIOD $c] : WNS [expr {[llength $p] ? [get_property SLACK $p] : {none}}] WHS [expr {[llength $h] ? [get_property SLACK $h] : {none}}]"
}
# worst path inside / outside the divider IP (core clock)
set g clk_out1_clk_wiz_0
foreach {tag flt} [list inside_divider {IS_SEQUENTIAL && NAME =~ *GEN_DIVIDERs*} outside_divider {IS_SEQUENTIAL && NAME !~ *GEN_DIVIDERs*}] {
    set p [get_timing_paths -quiet -setup -group $g -max_paths 1 -nworst 1 -to [get_cells -hier -filter $flt]]
    if {[llength $p]} {
        puts "$T PATH $tag slack [get_property SLACK $p] datapath [get_property DATAPATH_DELAY $p] logic [get_property DATAPATH_LOGIC_DELAY $p] route [get_property DATAPATH_NET_DELAY $p] levels [get_property LOGIC_LEVELS $p]"
        puts "$T PATH $tag from [get_property STARTPOINT_PIN $p]"
        puts "$T PATH $tag to   [get_property ENDPOINT_PIN $p]"
        report_timing -setup -group $g -max_paths 1 -to [get_cells -hier -filter $flt] -file [file join $out post_route_worst_$tag.rpt]
    }
}
set fp [get_timing_paths -quiet -setup -group $g -slack_lesser_than 0 -max_paths 100000 -nworst 1 -unique_pins]
set cat [dict create]
foreach p $fp {
    set e [get_property ENDPOINT_PIN $p]
    if {[string match *GEN_DIVIDERs* $e]} { set k divider_ip } elseif {[string match *VECTOR_UNIT* $e]} { set k vector_unit_other } \
    elseif {[string match *FP_EX* $e]} { set k scalar_fpu } else { set k scalar_other }
    dict incr cat $k
}
puts "$T failing endpoints clk_out1: [llength $fp]"
dict for {k v} $cat { puts "$T   endpoints $k : $v" }
note "reports DONE"
puts "$T ALL_DONE"
