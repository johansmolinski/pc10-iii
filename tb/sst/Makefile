# SingleStepTests harness for MCL86.
#   make            build obj_dir/sst_run
#   make convert    convert the suite (SST=path to SingleStepTests/8088)
#   make run        run all converted tests (TXT=dir), one job per file

SST  ?= $(HOME)/pcxt-work/ext/sst8088
TXT  ?= $(HOME)/pcxt-work/sst-txt
JOBS ?= $(shell nproc)

RTL  = ../../rtl/cpu/mcl86
SRC  = tb_mcl86.v $(RTL)/eu.v $(RTL)/biu_max.v $(RTL)/eu4kx32.v

obj_dir/sst_run: $(SRC) sst_run.cpp $(RTL)/microcode.hex
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style \
	    --top-module tb_mcl86 +define+MCL86_ROM='"$(abspath $(RTL))/microcode.hex"' \
	    $(SRC) sst_run.cpp -o sst_run -CFLAGS -O2
	@true

$(RTL)/microcode.hex: $(RTL)/microcode.txt ../../tools/mcasm.py
	python3 ../../tools/mcasm.py $< $@

convert:
	python3 -I sst2txt.py $(SST)/v2/metadata.json $(TXT) $(SST)/v2/*.json.gz

run: obj_dir/sst_run
	ls $(TXT)/*.txt | xargs -P $(JOBS) -n 1 obj_dir/sst_run | grep -v '^file' | sort

.PHONY: convert run
