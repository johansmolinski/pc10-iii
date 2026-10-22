# System simulation: pc_system + RAM/ROM models.
#   make            build obj/sys_run
#   ./obj/sys_run -b ~/pcxt-work/bios/GLABIOS_0.4.2_8X.ROM -s 2
#   make MDA=1      build obj_mda/sys_run with the MDA fitted (MDA=2: Hercules,
#                   obj_hgc); sys_run -m sets the mono DIP switches (doc/mda.md)

RTL  = ../../rtl
CPU  = $(RTL)/cpu/mcl86
KF   = $(RTL)/system/kf
ROMHEX ?= $(abspath $(CPU))/microcode.hex
CGA  ?= $(RTL)/video/cga/cga_crtc.sv $(RTL)/video/cga/cga_card.sv
MDA  ?= 0
VJ   ?= 0
MDASRC = $(RTL)/video/mda/mda_card.sv
SRC  = $(CPU)/eu.v $(CPU)/biu88.v $(CPU)/eu_rom.v $(RTL)/cpu/cpu8088.sv \
       $(wildcard $(KF)/KF8237/*.sv) $(wildcard $(KF)/KF8253/*.sv) \
       $(wildcard $(KF)/KF8255/*.sv) $(wildcard $(KF)/KF8259/*.sv) \
       $(RTL)/system/pc_clocks.sv $(RTL)/system/xt_board.sv $(RTL)/system/pc_system.sv \
       $(CGA) $(MDASRC) $(RTL)/fdc/upd765.sv $(RTL)/fdc/fdc_secbuf.sv $(RTL)/fdc/fdc_card.sv tb_sys.sv
INC  = -I$(KF)/KF8237 -I$(KF)/KF8253 -I$(KF)/KF8255 -I$(KF)/KF8259
ifeq ($(MDA),1)
OBJ ?= obj_mda
else ifeq ($(MDA),2)
OBJ ?= obj_hgc
else
OBJ ?= obj
endif

$(OBJ)/sys_run: $(SRC) sys_run.cpp
	verilator --cc --exe --build -O3 -j $(VJ) -Wno-fatal -Wno-lint -Wno-style \
	    --public-flat-rw --Mdir $(OBJ) --top-module tb_sys $(INC) \
	    +define+MCL86_ROM='"$(ROMHEX)"' -GMDA_FIT=$(MDA) \
	    $(SRC) sys_run.cpp -o sys_run -CFLAGS -O2
	@true
