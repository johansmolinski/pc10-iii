# Wait-state generator testbench (rtl/system/xt_wait.sv, doc/turbo.md section 6).
#   make          build obj/wait_run
#   make run      400,000 random bus cycles, three seeds
#   python3 mut.py   the mutants (each must make the bench fail)

SRC = ../../rtl/system/xt_wait.sv tb_wait.sv

obj/wait_run: $(SRC) wait_run.cpp
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style --top-module tb_wait \
	    --Mdir obj $(SRC) wait_run.cpp -o wait_run -CFLAGS -O2
	@true

run: obj/wait_run
	@r=0; for s in 1 2 3; do ./obj/wait_run 400000 $$s || r=1; done; exit $$r

.PHONY: run
