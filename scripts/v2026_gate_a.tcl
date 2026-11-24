# NEW (2026-11-12). Vivado 2026.1 gate test (a): are the Virtex-7 (IISc's VC707
# part) and Kintex-7 (Genesys 2 part) devices installed, and does the BASIC
# licence allow synthesis on each? A trivial 8-bit counter is synthesized per
# part. Nothing from rtl/ or external/ is read.
# Usage: <VIVADO_2026_ROOT>\bin\vivado.bat -mode batch -source scripts/v2026_gate_a.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root synth_build_2026 gate_a]
file mkdir $out
puts "GA version: [version -short]"
set parts {xc7vx485tffg1761-2 xc7k325tffg900-2}
foreach p $parts {
    set f [get_parts -quiet $p]
    puts "GA get_parts $p -> [expr {[llength $f] ? "FOUND ($f, family [get_property FAMILY [lindex $f 0]])" : "NOT FOUND"}]"
}
set v [file join $out counter.v]
set fh [open $v w]
puts $fh "module counter(input clk, input rst, output reg \[7:0\] q);"
puts $fh "  always @(posedge clk) if (rst) q <= 8'd0; else q <= q + 8'd1;"
puts $fh "endmodule"
close $fh
foreach p $parts {
    if {![llength [get_parts -quiet $p]]} { puts "GA SYNTH $p SKIPPED (part not found)"; continue }
    read_verilog $v
    if {[catch {synth_design -top counter -part $p} err]} {
        puts "GA SYNTH $p FAILED: $err"
    } else {
        puts "GA SYNTH $p OK: part=[get_property PART [current_design]] cells=[llength [get_cells -hier]] FDRE=[llength [get_cells -quiet -hier -filter {REF_NAME == FDRE}]]"
    }
    close_project -quiet
}
puts "GA_DONE"
