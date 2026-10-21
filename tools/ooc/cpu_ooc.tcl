# cpu_ooc.tcl - out-of-context synthesis + implementation of the CPU alone
# (MCL86 EU + biu88 + microcode ROM) for the MEGA65 R6 part at 100.2273 MHz.
#   cd <repo>/tools/ooc && vivado -mode batch -source cpu_ooc.tcl
# Results: ./out/ (utilization, timing summary, critical paths).
set here [file normalize [file dirname [info script]]]
set rtl  [file normalize $here/../../rtl/cpu/mcl86]
file mkdir $here/out
set_part xc7a200tfbg484-2
read_verilog $here/cpu_ooc_top.v $rtl/eu.v $rtl/biu88.v $rtl/eu_rom.v
set_property verilog_define [list MCL86_ROM=\"$rtl/microcode.hex\"] [current_fileset]
synth_design -top cpu_ooc_top -mode out_of_context -flatten_hierarchy rebuilt \
    -verilog_define MCL86_ROM=\"$rtl/microcode.hex\"
create_clock -name clk -period 9.977 [get_ports clk]
report_utilization -file $here/out/synth_util.rpt
report_timing_summary -file $here/out/synth_timing.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $here/out/util.rpt
report_utilization -hierarchical -file $here/out/util_hier.rpt
report_timing_summary -max_paths 10 -file $here/out/timing.rpt
report_timing -max_paths 20 -nworst 1 -sort_by group -file $here/out/paths.rpt
report_design_analysis -logic_level_distribution -file $here/out/levels.rpt
write_checkpoint -force $here/out/cpu_ooc_routed.dcp
