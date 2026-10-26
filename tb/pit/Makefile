# 8253 testbench (rtl/system/kf/KF8253): the read/write byte sequence and the latch.
#   make          build obj/pit_run
#   make run      all tests
#   python3 mut.py   the mutants

KF     = ../../rtl/system/kf/KF8253
SRC    = $(KF)/KF8253_Control_Logic.sv $(KF)/KF8253_Counter.sv $(KF)/KF8253.sv
VFLAGS = --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style -I$(KF) --top-module KF8253

obj/pit_run: $(SRC) pit_run.cpp
	verilator $(VFLAGS) --Mdir obj $(SRC) pit_run.cpp -o pit_run -CFLAGS -O2
	@true

run: obj/pit_run
	./obj/pit_run

.PHONY: run
