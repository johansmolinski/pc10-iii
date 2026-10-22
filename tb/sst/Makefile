# SingleStepTests harness for the 8088 (z8086's EU + biu88, doc/z8086.md).
#   make            build obj_z86/sst_run
#   make convert    convert the suite (SST=path to SingleStepTests/8088)
#   make run        run all converted tests (TXT=dir), one job per file
# The microcode bundle (tools/mkucode.py, not in the repository) is read at run
# time: $$PC10_UCODE, else Z86_UCODE compiled in.

SST  ?= $(HOME)/pcxt-work/ext/sst8088
TXT  ?= $(HOME)/pcxt-work/sst-txt
JOBS ?= $(shell nproc)

Z86_UCODE ?= $(HOME)/pcxt-work/ucode/8088.bin
Z86  = ../../rtl/cpu/z8086
SRC  = tb_z86.v $(Z86)/z86_eu.sv $(Z86)/z86_tables.sv $(Z86)/alu.sv \
       $(Z86)/cpu_z86.sv ../../rtl/cpu/biu88.sv
OBJ ?= obj_z86

$(OBJ)/sst_run: $(SRC) $(Z86)/z86_overlay.svh sst_run.cpp ../common/ucode_file.h
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style \
	    --Mdir $(OBJ) --top-module tb_z86 -I$(Z86) \
	    $(SRC) sst_run.cpp -o sst_run -CFLAGS -O2 \
	    -CFLAGS -DZ86_UCODE='\"$(Z86_UCODE)\"' -CFLAGS -I$(abspath ../common)
	@true

convert:
	python3 -I sst2txt.py $(SST)/v2/metadata.json $(TXT) $(SST)/v2/*.json.gz

run: $(OBJ)/sst_run
	ls $(TXT)/*.txt | xargs -P $(JOBS) -n 1 $(OBJ)/sst_run | grep -v '^file' | sort

.PHONY: convert run
