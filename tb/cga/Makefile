# CGA card testbench (doc/cga.md section 9).
#   make          build obj/cga_run
#   make run      font + all tests; images and logs in $(OUT)
#   make png      convert the PPM images in $(OUT) to PNG

RTL     = ../../rtl/video/cga
SRC     = $(RTL)/cga_crtc.sv $(RTL)/cga_card.sv
OUT    ?= $(HOME)/pcxt-work/cga
GLABIOS ?= $(HOME)/pcxt-work/ext/GLaBIOS/src/GLABIOS.ASM
FONT    = $(OUT)/testfont.bin
OBJ    ?= obj

$(OBJ)/cga_run: $(SRC) cga_run.cpp cga_model.h
	verilator --cc --exe --build -O3 -j 0 -Wall -Wno-fatal -Wno-UNUSEDSIGNAL \
	    --public-flat-rw --Mdir $(OBJ) --top-module cga_card \
	    $(SRC) cga_run.cpp -o cga_run -CFLAGS -O2
	@true

$(FONT): mkfont.py
	mkdir -p $(OUT)
	python3 -I mkfont.py $(GLABIOS) $@

run: $(OBJ)/cga_run $(FONT)
	./$(OBJ)/cga_run -f $(FONT) -o $(OUT) $(TESTS) | tee $(OUT)/cga_run.log
	@$(MAKE) --no-print-directory png

png:
	python3 -I topng.py $(OUT)/*.ppm

.PHONY: run png
