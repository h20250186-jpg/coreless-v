# NEW (2026-11-14). read_saif + report_power (Vivado 2026.1) on a ROUTED
# checkpoint, plus the share of registers / BRAM / DSP whose activity came from
# the SAIF: report_switching_activity -type <t> -all lists one line per pin with
# the source of its signal rate in brackets; (S) = from the simulation file.
# Read-only on the checkpoint.
# Usage: vivado -mode batch -source scripts/v7_rtlsaif_report.tcl -tclargs <post_route.dcp> <file.saif> <strip_path> <out dir> <tag>
lassign $argv dcp saif strip out tag
file mkdir $out
open_checkpoint $dcp
puts "RP $tag version [version -short] part [get_property PART [current_design]]"
read_saif -strip_path $strip $saif
report_power -file [file join $out power_$tag.rpt]
report_power -hierarchical_depth 4 -file [file join $out power_${tag}_hier.rpt]
set r [report_power -return_string]
foreach l [split $r \n] {
    if {[regexp {Total On-Chip Power|Dynamic \(W\)|Device Static|Confidence Level  |Design Nets Matched|^\| Clocks|^\| Slice Logic|^\| Signals|^\| Block RAM|^\| DSPs|^\| I/O  |^\| MMCM} $l]} { puts "RP $tag | [string trim $l]" }
}
foreach t {register bram_enable bram_wr_enable dsp} {
    set s [report_switching_activity -signal_rate -type $t -all -return_string]
    set tot 0; set src [dict create]
    foreach l [split $s \n] {
        if {[regexp {signal rate = \S+ \((\w+)\)} $l -> k]} { incr tot; dict incr src $k }
    }
    set parts {}
    dict for {k v} $src { lappend parts "$k=$v" }
    set sim [expr {[dict exists $src S] ? [dict get $src S] : 0}]
    puts [format "RP %s | MATCH %-15s %6d of %6d pins from SAIF (%.1f%%)  sources: %s" $tag $t $sim $tot [expr {$tot ? 100.0*$sim/$tot : 0}] [join $parts { }]]
}
puts "RP_DONE $tag"
