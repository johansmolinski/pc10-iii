# cpu_ooc.tcl - out-of-context synthesis + implementation of the CPU alone
# (rtl/cpu/cpu8088.sv: MCL86 EU + biu88 + microcode ROM) for the MEGA65 R6 part
# at 100.2273 MHz, with the CPU's constraints (rtl/cpu/cpu8088.xdc, scoped to
# cpu8088 as in the system).
#   cd <repo>/tools/ooc && vivado -mode batch -source cpu_ooc.tcl [-tclargs synth|explore]
# Results: ./out/ (utilization, timing summary, critical paths). With "synth"
# the run stops after synthesis (quick estimate); with "explore" the
# implementation uses the directives of the shell's impl_1 strategy
# (Performance_ExplorePostRoutePhysOpt: Explore for opt/place/phys_opt/route
# and a phys_opt_design after routing), otherwise the defaults.
set here [file normalize [file dirname [info script]]]
set cpu  [file normalize $here/../../rtl/cpu]
set rtl  $cpu/mcl86
set synth_only [expr {[llength $argv] > 0 && [lindex $argv 0] eq "synth"}]
set explore    [expr {[llength $argv] > 0 && [lindex $argv 0] eq "explore"}]
# optional second argument: another place_design directive (with "explore")
set placedir   [expr {[llength $argv] > 1 ? [lindex $argv 1] : "Explore"}]
file mkdir $here/out
set_part xc7a200tfbg484-2
read_verilog $here/cpu_ooc_top.v $rtl/eu.v $rtl/biu88.v $rtl/eu_rom.v
read_verilog -sv $cpu/cpu8088.sv
set clkxdc [open $here/out/clk.xdc w]
puts $clkxdc {create_clock -name clk -period 9.977 [get_ports clk]}
close $clkxdc
read_xdc $here/out/clk.xdc
if {[file exists $cpu/cpu8088.xdc]} {
    read_xdc -ref cpu8088 $cpu/cpu8088.xdc
}
synth_design -top cpu_ooc_top -mode out_of_context -flatten_hierarchy rebuilt \
    -verilog_define MCL86_ROM=\"$rtl/microcode.hex\"
report_utilization -file $here/out/synth_util.rpt
report_timing_summary -max_paths 10 -file $here/out/synth_timing.rpt
report_timing -max_paths 30 -nworst 1 -sort_by group -file $here/out/synth_paths.rpt
if {$synth_only} { exit }
if {$explore} {
    opt_design -directive Explore
    place_design -directive $placedir
    phys_opt_design -directive Explore
    route_design -directive Explore
    phys_opt_design -directive Explore
} else {
    opt_design
    place_design
    phys_opt_design
    route_design
}
report_utilization -file $here/out/util.rpt
report_utilization -hierarchical -file $here/out/util_hier.rpt
report_timing_summary -max_paths 10 -file $here/out/timing.rpt
report_timing -max_paths 30 -nworst 1 -sort_by group -file $here/out/paths.rpt
report_design_analysis -logic_level_distribution -file $here/out/levels.rpt
# by region: EU, BIU (the multicycle sources of biu88's step apart: bd*, sn_*, p1_*)
set eu  [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ cpu/eu/*}]
set win [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ cpu/biu/bd* || NAME =~ cpu/biu/sn_* || NAME =~ cpu/biu/p1_*)}]
set biu [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ cpu/biu/* && NAME !~ cpu/biu/bd* && NAME !~ cpu/biu/sn_* && NAME !~ cpu/biu/p1_*}]
report_timing -max_paths 5 -nworst 1 -from $eu  -to $eu  -file $here/out/eu2eu.rpt
report_timing -max_paths 5 -nworst 1 -from $eu  -to [concat $biu $win] -file $here/out/eu2biu.rpt
report_timing -max_paths 5 -nworst 1 -from [concat $biu $win] -to $eu -file $here/out/biu2eu.rpt
report_timing -max_paths 5 -nworst 1 -from $biu -to [concat $biu $win] -file $here/out/biu2biu.rpt
if {[llength $win]} { report_timing -max_paths 5 -nworst 1 -from $win -file $here/out/window.rpt }
report_exceptions -file $here/out/exceptions.rpt
# the registers (base names), to spot unintended ones
set fh [open $here/out/regs.rpt w]
foreach n [lsort -unique [regsub -all {(_reg)?(\[[0-9]+\])?(_replica[_0-9]*)?} [get_property NAME [get_cells -hier -filter {IS_SEQUENTIAL}]] ""]] { puts $fh $n }
close $fh
write_checkpoint -force $here/out/cpu_ooc_routed.dcp
