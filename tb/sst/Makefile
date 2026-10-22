# SingleStepTests harness for MCL86.
#   make            build obj_$(BIU)/sst_run
#   make convert    convert the suite (SST=path to SingleStepTests/8088)
#   make run        run all converted tests (TXT=dir), one job per file

SST  ?= $(HOME)/pcxt-work/ext/sst8088
TXT  ?= $(HOME)/pcxt-work/sst-txt
JOBS ?= $(shell nproc)

RTL  = ../../rtl/cpu/mcl86
# BIU=biu88 (default): the cycle-stepped BIU; BIU=max: MCL86's original BIU
BIU ?= biu88
# CPU=z86 (default): z8086's EU + biu88 (doc/z8086.md); CPU=mcl86: MCL86. The microcode bundle
# (tools/mkucode.py, not in the repository) is read at run time: $$PC10_UCODE,
# else Z86_UCODE compiled in.
CPU ?= z86
Z86_UCODE ?= $(HOME)/pcxt-work/ucode/8088.bin
Z86  = ../../rtl/cpu/z8086
ifeq ($(CPU),z86)
SRC  = tb_z86.v $(Z86)/z86_eu.sv $(Z86)/z86_tables.sv $(Z86)/alu.sv \
       $(Z86)/cpu_z86.sv $(RTL)/biu88.v
CDEF = -CFLAGS -DBIU88 -CFLAGS -DZ86 -CFLAGS -DZ86_UCODE='\"$(Z86_UCODE)\"' -CFLAGS -I$(abspath ../common) \
       -I$(Z86)
OBJ  ?= obj_z86
ROMHEX = $(Z86)/z86_overlay.svh
else ifeq ($(BIU),max)
SRC  = tb_mcl86.v $(RTL)/eu.v $(RTL)/biu_max.v $(RTL)/eu_rom.v
CDEF =
else
SRC  = tb_mcl86_biu88.v $(RTL)/eu.v $(RTL)/biu88.v $(RTL)/eu_rom.v
CDEF = -CFLAGS -DBIU88
endif
OBJ  ?= obj_$(BIU)
ROMHEX ?= $(abspath $(RTL))/microcode.hex

$(OBJ)/sst_run: $(SRC) sst_run.cpp $(ROMHEX)
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style \
	    --Mdir $(OBJ) --top-module tb_mcl86 \
	    +define+MCL86_ROM='"$(ROMHEX)"' \
	    $(SRC) sst_run.cpp -o sst_run -CFLAGS -O2 $(CDEF)
	@true

$(RTL)/microcode.hex: $(RTL)/microcode.txt ../../tools/mcasm.py
	python3 ../../tools/mcasm.py $< $@

convert:
	python3 -I sst2txt.py $(SST)/v2/metadata.json $(TXT) $(SST)/v2/*.json.gz

run: $(OBJ)/sst_run
	ls $(TXT)/*.txt | xargs -P $(JOBS) -n 1 $(OBJ)/sst_run | grep -v '^file' | sort

.PHONY: convert run
