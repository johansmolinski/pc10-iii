# cpu8088.xdc - timing exceptions of the 8088 (rtl/cpu/cpu8088.sv). Read it
# scoped to the module (read_xdc -ref cpu8088, or SCOPED_TO_REF cpu8088 in a
# project); the cell names are relative to a cpu8088 instance.
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
set_multicycle_path 3 -setup -from [get_cells -filter {IS_SEQUENTIAL} {biu/bd*_reg* biu/sn_*_reg*}]
set_multicycle_path 2 -hold  -from [get_cells -filter {IS_SEQUENTIAL} {biu/bd*_reg* biu/sn_*_reg*}]
set_multicycle_path 2 -setup -from [get_cells -filter {IS_SEQUENTIAL} {biu/p1_*_reg*}]
set_multicycle_path 1 -hold  -from [get_cells -filter {IS_SEQUENTIAL} {biu/p1_*_reg*}]
