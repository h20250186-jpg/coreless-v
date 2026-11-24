# NEW (2026-11-12), a copy of testbench/power_saif.tcl (unchanged) for the
# vl=16 design: xsim batch script recording switching activity (SAIF) of the
# routed atee_top_vl16 netlist over the layer-busy window ONLY, while
# atee_conv_vl16_tb runs CONV2D 8x8 (conv8_3 data), no ReLU.
# Steps are 20 ns = one clock period, ending on falling edges.
# Only the nets and ports of the design's own module scopes are logged, as in
# the vl=8 run (no recursion into the primitive cell models).
set TB /atee_conv_vl16_tb
set P  $TB/dut/u_vec_unit/wrapper_vhd/VECTOR_EXE_UNIT_PIPE
set n 0
while {[get_value $TB/dut/cfg_layer_busy] ne "1"} {
    run 20ns
    incr n
    if {$n > 500000} { puts "SAIF ERROR: layer never became busy"; quit }
}
puts "SAIF window opens at [current_time] (after $n cycles of reset, DMEM load and configuration)"

set scopes [list $TB/dut $TB/dut/u_config $TB/dut/u_hbm_lite $TB/dut/u_hbm_lite/u_outsize \
                 $TB/dut/u_vec_unit $TB/dut/u_vec_unit/wrapper_vhd $P]
foreach k [get_scopes -quiet $P/*] {
    if {[regexp {/\\?(DMEM[0-7]|DMEM_INF|VECTOR_CPU_INF|X_REGS|gen_stall|GEN_[A-Za-z]+\[[0-7]\]\.[a-z_]+_gen) ?$} $k]} { lappend scopes $k }
}
open_saif conv8_3_vl16_busy.saif
# The 40 escaped GEN_* scope names do not resolve in get_objects: the pattern
# falls back to the TESTBENCH's own top-level signals (found 2026-11-12). The
# vl=8 run logged those testbench signals, which report_power cannot match to
# the design, so its effective design coverage is the 19 resolving scopes.
# Here objects outside their own scope are dropped: same design coverage as
# the vl=8 run, without logging the 61,504-word testbench arrays.
set nobj 0
set nscope 0
set ndrop 0
foreach s $scopes {
    set keep {}
    foreach x [get_objects -quiet $s/*] {
        if {[string first "$s/" $x] == 0} { lappend keep $x } else { incr ndrop }
    }
    if {[llength $keep]} { log_saif $keep; incr nobj [llength $keep]; incr nscope }
}
puts "SAIF logging $nobj nets/ports from $nscope of [llength $scopes] listed scopes ($ndrop objects outside their scope dropped)"

set c 0
while {[get_value $TB/dut/cfg_layer_busy] eq "1"} {
    run 20ns
    incr c
}
close_saif
puts "SAIF window closes at [current_time]: $c clock cycles with layer_busy = 1"
run -all
quit
