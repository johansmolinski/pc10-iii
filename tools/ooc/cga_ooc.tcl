# cga_ooc.tcl - out-of-context synthesis + implementation of the CGA card
# alone for the MEGA65 R6 part at 28.63636 MHz.
#   cd <repo>/tools/ooc && vivado -mode batch -source cga_ooc.tcl
# Results: ./out_cga/ (utilization, timing summary, critical paths).
set here [file normalize [file dirname [info script]]]
set rtl  [file normalize $here/../../rtl/video/cga]
file mkdir $here/out_cga
set_part xc7a200tfbg484-2
read_verilog -sv [list $rtl/cga_crtc.sv $rtl/cga_card.sv]
synth_design -top cga_card -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name clk -period 34.921 [get_ports clk]
report_utilization -file $here/out_cga/synth_util.rpt
report_timing_summary -file $here/out_cga/synth_timing.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $here/out_cga/util.rpt
report_utilization -hierarchical -file $here/out_cga/util_hier.rpt
report_timing_summary -max_paths 10 -file $here/out_cga/timing.rpt
report_timing -max_paths 20 -nworst 1 -sort_by group -file $here/out_cga/paths.rpt
report_design_analysis -logic_level_distribution -file $here/out_cga/levels.rpt
