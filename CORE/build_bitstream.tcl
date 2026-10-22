# Build one board bitstream in Vivado batch mode (called by build_all.sh):
#
#   vivado -mode batch -source build_bitstream.tcl -tclargs <R6> [jobs]
#
# Prints one "RESULT <board> ..." line and exits non-zero on any failure. After the bitstream
# the routed design is opened and the sign-off gates are checked (constraints that silently
# no-op when instance names drift).

set board [lindex $argv 0]
set jobs  [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]

open_project CORE-${board}.xpr

reset_run synth_1
# Reference build (REF_DIR in build_all.sh, REF= in tools/remote/rbuild.sh): incremental
# synthesis and implementation from that build's checkpoints; cleared again afterwards so
# the .xpr stays unchanged.
set synth_ref [expr {[info exists ::env(REF_SYNTH_DCP)] ? $::env(REF_SYNTH_DCP) : ""}]
set impl_ref  [expr {[info exists ::env(REF_DCP)] ? $::env(REF_DCP) : ""}]
if {$synth_ref ne ""} {
    puts "REF_SYNTH_DCP: incremental synthesis from $synth_ref"
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
    set_property INCREMENTAL_CHECKPOINT $synth_ref [get_runs synth_1]
}
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {$synth_ref ne ""} {
    set_property INCREMENTAL_CHECKPOINT "" [get_runs synth_1]
    catch {remove_files -quiet -fileset utils_1 [get_files -quiet -of_objects [get_filesets utils_1] $synth_ref]}
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "RESULT $board FAILED synth_1: [get_property STATUS [get_runs synth_1]]"
    exit 1
}

# with CPU = "mcl86" the MCL86 microcode ROM must have been read (a missing file is only a
# warning: a dead CPU). The default CPU (z86) has no microcode in the bitstream: it is loaded
# from the SD card (pc_ucode.vhd, AGENTS.md rule 4).
set synth_log [file join [get_property DIRECTORY [get_runs synth_1]] runme.log]
set uc_gate ""
set f [open $synth_log r]; set log [read $f]; close $f
if {[string match *MCL86_ROM* [get_property verilog_define [current_fileset]]] &&
    [regexp {synthesizing module 'mcl86_eu_core} $log]} {
    if {![regexp {microcode\.hex' is read successfully} $log]} {
        set uc_gate "the MCL86 microcode image was not read by synthesis"
    }
}

if {$impl_ref ne ""} {
    puts "REF_DCP: incremental implementation from $impl_ref"
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs impl_1]
    set_property INCREMENTAL_CHECKPOINT $impl_ref [get_runs impl_1]
}
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {$impl_ref ne ""} {
    set_property INCREMENTAL_CHECKPOINT "" [get_runs impl_1]
    catch {remove_files -quiet -fileset utils_1 [get_files -quiet -of_objects [get_filesets utils_1] $impl_ref]}
}
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "RESULT $board FAILED impl_1: [get_property STATUS [get_runs impl_1]]"
    exit 1
}

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
open_run impl_1
report_utilization -hierarchical -file CORE-${board}.runs/impl_1/utilization_hierarchical.rpt
report_timing -max_paths 50 -nworst 1 -sort_by group -file CORE-${board}.runs/impl_1/worst_paths.rpt
set gate {}
if {$uc_gate ne ""} { lappend gate $uc_gate }
foreach {clk want} {main_clk 9.977 video_clk 34.921} {
    set c [get_clocks -quiet $clk]
    if {[llength $c] == 0} {
        lappend gate "generated clock $clk missing"
    } elseif {[expr {abs([get_property PERIOD $c] - $want)}] > 0.01} {
        lappend gate "$clk period [get_property PERIOD $c] ns, expected $want ns"
    }
}
if {[llength [get_cells -quiet -hierarchical -filter {NAME =~ CORE/i_pc_fdd_sd/i_cdc_geo/*dst_data_o_reg*}]] == 0} {
    lappend gate "multicycle target CORE/i_pc_fdd_sd/i_cdc_geo missing"
}
if {[llength [get_cells -quiet -hierarchical -filter {NAME =~ CORE/i_pc_ram/* && REF_NAME =~ RAMB*}]] < 160} {
    lappend gate "pc_ram has fewer than 160 block RAM primitives (640 KB optimised away?)"
}
if {[llength $gate] > 0} {
    foreach g $gate { puts "GATE $board: $g" }
    puts "RESULT $board SIGNOFF-FAILED WNS=$wns WHS=$whs"
    exit 3
}
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
    puts "RESULT $board TIMING-FAILED WNS=$wns WHS=$whs bit=CORE-${board}.runs/impl_1/mega65_[string tolower $board].bit"
    exit 2
}
puts "RESULT $board OK WNS=$wns WHS=$whs bit=CORE-${board}.runs/impl_1/mega65_[string tolower $board].bit"
close_project
