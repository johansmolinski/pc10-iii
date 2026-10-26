#!/usr/bin/env bash
# ghdl checks of the shell's VHDL glue (tb_glue.vhd: keyboard, BIOS, RAM, CGA font, microcode;
# tb_fdd.vhd: the floppy backend against an engine-port model; tb_drvsnd.vhd: the drive LED and
# the drive sound against a model of the internal drive; tb_chipset.vhd: the menu's chipset,
# its switches and the restart; tb_rtc.vhd: the real-time clock's write-back, pc_rtc.vhd with M2M's
# RTC device and the firmware's access sequence), the firmware's settings file
# signature and the RTC write-back (PC_RTC_WB) on the QNICE emulator (run_cfgsig.sh, run_rtcwb.sh) and a Verilator run of the stand-in
# pc_system (tb_stub.sv). Run from anywhere: tb/shell/run.sh. Mutants: tb/shell/mut.py, tb/shell/mut_rtc.py
set -e
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cd "$W"
M=$R/M2M/vhdl
for f in $R/M2M/QNICE/vhdl/tools.vhd $M/tdp_ram.vhd $M/2port2clk_ram.vhd $M/cdc_stable.vhd \
         $M/QNICE/sdhost.vhd $R/CORE/vhdl/keyboard.vhd $R/CORE/vhdl/pc_bios.vhd $R/CORE/vhdl/pc_ram.vhd \
         $R/CORE/vhdl/pc_font.vhd $R/CORE/vhdl/pc_ucode.vhd $R/CORE/vhdl/pc_fdd_sd.vhd $R/CORE/vhdl/pc_drvsnd.vhd \
         $R/CORE/vhdl/pc_chipset.vhd $M/i2c/rtc_master.vhd $M/i2c/rtc_controller.vhd $R/CORE/vhdl/pc_rtc.vhd \
         $H/tb_glue.vhd $H/tb_fdd.vhd $H/tb_drvsnd.vhd $H/tb_chipset.vhd $H/tb_rtc.vhd; do
    ghdl -a --std=08 -frelaxed "$f"
done
ghdl -e --std=08 -frelaxed tb_glue
ghdl -r --std=08 -frelaxed tb_glue -gG_FONT_HEX="$R/CORE/font/cga_default.hex" --ieee-asserts=disable 2>&1 | grep -E "PASS|FAIL|error|failure" || true
ghdl -e --std=08 -frelaxed tb_fdd
ghdl -r --std=08 -frelaxed tb_fdd --ieee-asserts=disable 2>&1 | grep -E "PASS|FAIL|error|failure" || true
ghdl -e --std=08 -frelaxed tb_drvsnd
ghdl -r --std=08 -frelaxed tb_drvsnd --ieee-asserts=disable 2>&1 | grep -E "PASS|FAIL|error|failure" || true
ghdl -e --std=08 -frelaxed tb_chipset
ghdl -r --std=08 -frelaxed tb_chipset --ieee-asserts=disable 2>&1 | grep -E "PASS|FAIL|error|failure" || true
ghdl -e --std=08 -frelaxed tb_rtc
ghdl -r --std=08 -frelaxed tb_rtc --ieee-asserts=disable 2>&1 | grep -E "PASS|FAIL|error|failure" || true
"$H/run_cfgsig.sh"
"$H/run_rtcwb.sh"
verilator --binary -j 0 -Wno-fatal -Wno-lint -Wno-style --top-module tb_stub \
    "$R/CORE/stub/pc_system.sv" "$H/tb_stub.sv" -o tb_stub > /dev/null
./obj_dir/tb_stub
