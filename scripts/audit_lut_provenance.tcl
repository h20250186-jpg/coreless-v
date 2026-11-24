# READ-ONLY provenance audit of the out-of-context checkpoints (no run is
# changed, no checkpoint is written). Opens each routed checkpoint and prints
#   - the Slice LUT total and per-instance Slice LUTs (report_utilization -cells)
#   - LUT PRIMITIVE counts per scope (each LUT cell counted once, so these
#     sum exactly; Slice LUT rows of the hierarchical report can count a
#     shared LUT site in two instances)
#   - divider LUTs inside the I2SRV32-V vector unit
#   - the DSP48E1 cells of our controller
# Usage: vivado -mode batch -source scripts/audit_lut_provenance.tcl
set root [file normalize [file join [file dirname [info script]] .. synth_build]]

proc slut {cells} {
    if {![llength $cells]} { return 0 }
    set r [report_utilization -cells $cells -return_string]
    foreach l [split $r \n] {
        if {[regexp {^\|\s*Slice LUTs\*?\s*\|\s*(\d+)} $l -> v]} { return $v }
    }
    return ?
}
proc nlut {pattern} {
    return [llength [get_cells -quiet -hier -filter "IS_PRIMITIVE && REF_NAME =~ LUT* && NAME =~ $pattern"]]
}
proc ndsp {pattern} {
    return [llength [get_cells -quiet -hier -filter "IS_PRIMITIVE && REF_NAME =~ DSP48* && NAME =~ $pattern"]]
}

# ---------- I2SRV32-V cpu + vector, out of context, post-route
open_checkpoint [file join $root iisc_ooc_both post_route.dcp]
puts "AUDIT BOTH design=[get_property TOP [current_design]] part=[get_property PART [current_design]]"
puts "AUDIT BOTH slice LUTs total             = [slut [get_cells -quiet *]]"
set vu [get_cells fdem/Pipeline/VECTOR_UNIT]
puts "AUDIT BOTH slice LUTs VECTOR_UNIT       = [slut $vu]"
puts "AUDIT BOTH LUT primitives total         = [nlut *]"
puts "AUDIT BOTH LUT primitives VECTOR_UNIT   = [nlut fdem/Pipeline/VECTOR_UNIT/*]"
puts "AUDIT BOTH LUT primitives outside it    = [expr {[nlut *] - [nlut fdem/Pipeline/VECTOR_UNIT/*]}]"
foreach s {fdem/Pipeline/FP_EX fdem/db1 fdem/mh fdem/Pipeline/c1 fdem/Pipeline/EX fdem/Pipeline/FP_RF} {
    puts "AUDIT BOTH LUT primitives $s = [nlut $s/*] ; slice LUTs = [slut [get_cells $s]]"
}
set dv [get_cells -quiet -hier -filter {!IS_PRIMITIVE && NAME =~ fdem/Pipeline/VECTOR_UNIT/* && (NAME =~ *GEN_DIVIDERs*/signed_divider || NAME =~ *GEN_DIVIDERs*/unsigned_divider)}]
puts "AUDIT BOTH divider IP instances         = [llength $dv]"
puts "AUDIT BOTH slice LUTs of divider IPs    = [slut $dv]"
puts "AUDIT BOTH LUT primitives in dividers   = [nlut fdem/Pipeline/VECTOR_UNIT/*GEN_DIVIDERs*]"
close_design

# ---------- I2SRV32-V vector_top alone, out of context, post-route
open_checkpoint [file join $root iisc_ooc_vector post_route.dcp]
puts "AUDIT VEC design=[get_property TOP [current_design]] part=[get_property PART [current_design]]"
puts "AUDIT VEC slice LUTs total              = [slut [get_cells -quiet *]]"
puts "AUDIT VEC LUT primitives total          = [nlut *]"
set dv [get_cells -quiet -hier -filter {!IS_PRIMITIVE && (NAME =~ *GEN_DIVIDERs*/signed_divider || NAME =~ *GEN_DIVIDERs*/unsigned_divider)}]
puts "AUDIT VEC divider IP instances          = [llength $dv]"
puts "AUDIT VEC slice LUTs of divider IPs     = [slut $dv]"
puts "AUDIT VEC LUT primitives in dividers    = [nlut *GEN_DIVIDERs*]"
puts "AUDIT VEC block RAM cells: [llength [get_cells -quiet -hier -filter {IS_PRIMITIVE && REF_NAME =~ RAMB*}]] ; under DMEM*: [llength [get_cells -quiet -hier -filter {IS_PRIMITIVE && REF_NAME =~ RAMB* && NAME =~ *DMEM*}]]"
close_design

# ---------- Coreless-V atee_top, out of context, post-route
open_checkpoint [file join $root atee_ooc_atee_top post_route.dcp]
puts "AUDIT ATEE design=[get_property TOP [current_design]] part=[get_property PART [current_design]]"
puts "AUDIT ATEE slice LUTs total             = [slut [get_cells -quiet *]]"
puts "AUDIT ATEE slice LUTs u_vec_unit        = [slut [get_cells u_vec_unit]]"
puts "AUDIT ATEE LUT primitives total         = [nlut *]"
puts "AUDIT ATEE LUT primitives u_vec_unit    = [nlut u_vec_unit/*]"
puts "AUDIT ATEE LUT primitives u_hbm_lite    = [nlut u_hbm_lite/*]"
puts "AUDIT ATEE LUT primitives u_config      = [nlut u_config/*]"
puts "AUDIT ATEE LUT primitives outside u_vec_unit = [expr {[nlut *] - [nlut u_vec_unit/*]}]"
puts "AUDIT ATEE block RAM cells: [llength [get_cells -quiet -hier -filter {IS_PRIMITIVE && REF_NAME =~ RAMB*}]]"
puts "AUDIT ATEE DSP under u_hbm_lite = [ndsp u_hbm_lite/*] ; under u_vec_unit = [ndsp u_vec_unit/*]"
close_design

# ---------- Coreless-V hbm_lite_controller, out of context, post-route
open_checkpoint [file join $root atee_ooc_hbm_lite_controller post_route.dcp]
set d [get_cells -hier -filter {IS_PRIMITIVE && REF_NAME =~ DSP48*}]
puts "AUDIT CTRL DSP48 cells = [llength $d] ; under u_outsize: [ndsp u_outsize/*]"
foreach c [lsort $d] { puts "AUDIT CTRL DSP $c" }
close_design
puts "AUDIT_DONE"
