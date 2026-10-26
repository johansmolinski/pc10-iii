# Drive B: as the real drive: fdc_card + fdd_intdrv + C++ models of the bus,
# the DMA, the image backend and a 3.5" DD drive (flux in and out).
#   make        build obj/intfd_run
#   make run    build and run
#   make lint   Verilator lint of the new RTL

RTL = ../../rtl/fdc
SRC = $(RTL)/upd765.sv $(RTL)/fdc_secbuf.sv $(RTL)/fdc_card.sv \
      $(RTL)/fdd_mfm_rd.sv $(RTL)/fdd_mfm_wr.sv $(RTL)/fdd_phys.sv $(RTL)/fdd_intdrv.sv tb_intfd.sv
OBJ ?= obj

$(OBJ)/intfd_run: $(SRC) intfd_run.cpp
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-MULTIDRIVEN \
	    --Mdir $(OBJ) --top-module tb_intfd \
	    $(SRC) intfd_run.cpp -o intfd_run -CFLAGS -O2
	@true

run: $(OBJ)/intfd_run
	./$(OBJ)/intfd_run

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME --top-module fdd_intdrv \
	    $(RTL)/fdd_mfm_rd.sv $(RTL)/fdd_mfm_wr.sv $(RTL)/fdd_phys.sv $(RTL)/fdd_intdrv.sv

.PHONY: run lint
