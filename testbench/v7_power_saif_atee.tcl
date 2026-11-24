# NEW (2026-11-14). xsim batch script (Vivado 2019.1 xsim, Task B hybrid flow)
# recording SAIF of a routed Coreless-V netlist over the LAYER-BUSY window.
# Settings come from environment variables (set by scripts/v7_power_atee.ps1):
#   SAIF_TB    testbench top, e.g. atee_conv_vl16_tb or atee_conv8_3_tb
#   SAIF_FILE  output SAIF file name
#   SAIF_MODE  old : the earlier scope list and pattern (testbench/power_saif_vl16.tcl,
#                    19 of 59 scopes resolve) -- for the "before" figure
#              new : every hierarchical (non-primitive) cell of the netlist,
#                    listed by Vivado in SAIF_HIER (hier_cells.txt), entered with
#                    current_scope so escaped names (\GEN_ALUs[1].alu_gen ) resolve
#   SAIF_HIER  file with one hierarchical cell name per line (relative to dut)
# Steps are 20 ns = one clock period.
set TB /$::env(SAIF_TB)
set mode $::env(SAIF_MODE)
set P  $TB/dut/u_vec_unit/wrapper_vhd/VECTOR_EXE_UNIT_PIPE
set n 0
while {[get_value $TB/dut/cfg_layer_busy] ne "1"} {
    run 20ns
    incr n
    if {$n > 500000} { puts "SAIF ERROR: layer never became busy"; quit }
}
puts "SAIF window opens at [current_time] (after $n cycles of reset, DMEM load and configuration)"
open_saif $::env(SAIF_FILE)

if {$mode eq "old"} {
    set scopes [list $TB/dut $TB/dut/u_config $TB/dut/u_hbm_lite $TB/dut/u_hbm_lite/u_outsize \
                     $TB/dut/u_vec_unit $TB/dut/u_vec_unit/wrapper_vhd $P]
    foreach k [get_scopes -quiet $P/*] {
        if {[regexp {/\\?(DMEM[0-7]|DMEM_INF|VECTOR_CPU_INF|X_REGS|gen_stall|GEN_[A-Za-z]+\[[0-7]\]\.[a-z_]+_gen) ?$} $k]} { lappend scopes $k }
    }
    set nobj 0; set nscope 0; set ndrop 0
    foreach s $scopes {
        set keep {}
        foreach x [get_objects -quiet $s/*] {
            if {[string first "$s/" $x] == 0} { lappend keep $x } else { incr ndrop }
        }
        if {[llength $keep]} { log_saif $keep; incr nobj [llength $keep]; incr nscope }
    }
    puts "SAIF MODE old: logging $nobj nets/ports from $nscope of [llength $scopes] listed scopes ($ndrop objects outside their scope dropped)"
} else {
    set fh [open $::env(SAIF_HIER) r]; set want [dict create]
    while {[gets $fh l] >= 0} { set l [string trim $l]; if {$l ne ""} { dict set want $l 1 } }
    close $fh
    # breadth-first walk: enter each scope with current_scope, list its child
    # scopes and objects with relative patterns
    set queue [list [list $TB/dut ""]]
    set nobj 0; set nscope 0; set found [dict create]
    while {[llength $queue]} {
        lassign [lindex $queue 0] s rel; set queue [lrange $queue 1 end]
        current_scope $s
        set objs [get_objects -quiet *]
        set kids [get_scopes -quiet *]
        current_scope /
        if {[llength $objs]} { log_saif $objs; incr nobj [llength $objs] }
        incr nscope
        if {$rel ne ""} { dict set found $rel 1 }
        foreach k $kids {
            set leaf [string trimright [string trimleft [lindex [split [string range $k [string length $s] end] /] end] \\] " "]
            set krel [expr {$rel eq "" ? $leaf : "$rel/$leaf"}]
            if {[dict exists $want $krel]} { lappend queue [list $k $krel] }
        }
    }
    set miss {}
    dict for {k v} $want { if {![dict exists $found $k]} { lappend miss $k } }
    puts "SAIF MODE new: logging $nobj nets/ports from $nscope scopes (dut + [expr {$nscope - 1}] of [dict size $want] hierarchical cells listed by Vivado; not found: [llength $miss])"
    foreach m [lrange $miss 0 9] { puts "SAIF   not found: $m" }
}

set c 0
while {[get_value $TB/dut/cfg_layer_busy] eq "1"} {
    run 20ns
    incr c
}
close_saif
puts "SAIF window closes at [current_time]: $c clock cycles with layer_busy = 1"
run -all
quit
