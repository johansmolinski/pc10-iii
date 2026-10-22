# MDA / Hercules card testbench (doc/mda.md section 8).
#   make          build obj/mda_run (MDA) and obj_hgc/mda_run (Hercules)
#   make run      font + all tests; images and logs in $(OUT)
#   make png      convert the PPM images in $(OUT) to PNG

RTL     = ../../rtl/video
SRC     = $(RTL)/cga/cga_crtc.sv $(RTL)/mda/mda_card.sv
OUT    ?= $(HOME)/pcxt-work/mda
GLABIOS ?= $(HOME)/pcxt-work/ext/GLaBIOS/src/GLABIOS.ASM
FONT    = $(OUT)/testfont.bin
VFLAGS  = --cc --exe --build -O3 -j 4 -Wall -Wno-fatal -Wno-UNUSEDSIGNAL --public-flat-rw --top-module mda_card

all: obj/mda_run obj_hgc/mda_run

obj/mda_run: $(SRC) mda_run.cpp mda_model.h ../cga/cga_model.h
	verilator $(VFLAGS) --Mdir obj $(SRC) mda_run.cpp -o mda_run -CFLAGS -O2
	@true

obj_hgc/mda_run: $(SRC) mda_run.cpp mda_model.h ../cga/cga_model.h
	verilator $(VFLAGS) -GHERC=1\'b1 --Mdir obj_hgc $(SRC) mda_run.cpp -o mda_run -CFLAGS "-O2 -DHERC_BUILD=1"
	@true

$(FONT): mkfont.py
	mkdir -p $(OUT)
	python3 -I mkfont.py $(GLABIOS) $@

run: obj/mda_run obj_hgc/mda_run $(FONT)
	./obj/mda_run -f $(FONT) -o $(OUT) $(TESTS) | tee $(OUT)/mda_run.log
	./obj_hgc/mda_run -f $(FONT) -o $(OUT) $(HTESTS) | tee $(OUT)/hgc_run.log
	@$(MAKE) --no-print-directory png

png:
	python3 -I topng.py $(OUT)/*.ppm

.PHONY: all run png
