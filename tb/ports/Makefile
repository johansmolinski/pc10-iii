# The PC10-III's ports (doc/ports.md section 7): the 8250 serial port, the
# parallel port, the 5720's bus mouse, the audio mixer with the Covox.
#   make          build obj_<block>/<block>_run
#   make run      all tests; logs in $(OUT)/run
#   python3 mut.py   the mutants

RTL    = ../../rtl/system
VFLAGS = --cc --exe --build -O2 -j 0 -Wall -Wno-fatal -Wno-UNUSEDSIGNAL
OUT   ?= $(HOME)/pcxt-work/ports/tb
BLOCKS = uart lpt mouse mix
SRC_uart  = $(RTL)/uart8250.sv
SRC_lpt   = $(RTL)/lpt_ppc1.sv
SRC_mouse = $(RTL)/cbm_mouse.sv
SRC_mix   = $(RTL)/pc_audio_mix.sv
TOP_uart  = uart8250
TOP_lpt   = lpt_ppc1
TOP_mouse = cbm_mouse
TOP_mix   = pc_audio_mix

all: $(foreach b,$(BLOCKS),obj_$(b)/$(b)_run)

define blk
obj_$(1)/$(1)_run: $$(SRC_$(1)) $(1)_run.cpp bus.h $$(wildcard $(1)_model.h)
	verilator $$(VFLAGS) --top-module $$(TOP_$(1)) --Mdir obj_$(1) $$(SRC_$(1)) $(1)_run.cpp -o $(1)_run -CFLAGS -O2 -CFLAGS -I$$(CURDIR)
	@true
endef
$(foreach b,$(BLOCKS),$(eval $(call blk,$(b))))

run: all
	mkdir -p $(OUT)/run
	for b in $(BLOCKS); do ./obj_$$b/$${b}_run > $(OUT)/run/$$b.log 2>&1 & done; wait; \
	grep -h -E "^[a-z0-9]+: (PASS|FAIL)|tests,|^random:|^range:|^gain|^decay" $(OUT)/run/*.log; \
	! grep -l -E "^[a-z0-9]+: FAIL|^FAIL|MISMATCH" $(OUT)/run/*.log

.PHONY: all run
