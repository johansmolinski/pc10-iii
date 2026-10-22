# cpu8088.xdc - timing exceptions of the 8088 (rtl/cpu/cpu8088.sv). Read it
# scoped to the module (read_xdc -ref cpu8088, or SCOPED_TO_REF cpu8088 in a
# project); the cell names are relative to a cpu8088 instance.
#
# The 8088 (CPU = "z86"): z8086's EU (rtl/cpu/z8086/z86_eu.sv) and biu88
# (rtl/cpu/biu88.sv) change state once per 8088 clock each:
#   - biu88 at `step` (the rising CLK edge): every 21 clk in the system, 20 or
#     21 in the SingleStepTests harness, at least 10 at the 9.54 MHz turbo
#     speed should it ever run on this clock;
#   - the EU at its clock enable, `step` + 3 clk (cpu_z86.sv EU_DELAY), and
#     every clk while the CPU is in reset, when all its inputs are static.
# Each takes what the other set at its own enable: biu88 the EU's outputs of
# its last clock, the EU biu88's outputs after the step. So a path from a
# register of either to a register of either has at least 3 clk: EU -> EU
# and biu88 -> biu88 a whole 8088 clock, biu88 -> EU the 3 clk of EU_DELAY,
# EU -> biu88 the rest of the 8088 clock. Three clocks are claimed. Paths
# from the tables (z86_tables.sv, block and distributed RAM read every clk)
# and from the board (READY, the data bus) keep their single clock. Hold at
# the launch edge.
set_multicycle_path 3 -setup -from [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ *g_z86.cpu/eu/* || NAME =~ *g_z86.cpu/biu/*)}] -to [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ *g_z86.cpu/eu/* || NAME =~ *g_z86.cpu/biu/*)}]
set_multicycle_path 2 -hold  -from [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ *g_z86.cpu/eu/* || NAME =~ *g_z86.cpu/biu/*)}] -to [get_cells -hier -filter {IS_SEQUENTIAL && (NAME =~ *g_z86.cpu/eu/* || NAME =~ *g_z86.cpu/biu/*)}]
