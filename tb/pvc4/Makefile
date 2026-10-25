# Paradise PVC4 testbench (doc/pvc4.md section 9).
#   make          build obj/pvc4_run
#   make run      font + all tests; images and logs in $(OUT)
#   make png      convert the PPM images in $(OUT) to PNG

RTL     = ../../rtl/video
SRC     = $(RTL)/cga/cga_crtc.sv $(RTL)/pvc4/pvc4.sv
OUT    ?= $(HOME)/pcxt-work/pvc4/tb
GLABIOS ?= $(HOME)/pcxt-work/ext/GLaBIOS/src/GLABIOS.ASM
FONT    = $(OUT)/testfont.bin
OBJ    ?= obj

$(OBJ)/pvc4_run: $(SRC) pvc4_run.cpp pvc4_model.h ../cga/cga_model.h
	verilator --cc --exe --build -O3 -j 0 -Wall -Wno-fatal -Wno-UNUSEDSIGNAL \
	    --public-flat-rw --Mdir $(OBJ) --top-module pvc4 \
	    $(SRC) pvc4_run.cpp -o pvc4_run -CFLAGS -O2
	@true

$(FONT): ../mda/mkfont.py
	mkdir -p $(OUT)
	python3 -I ../mda/mkfont.py $(GLABIOS) $@

run: $(OBJ)/pvc4_run $(FONT)
	./$(OBJ)/pvc4_run -f $(FONT) -o $(OUT) $(TESTS) | tee $(OUT)/pvc4_run.log
	@$(MAKE) --no-print-directory png

png:
	python3 -I topng.py $(OUT)/*.ppm

.PHONY: run png
