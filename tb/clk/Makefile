# Clock-enable testbench (rtl/system/pc_clocks.sv, doc/turbo.md section 6).
#   make          build obj/clk_run (PHASE 0) and obj5/clk_run (PHASE 5)
#   make run      the tests ref, fixed, switch on both
#   python3 mut.py   the mutants (each must make a test fail)

SRC    = ../../rtl/system/pc_clocks.sv tb_clk.sv
VFLAGS = --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style --top-module tb_clk
TESTS  = ref fixed switch

all: obj/clk_run obj5/clk_run

obj/clk_run: $(SRC) clk_run.cpp
	verilator $(VFLAGS) --Mdir obj $(SRC) clk_run.cpp -o clk_run -CFLAGS -O2
	@true

obj5/clk_run: $(SRC) clk_run.cpp
	verilator $(VFLAGS) --Mdir obj5 -GPHASE=5 $(SRC) clk_run.cpp -o clk_run -CFLAGS -O2
	@true

run: all
	@r=0; for o in obj obj5; do for t in $(TESTS); do echo "== $$o $$t"; ./$$o/clk_run $$t || r=1; done; done; exit $$r

.PHONY: all run
