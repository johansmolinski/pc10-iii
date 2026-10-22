# XTIDE card testbench: xtide_card + C++ bus, ROM and disk-image models.
#   make        build obj/hdc_run
#   make run    build and run
#   make lint   Verilator lint of the RTL
#   ./mut.py    mutation check (each mutant must make the bench fail)

RTL ?= ../../rtl/hdc
SRC  = $(RTL)/hdc_secbuf.sv $(RTL)/ata_dev.sv $(RTL)/xtide_card.sv
OBJ ?= obj

$(OBJ)/hdc_run: $(SRC) hdc_run.cpp
	verilator --cc --exe --build -O3 -j 4 -Wno-fatal -Wno-lint -Wno-style \
	    --Mdir $(OBJ) --top-module xtide_card -GIRQ=5 \
	    $(SRC) hdc_run.cpp -o hdc_run -CFLAGS -O2
	@true

run: $(OBJ)/hdc_run
	./$(OBJ)/hdc_run

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME --top-module xtide_card $(SRC)

.PHONY: run lint
