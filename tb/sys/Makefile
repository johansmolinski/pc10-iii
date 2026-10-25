# System simulation: pc_system + RAM/ROM models.
#   make            build obj/sys_run
#   make RAM_KB=128 OBJ=obj128     a PC with 128 KB (a shorter BIOS RAM test)
#   ./obj/sys_run -b ~/pcxt-work/bios/GLABIOS_0.4.2_8X.ROM -s 2
#   make MDA=1      build obj_mda/sys_run with the MDA fitted (MDA=2: Hercules,
#                   obj_hgc); sys_run -m sets the mono DIP switches (doc/mda.md)
#   make FE=1 OBJ=obj_fe   the PC10-III's FE2010A port logic (xt_board); its switches
#                   differ from the 5160's: sys_run -d 5D (80x25 colour, 2 drives)

# The 8088's microcode bundle (tools/mkucode.py, not in the repository) is
# read at run time: $$PC10_UCODE, else Z86_UCODE compiled in.

RTL  = ../../rtl
Z86  = $(RTL)/cpu/z8086
KF   = $(RTL)/system/kf
Z86_UCODE ?= $(HOME)/pcxt-work/ucode/8088.bin
CPUSRC = $(Z86)/z86_eu.sv $(Z86)/z86_tables.sv $(Z86)/alu.sv $(Z86)/cpu_z86.sv $(RTL)/cpu/biu88.sv
CPUDEF = -I$(Z86) -CFLAGS -DZ86_UCODE='\"$(Z86_UCODE)\"' -CFLAGS -I$(abspath ../common)
CGA  ?= $(RTL)/video/cga/cga_crtc.sv $(RTL)/video/cga/cga_card.sv
MDA  ?= 0
VJ   ?= 0
MDASRC = $(RTL)/video/mda/mda_card.sv
SRC  = $(CPUSRC) $(RTL)/cpu/cpu8088.sv \
       $(wildcard $(KF)/KF8237/*.sv) $(wildcard $(KF)/KF8253/*.sv) \
       $(wildcard $(KF)/KF8255/*.sv) $(wildcard $(KF)/KF8259/*.sv) \
       $(RTL)/system/pc_clocks.sv $(RTL)/system/xt_board.sv $(RTL)/system/pc_system.sv \
       $(CGA) $(MDASRC) $(RTL)/fdc/upd765.sv $(RTL)/fdc/fdc_secbuf.sv $(RTL)/fdc/fdc_card.sv \
       $(RTL)/hdc/hdc_secbuf.sv $(RTL)/hdc/ata_dev.sv $(RTL)/hdc/xtide_card.sv tb_sys.sv
INC  = -I$(KF)/KF8237 -I$(KF)/KF8253 -I$(KF)/KF8255 -I$(KF)/KF8259
ifeq ($(MDA),1)
OBJ ?= obj_mda
else ifeq ($(MDA),2)
OBJ ?= obj_hgc
else
OBJ ?= obj
endif
RAM_KB ?= 640
# DRQ0_SKEW=7: MartyPC's refresh phase (trace comparison with MartyPC)
DRQ0_SKEW ?= 0
FE ?= 0

$(OBJ)/sys_run: $(SRC) sys_run.cpp
	verilator --cc --exe --build -O3 -j $(VJ) -Wno-fatal -Wno-lint -Wno-style \
	    --public-flat-rw --Mdir $(OBJ) --top-module tb_sys $(INC) \
	    -GRAM_KB=$(RAM_KB) -GDRQ0_SKEW=$(DRQ0_SKEW) -GMDA_FIT=$(MDA) -GFE2010A=$(FE) $(CPUDEF) \
	    $(SRC) sys_run.cpp -o sys_run -CFLAGS -O2
	@true
