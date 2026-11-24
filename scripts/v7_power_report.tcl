# NEW (2026-11-14). report_power (Vivado 2026.1) on a ROUTED checkpoint with
# the activity of a SAIF recorded in 2019.1 xsim (Task B hybrid flow).
# Read-only on the checkpoint (nothing written back).
# Usage: vivado -mode batch -source scripts/v7_power_report.tcl -tclargs <post_route.dcp> <file.saif> <strip_path> <out dir> <tag>
lassign $argv dcp saif strip out tag
file mkdir $out
open_checkpoint $dcp
puts "PW $tag version [version -short] part [get_property PART [current_design]]"
read_saif -strip_path $strip $saif
report_power -file [file join $out power_$tag.rpt]
report_power -hierarchical_depth 4 -file [file join $out power_${tag}_hier.rpt]
set r [report_power -return_string]
foreach l [split $r \n] {
    if {[regexp {Total On-Chip Power|Dynamic \(W\)|Device Static|Confidence Level|Design Nets Matched|Clocks|Slice Logic|Signals|Block RAM|DSPs|I/O  |MMCM} $l]} { puts "PW $tag | [string trim $l]" }
}
puts "PW_DONE $tag"
