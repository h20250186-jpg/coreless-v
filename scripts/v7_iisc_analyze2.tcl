# NEW (2026-11-14). READ-ONLY analysis of the routed Virtex-7 IISc checkpoint
# (synth_build_2026/v7_xc7vx485t/iisc_fpga_wrapper/post_route.dcp), for the
# "repo build vs paper" questions. Changes no constraint, placement or routing
# and writes no checkpoint. Outputs go to <run dir>/analysis2_*.
#  1. deep hierarchical utilization of VECTOR_UNIT
#  2. LUT primitives by sub-block of the vector unit (leaf-cell name prefix)
#  3. DMEM primitives: count per bank, configuration, cascade use
#  4. worst non-divider path: levels per hierarchy, logic vs route delay
# Usage (2026.1): vivado -mode batch -source scripts/v7_iisc_analyze2.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set d [file join $root synth_build_2026 v7_xc7vx485t iisc_fpga_wrapper]
open_checkpoint [file join $d post_route.dcp]
set VU cpu1/fdem/Pipeline/VECTOR_UNIT
set P  $VU/VEC_EXE_UNIT/wrapper_vhd/VECTOR_EXE_UNIT_PIPE

# 1. deep hierarchy of the vector unit
report_utilization -hierarchical -hierarchical_depth 4 -cells [get_cells $VU/VEC_EXE_UNIT/wrapper_vhd/VECTOR_EXE_UNIT_PIPE] \
    -file [file join $d analysis2_vector_hier.rpt]
puts "A2 hier report written"

# 2. LUT primitives in the vector unit, by the first hierarchy level below
#    VECTOR_EXE_UNIT_PIPE (the instance the leaf is named under after routing)
set luts [get_cells -hier -filter "PRIMITIVE_GROUP == LUT && NAME =~ $VU/*"]
puts "A2 LUT primitives under VECTOR_UNIT: [llength $luts]"
set cnt [dict create]
foreach c $luts {
    set n [get_property NAME $c]
    if {[string match "$P/*" $n]} {
        set rest [string range $n [expr {[string length $P] + 1}] end]
        set k [lindex [split $rest /] 0]
        if {[llength [split $rest /]] == 1} { set k "(exe_unit itself)" }
        regsub {\[\d+\]} $k {[*]} k
    } else { set k "(outside VECTOR_EXE_UNIT_PIPE)" }
    dict incr cnt $k
}
set fh [open [file join $d analysis2_vector_lut_by_block.txt] w]
foreach k [lsort [dict keys $cnt]] { puts $fh [format "%-40s %7d" $k [dict get $cnt $k]]; puts "A2 LUTS $k [dict get $cnt $k]" }
close $fh
# divider-only primitives (any hierarchy)
set dl [get_cells -hier -filter {PRIMITIVE_GROUP == LUT && NAME =~ *GEN_DIVIDERs*}]
set dc [get_cells -hier -filter {REF_NAME == CARRY4 && NAME =~ *GEN_DIVIDERs*}]
set df [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH && NAME =~ *GEN_DIVIDERs*}]
puts "A2 DIVIDER primitives: LUT [llength $dl] CARRY4 [llength $dc] FF [llength $df]"
foreach g [lsort [get_cells -quiet -hier -filter "NAME =~ $P/GEN_DIVIDERs*" ]] {
    if {[regexp {GEN_DIVIDERs\[\d+\]\.[^/]+$} [get_property NAME $g]] || [regexp {GEN_DIVIDERs\[\d+\]/[^/]+$} [get_property NAME $g]]} {
        puts "A2 DIVCELL [get_property NAME $g] ref [get_property REF_NAME $g]"
    }
}

# 3. DMEM primitives
for {set b 0} {$b < 8} {incr b} {
    set prims [get_cells -hier -filter "PRIMITIVE_GROUP == BLOCKRAM && NAME =~ $P/DMEM$b/*"]
    set desc {}
    foreach p $prims {
        lappend desc "[get_property REF_NAME $p]:RW_A=[get_property READ_WIDTH_A $p]:EXT_A=[get_property RAM_EXTENSION_A $p]"
    }
    set u [lsort -unique $desc]
    set s {}
    foreach x $u { lappend s "[llength [lsearch -all $desc $x]]x $x" }
    puts "A2 DMEM$b primitives [llength $prims] : [join $s {, }]"
}
set mux [get_cells -hier -filter "PRIMITIVE_GROUP == LUT && NAME =~ $P/DMEM1/*has_mux_a*"]
puts "A2 DMEM1 output-mux LUTs (has_mux_a): [llength $mux]"

# 4. worst non-divider path, split by hierarchy
set p [get_timing_paths -setup -group clk_out1_clk_wiz_0 -max_paths 1 -nworst 1 \
        -to [get_cells -hier -filter {IS_SEQUENTIAL && NAME !~ *GEN_DIVIDERs*}]]
puts "A2 PATH slack [get_property SLACK $p] datapath [get_property DATAPATH_DELAY $p] logic [get_property DATAPATH_LOGIC_DELAY $p] route [get_property DATAPATH_NET_DELAY $p] levels [get_property LOGIC_LEVELS $p]"
set blk [dict create]
foreach c [get_cells -of_objects $p] {
    set n [get_property NAME $c]
    if {[string match "$P/DMEM*" $n]} { set k DMEM_ip } \
    elseif {[string match "$P/VECTOR_CPU_INF/*" $n]} { set k VECTOR_CPU_INF } \
    elseif {[string match "$P/*" $n]} { set k exe_unit_other } \
    elseif {[string match "cpu1/fdem/db1/dt1/dd/dtlb/*" $n]} { set k dtlb } \
    elseif {[string match "cpu1/fdem/db1/dt1/*" $n]} { set k dcache_top_other } \
    elseif {[string match "cpu1/fdem/db1/biu1/*" $n]} { set k dcache_biu1 } \
    else { set k other:[join [lrange [split $n /] 0 3] /] }
    dict lappend blk $k [get_property REF_NAME $c]
}
dict for {k v} $blk { puts "A2 PATHCELLS $k : [llength $v] cells ([join [lsort -unique $v] { }])" }
puts "A2_DONE"
