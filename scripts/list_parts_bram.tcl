# Lists the installed parts by block-RAM capacity (RAMB36 tiles).
# Usage: vivado -mode batch -source scripts/list_parts_bram.tcl
set fams {}
foreach p [get_parts] { dict incr fams [get_property FAMILY $p] }
puts "PARTS installed families: $fams"
set seen {}
foreach p [get_parts] {
    set dev [get_property DEVICE $p]
    if {[dict exists $seen $dev]} continue
    dict set seen $dev [list [get_property BLOCK_RAMS $p] [get_property LUT_ELEMENTS $p] [get_property FAMILY $p]]
}
foreach dev [lsort -command {apply {{a b} {global seen; expr {[lindex [dict get $seen $b] 0] - [lindex [dict get $seen $a] 0]}}}} [dict keys $seen]] {
    lassign [dict get $seen $dev] br lut fam
    if {$br >= 300} { puts "PARTS $dev family=$fam BLOCK_RAMS=$br LUTs=$lut" }
}
puts "PARTS_DONE [dict size $seen] devices"
