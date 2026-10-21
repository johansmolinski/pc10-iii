# FDC card testbench: fdc_card + C++ bus, DMA and disk-image models.
#   make        build obj/fdc_run
#   make run    build and run (images written to $(OUT))
#   make lint   Verilator lint of the RTL

RTL = ../../rtl/fdc
SRC = $(RTL)/upd765.sv $(RTL)/fdc_secbuf.sv $(RTL)/fdc_card.sv
OBJ ?= obj
OUT ?= $(HOME)/pcxt-work/fdc

$(OBJ)/fdc_run: $(SRC) fdc_run.cpp
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-MULTIDRIVEN \
	    --Mdir $(OBJ) --top-module fdc_card \
	    $(SRC) fdc_run.cpp -o fdc_run -CFLAGS -O2
	@true

run: $(OBJ)/fdc_run
	mkdir -p $(OUT)
	./$(OBJ)/fdc_run -o $(OUT)

lint:
	verilator --lint-only -Wall -Wno-MULTIDRIVEN --top-module fdc_card $(SRC)

.PHONY: run lint
