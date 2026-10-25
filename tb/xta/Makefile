# PC20-III hard disk testbench: xta_card + C++ bus, 8237 channel 3, backend
# and reference models (doc/xta.md section 10).
#   make        build obj/xta_run
#   make run    build and run (make run ARGS=-f: also format the whole drive)
#   make lint   Verilator lint of the RTL
#   ./mut.py    mutation check (each mutant must make the bench fail)

RTL ?= ../../rtl/hdc
SRC  = $(RTL)/hdc_secbuf.sv $(RTL)/xta_card.sv
OBJ ?= obj
# a short spin-up for the bench (the card's default is 5 s)
GEN  = -GSPINUP_MS=5

$(OBJ)/xta_run: $(SRC) xta_run.cpp
	verilator --cc --exe --build -O3 -j 4 -Wno-fatal -Wno-lint -Wno-style \
	    --Mdir $(OBJ) --top-module xta_card $(GEN) \
	    $(SRC) xta_run.cpp -o xta_run -CFLAGS -O2
	@true

run: $(OBJ)/xta_run
	./$(OBJ)/xta_run $(ARGS)

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME --top-module xta_card $(SRC)

.PHONY: run lint
