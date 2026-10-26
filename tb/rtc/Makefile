# Real-time clock testbench (doc/rtc.md section 8).
#   make          build obj/rtc_run (the exact 32.768 kHz oscillator) and
#                 obj_fast/rtc_run (32.768 kHz = clk / 8)
#   make run      all tests of both builds, in parallel; logs in $(OUT)
#   python3 mut.py   the mutants

SRC    = ../../rtl/system/msm6242.sv
VFLAGS = --cc --exe --build -O3 -j 0 -Wall -Wno-fatal -Wno-UNUSEDSIGNAL --top-module msm6242
COPT   = -CFLAGS -O3 -CFLAGS -march=native
OUT   ?= $(HOME)/pcxt-work/rtc/tb
EXACT  = bios calendar hold adjust stoprest irq seed
FAST   = calendar torture1 torture2 torture3 torture4

all: obj/rtc_run obj_fast/rtc_run

obj/rtc_run: $(SRC) rtc_run.cpp rtc_model.h
	verilator $(VFLAGS) --Mdir obj $(SRC) rtc_run.cpp -o rtc_run $(COPT)
	@true

obj_fast/rtc_run: $(SRC) rtc_run.cpp rtc_model.h
	verilator $(VFLAGS) --Mdir obj_fast -GOSC_NUM=1 -GOSC_DEN=8 $(SRC) rtc_run.cpp -o rtc_run \
	    $(COPT) -CFLAGS -DOSC_NUM=1u -CFLAGS -DOSC_DEN=8u
	@true

run: all
	mkdir -p $(OUT)
	( for t in $(EXACT); do echo "obj $$t"; done; for t in $(FAST); do echo "obj_fast $$t"; done ) | \
	    xargs -P 12 -L 1 sh -c './$$0/rtc_run $$1 > $(OUT)/$$0_$$1.log 2>&1'; \
	grep -h -E "^[a-z0-9]+: (PASS|FAIL)" $(OUT)/obj*_*.log; \
	! grep -l -E "^[a-z0-9]+: FAIL|^FAIL" $(OUT)/obj*_*.log

.PHONY: all run
