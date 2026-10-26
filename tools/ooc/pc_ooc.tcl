# pc_ooc.tcl - out-of-context synthesis + implementation of the PC side
# (tools/ooc/pc_ooc_top.sv: pc_system with all its cards, the shell's pc_ram, the
# ROMs as block RAMs) for the MEGA65 R6 part at 28.63636 MHz, the PC's one clock
# (doc/clock-plan.md). No multicycle paths, no exceptions.
#   cd <repo>/tools/ooc && vivado -mode batch -source pc_ooc.tcl [-tclargs synth]
# Results: ./out_pc/ (utilization, timing summary, critical paths).
set here [file normalize [file dirname [info script]]]
set rtl  [file normalize $here/../../rtl]
set core [file normalize $here/../../CORE]
set synth_only [expr {[llength $argv] > 0 && [lindex $argv 0] eq "synth"}]
file mkdir $here/out_pc
set_part xc7a200tfbg484-2
set kf $rtl/system/kf
read_verilog -sv [concat \
    [list $rtl/cpu/z8086/alu.sv $rtl/cpu/z8086/z86_tables.sv $rtl/cpu/z8086/z86_eu.sv \
          $rtl/cpu/z8086/cpu_z86.sv $rtl/cpu/biu88.sv $rtl/cpu/cpu8088.sv] \
    [glob $kf/KF8237/*.sv] [glob $kf/KF8253/*.sv] [glob $kf/KF8255/*.sv] [glob $kf/KF8259/*.sv] \
    [list $rtl/system/pc_clocks.sv $rtl/system/xt_board.sv $rtl/system/pc_system.sv \
          $rtl/video/cga/cga_crtc.sv $rtl/video/cga/cga_card.sv $rtl/video/mda/mda_card.sv \
          $rtl/video/pvc4/pvc4.sv $rtl/system/cbm_cfg230.sv \
          $rtl/fdc/upd765.sv $rtl/fdc/fdc_secbuf.sv $rtl/fdc/fdc_card.sv \
          $rtl/hdc/hdc_secbuf.sv $rtl/hdc/ata_dev.sv $rtl/hdc/xtide_card.sv $rtl/hdc/xta_card.sv \
          $here/pc_ooc_top.sv]]
read_vhdl -vhdl2008 $core/vhdl/pc_ram.vhd
set clkxdc [open $here/out_pc/clk.xdc w]
puts $clkxdc {create_clock -name clk -period 34.921 [get_ports clk]}
close $clkxdc
read_xdc $here/out_pc/clk.xdc
synth_design -top pc_ooc_top -mode out_of_context -flatten_hierarchy rebuilt \
    -include_dirs [list $kf/KF8237 $kf/KF8253 $kf/KF8255 $kf/KF8259 $rtl/cpu/z8086]
report_utilization -file $here/out_pc/synth_util.rpt
report_timing_summary -max_paths 10 -file $here/out_pc/synth_timing.rpt
if {$synth_only} { exit }
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $here/out_pc/util.rpt
report_utilization -hierarchical -file $here/out_pc/util_hier.rpt
report_timing_summary -max_paths 10 -file $here/out_pc/timing.rpt
report_timing -max_paths 30 -nworst 1 -sort_by group -file $here/out_pc/paths.rpt
report_design_analysis -logic_level_distribution -file $here/out_pc/levels.rpt
report_exceptions -file $here/out_pc/exceptions.rpt
write_checkpoint -force $here/out_pc/pc_ooc_routed.dcp
