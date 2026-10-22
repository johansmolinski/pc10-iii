# cpu8088.xdc - timing exceptions of the 8088 (rtl/cpu/cpu8088.sv). Read it
# scoped to the module (read_xdc -ref cpu8088, or SCOPED_TO_REF cpu8088 in a
# project); the cell names are relative to a cpu8088 instance.
# The biu88 part applies with either CPU, the EU part with CPU = "z86".
#
# biu88's step (rtl/cpu/mcl86/biu88.v, "Timing structure"): the step's work on
# the bus state (do_cycle and the EU request phases, MartyPC's state machine)
# and the EU events of the step's clock and of the clock after it are applied
# two clocks after the step (biu88 signal win2), from
#
#   bd*   a copy of the bus state (its six candidates and their choice) and
#   sn_*  a copy of the fast values the step reads: written on every clock
#         except the step's and the next (biu88 signal hold = step | win1), so
#         two clocks after the step they still hold what was written on the
#         clock before it: three clocks;
#   p1_*  the events of the step's clock, written on that clock only: two
#         clocks.
#
# (pw_*, the events of the clock after the step, are read on the next clock:
# no exception.) The steps are the rising CLK edges of the 8088: every 21 clk
# in the system, 20 or 21 in the SingleStepTests harness, so no step falls on
# the two clocks after a step and these registers do not change between their
# write and win2. On every other clock the logic they feed is not used (the
# bus state takes the per-clock path), and they feed nothing else. Hold
# checks stay at the launch edge.
# (biu88 is cpu8088's g_mcl86.biu or g_z86.cpu/biu: matched by name.)
set_multicycle_path 3 -setup -from [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ *biu/bd*_reg* || NAME =~ *biu/sn_*_reg*)}]
set_multicycle_path 2 -hold  -from [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ *biu/bd*_reg* || NAME =~ *biu/sn_*_reg*)}]
set_multicycle_path 2 -setup -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *biu/p1_*_reg*}]
set_multicycle_path 1 -hold  -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *biu/p1_*_reg*}]

# z8086's EU (rtl/cpu/z8086/z86_eu.sv, CPU = "z86"): every register of the
# module changes only at its clock enable, once per 8088 clock (the step
# delayed by 3 clk; every clk while the CPU is in reset, when all its inputs
# are static), and is only taken at that enable. So a path from one EU
# register to another has at least the distance between two enables: 21 clk
# in the system, 20 or 21 in the SingleStepTests harness, 3 on a 28.636 MHz
# board at 9.54 MHz (doc/clock-plan.md). Two clocks are claimed here. Paths
# into the EU from biu88, the adapter (cpu_z86.sv) and the tables
# (z86_tables.sv), and out of it, keep their single clock. Hold at the launch
# edge.
set_multicycle_path 2 -setup -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *g_z86.cpu/eu/*}] -to [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *g_z86.cpu/eu/*}]
set_multicycle_path 1 -hold  -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *g_z86.cpu/eu/*}] -to [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *g_z86.cpu/eu/*}]
