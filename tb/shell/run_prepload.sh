#!/usr/bin/env bash
# run_prepload.sh: the image checks of the firmware's PREP_LOAD_IMAGE (A:, B:, C:; CORE/m2m-rom/
# m2m-rom.asm) on the QNICE emulator (headless batch mode, built here from M2M/QNICE), with a
# stub FD_SETUP (prepload_test.asm). Optional argument: another m2m-rom.asm (mutants).
set -e
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
FW=${1:-$R/CORE/m2m-rom/m2m-rom.asm}
Q=$R/M2M/QNICE
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
CC=$(command -v cc || command -v gcc)
"$CC" -O2 -w -o "$W/qasm" "$Q/assembler/qasm.c"
cp "$Q"/monitor/*.asm "$W/"
mkdir -p "$W/dist_kit"
(cd "$W" && perl "$Q/monitor/sysdef2header.pl" sysdef.asm dist_kit/sysdef.h)
mkdir -p "$W/emu" && cp "$Q"/emulator/*.[ch] "$W/emu/"
(cd "$W/emu" && "$CC" -O2 -w -o "$W/qnice" -DUSE_SD -DUSE_UART -DUSE_TIMER -UUSE_VGA -UUSE_IDE \
    -U__EMSCRIPTEN__ -UDEBUG qnice.c uart.c sd.c timer.c -lpthread -lm)
cd "$W"
"$CC" -xc -E monitor.asm 2>/dev/null | sed '/^#.*/d' > __m.asm
./qasm __m.asm monitor.out monitor.lis > /dev/null
# the function under test: from PREP_LOAD_IMAGE's comment to FD_SETUP's (FD_SEL, the tables)
awk '/^; PREP_LOAD_IMAGE/ {p = 1} /^; FD_SETUP/ {exit} p {print}' "$FW" > prepload_fn.asm
grep -q '^PREP_LOAD_IMAGE' prepload_fn.asm || { echo "PREPLOAD TEST: FAIL (no PREP_LOAD_IMAGE)"; exit 1; }
# the core's constants, as make_rom.sh makes them (config.vhd OPTM_G_*, globals.vhd C_DEV_PC_*)
{
    awk '/constant OPTM_G_/ && !/16#/ {gsub("OPTM_G_", "PC_OPTM_G_"); gsub(";", ""); printf("%-31s .EQU %s\n", $2, $6)}' "$R/CORE/vhdl/config.vhd"
    awk '/constant C_DEV_PC_/ {name=$2; sub(/^C_DEV_PC_/, "", name); gsub(/.*x"/, ""); gsub(/".*/, ""); printf("%-31s .EQU 0x%s\n", "PC_DEV_" name, $0)}' "$R/CORE/vhdl/globals.vhd"
} > prepload_const.asm
cp "$H/prepload_test.asm" .
"$CC" -xc -E prepload_test.asm 2>/dev/null | sed '/^#.*/d' > __t.asm
./qasm __t.asm prepload_test.out prepload_test.lis > qasm.log 2>&1 || { cat qasm.log; exit 1; }
timeout 20 ./qnice -b 0x9000 monitor.out prepload_test.out < /dev/null 2>&1 | grep -a "PREPLOAD TEST" || echo "PREPLOAD TEST: FAIL (no result)"
