#!/usr/bin/env bash
# run_rows.sh: M2M/rom/menu_rows.asm (OPTR_PRINT, OPTR_POS: the row without a label, " B:%s" +
# " int. drive", shown and hidden by OPTM_CORE_HIDE; a row with a label) on the QNICE emulator
# (headless batch mode, built here from M2M/QNICE). Optional argument: another menu_rows.asm
# (mutants).
set -e
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
MR=${1:-$R/M2M/rom/menu_rows.asm}
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
cp "$MR" menu_rows.asm
# menu.asm's record offsets and the "\n" it searches for
grep -E '^(OPTM_IR_[A-Z]+ +\.EQU|OPTM_NL +\.DW)' "$R/M2M/rom/menu.asm" > rows_menu.asm
cp "$H/rows_test.asm" .
"$CC" -xc -E rows_test.asm 2>/dev/null | sed '/^#.*/d' > __t.asm
./qasm __t.asm rows_test.out rows_test.lis > qasm.log 2>&1 || { cat qasm.log; exit 1; }
timeout 20 ./qnice -b 0x8000 monitor.out rows_test.out < /dev/null 2>&1 | grep -a -A12 "ROWS TEST" || echo "ROWS TEST: FAIL (no result)"
