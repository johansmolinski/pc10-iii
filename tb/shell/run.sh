#!/usr/bin/env bash
# ghdl checks of the shell's VHDL glue (tb_glue.vhd: keyboard, BIOS, RAM, CGA font;
# tb_fdd.vhd: the floppy backend against an engine-port model) and a Verilator run of the
# stand-in pc_system (tb_stub.sv). Run from anywhere: tb/shell/run.sh
set -e
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cd "$W"
M=$R/M2M/vhdl
for f in $R/M2M/QNICE/vhdl/tools.vhd $M/tdp_ram.vhd $M/2port2clk_ram.vhd $M/cdc_stable.vhd \
         $M/QNICE/sdhost.vhd $R/CORE/vhdl/keyboard.vhd $R/CORE/vhdl/pc_bios.vhd $R/CORE/vhdl/pc_ram.vhd \
         $R/CORE/vhdl/pc_font.vhd $R/CORE/vhdl/pc_fdd_sd.vhd $H/tb_glue.vhd $H/tb_fdd.vhd; do
    ghdl -a --std=08 -frelaxed "$f"
done
ghdl -e --std=08 -frelaxed tb_glue
ghdl -r --std=08 -frelaxed tb_glue -gG_FONT_HEX="$R/CORE/font/cga_default.hex" --ieee-asserts=disable 2>&1 | grep -E "PASS|FAIL|error|failure" || true
ghdl -e --std=08 -frelaxed tb_fdd
ghdl -r --std=08 -frelaxed tb_fdd --ieee-asserts=disable 2>&1 | grep -E "PASS|FAIL|error|failure" || true
verilator --binary -j 0 -Wno-fatal -Wno-lint -Wno-style --top-module tb_stub \
    "$R/CORE/stub/pc_system.sv" "$H/tb_stub.sv" -o tb_stub > /dev/null
./obj_dir/tb_stub
