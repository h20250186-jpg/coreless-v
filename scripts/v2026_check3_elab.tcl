# NEW (2026-11-13). Vivado 2026.1 pre-(c) check 3, re-run of the elaboration in
# v2026_gate_b2.tcl with the message limit raised (the first run's log hit the
# default 100-message limit on Synth 8-6157) and the netlist queried directly.
# Opens the 2026.1 project of the COPY (external_2026/iisc_copy/proj_2026); the
# IPs are already upgraded, generated and synthesized out of context there.
# Usage: <VIVADO_2026_ROOT>\bin\vivado.bat -mode batch -source scripts/v2026_check3_elab.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root synth_build_2026 gate_b2]
open_project [file join $root external_2026 iisc_copy proj_2026 iisc_2026.xpr]
set_msg_config -id {Synth 8-6157} -limit 100000
set_msg_config -id {Synth 8-6155} -limit 100000
set_msg_config -id {Synth 8-439}  -limit 100000
set_msg_config -id {Synth 8-3331} -limit 100000
synth_design -rtl -name rtl_chk3 -top FPGA_WRAPPER -part xc7vx485tffg1761-2
set fh [open [file join $out elab_check3.txt] w]
set names {mainMem DMEM_0 DMEM_1 DMEM_2 DMEM_3 DMEM_4 DMEM_5 DMEM_6 DMEM_7 dcache tag_ram BTB_mem PHT_mem blk_mem_gen_v7_3 blk_mem_gen_v7_3_2 clk_wiz_0 div_gen_0 div_gen_1 xbip_dsp48_macro_0 xbip_dsp48_macro_1 xbip_dsp48_macro_2}
foreach n $names {
    set c [get_cells -quiet -hier -filter "REF_NAME == $n || ORIG_REF_NAME == $n"]
    set bb [get_cells -quiet -hier -filter "(REF_NAME == $n || ORIG_REF_NAME == $n) && IS_BLACKBOX == 1"]
    set line "CHK3 $n instances=[llength $c] blackbox=[llength $bb] e.g. [lindex $c 0]"
    puts $line; puts $fh $line
}
set allbb [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]
set refs [lsort -unique [get_property REF_NAME $allbb]]
set line "CHK3 all IS_BLACKBOX cells=[llength $allbb] refs={$refs}"
puts $line; puts $fh $line
close $fh
close_design
close_project
puts "CHK3_DONE"
