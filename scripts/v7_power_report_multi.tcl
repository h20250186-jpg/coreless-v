# NEW (2026-11-19). report_power (Vivado 2026.1) for SEVERAL SAIF files on one
# routed checkpoint, opened once: for each file, reset_switching_activity -all,
# read_saif, report_power (as scripts/v7_power_report.tcl, unchanged) and the
# per-category SAIF match (as scripts/v7_rtlsaif_report.tcl, unchanged).
# Read-only on the checkpoint.
# Usage: vivado -mode batch -source scripts/v7_power_report_multi.tcl -tclargs <dcp> <strip_path> <out dir> <saif1> <tag1> [<saif2> <tag2> ...]
set dcp [lindex $argv 0]; set strip [lindex $argv 1]; set out [lindex $argv 2]
file mkdir $out
open_checkpoint $dcp
puts "PM version [version -short] part [get_property PART [current_design]]"
foreach {saif tag} [lrange $argv 3 end] {
    reset_switching_activity -all
    read_saif -strip_path $strip $saif
    report_power -file [file join $out power_$tag.rpt]
    report_power -hierarchical_depth 4 -file [file join $out power_${tag}_hier.rpt]
    set r [report_power -return_string]
    foreach l [split $r \n] {
        if {[regexp {Total On-Chip Power|Dynamic \(W\)|Device Static|Confidence Level  |Design Nets Matched|^\| Clocks|^\| Slice Logic|^\| Signals|^\| Block RAM|^\| DSPs|^\| I/O  |^\| MMCM} $l]} { puts "PM $tag | [string trim $l]" }
    }
    foreach t {register bram_enable bram_wr_enable dsp} {
        set s [report_switching_activity -signal_rate -type $t -all -return_string]
        set tot 0; set sim 0
        foreach l [split $s \n] {
            if {[regexp {signal rate = \S+ \((\w+)\)} $l -> k]} { incr tot; if {$k eq "S"} { incr sim } }
        }
        puts [format "PM %s | MATCH %-15s %6d of %6d pins from SAIF (%.1f%%)" $tag $t $sim $tot [expr {$tot ? 100.0*$sim/$tot : 0}]]
    }
}
puts "PM_DONE"
