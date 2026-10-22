# System simulation: pc_system + RAM/ROM models.
#   make            build obj/sys_run
#   make RAM_KB=128 OBJ=obj128     a PC with 128 KB (a shorter BIOS RAM test)
#   ./obj/sys_run -b ~/pcxt-work/bios/GLABIOS_0.4.2_8X.ROM -s 2

RTL  = ../../rtl
CPU  = $(RTL)/cpu/mcl86
KF   = $(RTL)/system/kf
ROMHEX ?= $(abspath $(CPU))/microcode.hex
CGA  ?= $(RTL)/video/cga/cga_crtc.sv $(RTL)/video/cga/cga_card.sv
SRC  = $(CPU)/eu.v $(CPU)/biu88.v $(CPU)/eu_rom.v $(RTL)/cpu/cpu8088.sv \
       $(wildcard $(KF)/KF8237/*.sv) $(wildcard $(KF)/KF8253/*.sv) \
       $(wildcard $(KF)/KF8255/*.sv) $(wildcard $(KF)/KF8259/*.sv) \
       $(RTL)/system/pc_clocks.sv $(RTL)/system/xt_board.sv $(RTL)/system/pc_system.sv \
       $(CGA) $(RTL)/fdc/upd765.sv $(RTL)/fdc/fdc_secbuf.sv $(RTL)/fdc/fdc_card.sv \
       $(RTL)/hdc/hdc_secbuf.sv $(RTL)/hdc/ata_dev.sv $(RTL)/hdc/xtide_card.sv tb_sys.sv
INC  = -I$(KF)/KF8237 -I$(KF)/KF8253 -I$(KF)/KF8255 -I$(KF)/KF8259
OBJ ?= obj
RAM_KB ?= 640
JOBS ?= 0

$(OBJ)/sys_run: $(SRC) sys_run.cpp
	verilator --cc --exe --build -O3 -j $(JOBS) -Wno-fatal -Wno-lint -Wno-style \
	    --public-flat-rw --Mdir $(OBJ) --top-module tb_sys $(INC) \
	    +define+MCL86_ROM='"$(ROMHEX)"' -GRAM_KB=$(RAM_KB) \
	    $(SRC) sys_run.cpp -o sys_run -CFLAGS -O2
	@true
