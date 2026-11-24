# xsim batch script: record switching activity (SAIF) of the routed netlist
# over the layer-busy window ONLY, while atee_conv8_3_tb runs conv8_3.
# Steps are 20 ns = one clock period, ending on falling edges.
#
# Only the nets and ports of the design's own module scopes are logged (the 58
# hierarchical cells of the routed design plus the top). Recursing with
# `get_objects -r` would also descend into all ~48,000 primitive cell models,
# which takes far too long and adds nothing report_power can match.
set TB /atee_conv8_3_tb
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
open_saif conv8_3_busy.saif
set nobj 0
foreach s $scopes {
    set o [get_objects -quiet $s/*]
    if {[llength $o]} { log_saif $o; incr nobj [llength $o] }
}
puts "SAIF logging [llength $scopes] module scopes, $nobj nets/ports"

set c 0
while {[get_value $TB/dut/cfg_layer_busy] eq "1"} {
    run 20ns
    incr c
}
close_saif
puts "SAIF window closes at [current_time]: $c clock cycles with layer_busy = 1"
run -all
quit
