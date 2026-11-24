# NEW (2026-11-15). xsim batch script for iisc_tb_bench: run until the
# testbench's $stop (end of the measured run), then read the final contents of
# the 8 DMEM bank models and the 8 VRF banks with get_value and write them to
# dmem_<b>.txt / vrf_<b>.txt in the run directory (one value per line, in the
# order get_value returns them; the check script verifies the DMEM order against
# the initial image). Read only; nothing in the design is forced.
# Escaped generate names (\GEN_VRFS(0)\ , \native_mem_module.blk_mem_gen_v8_4_4_inst )
# are entered with current_scope on the names get_scopes returns.
set EU /iisc_tb_bench/dut/cpu1/fdem/Pipeline/VECTOR_UNIT/VEC_EXE_UNIT/wrapper_vhd/VECTOR_EXE_UNIT_PIPE
proc dumpval {obj fn} {
    set v [get_value -radix hex $obj]
    set f [open $fn w]
    foreach x [split [string map {"\{" " " "\}" " " "," " "} $v] " "] { if {$x ne ""} { puts $f $x } }
    close $f
}
run -all
set_property array_display_limit 65536 [current_sim]
puts "DUMP array_display_limit [get_property array_display_limit [current_sim]]"
puts "DUMP stopped at [current_time]"
for {set b 0} {$b < 8} {incr b} {
    current_scope $EU/DMEM$b/inst
    current_scope [lindex [get_scopes] 0]
    dumpval memory "dmem_$b.txt"
}
puts "DUMP dmem written"
set b 0
foreach i {0 1 2 3 4 5 6 7} {
    current_scope $EU
    set s [lsearch -inline -all [get_scopes] "*GEN_VRFS($i)*"]
    current_scope [lindex $s 0]
    current_scope vrf_gen
    dumpval vec_reg "vrf_$b.txt"
    incr b
}
puts "DUMP vrf written ($b banks)"
quit
