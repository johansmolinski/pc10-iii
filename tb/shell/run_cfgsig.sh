#!/usr/bin/env bash
# run_cfgsig.sh: the settings file signature of the firmware (CFG_SIGCHECK, CFG_SIGSET in
# CORE/m2m-rom/m2m-rom.asm) with M2M's cfgstr.asm on the QNICE emulator (headless batch
# mode, built here from M2M/QNICE). Optional argument: another m2m-rom.asm (mutants).
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
# the emulator (qnice.c includes ../dist_kit/sysdef.h)
mkdir -p "$W/emu" && cp "$Q"/emulator/*.[ch] "$W/emu/"
(cd "$W/emu" && "$CC" -O2 -w -o "$W/qnice" -DUSE_SD -DUSE_UART -DUSE_TIMER -UUSE_VGA -UUSE_IDE \
    -U__EMSCRIPTEN__ -UDEBUG qnice.c uart.c sd.c timer.c -lpthread -lm)
cd "$W"
"$CC" -xc -E monitor.asm 2>/dev/null | sed '/^#.*/d' > __m.asm
./qasm __m.asm monitor.out monitor.lis > /dev/null
cp "$R/M2M/rom/cfgstr.asm" .
awk '/^; CFG_SIGCHECK/ {p = 1} p {print} /^CFG_SIG_VAL/ {exit}' "$FW" > cfgsig_fn.asm
SIG=$(sed -n 's/^CFG_SIG_VAL *\.ASCII_W *"\(.*\)".*/\1/p' cfgsig_fn.asm)
[ -n "$SIG" ] || { echo "CFGSIG TEST: FAIL (no CFG_SIG_VAL)"; exit 1; }
cp "$H/cfgsig_test.asm" .
"$CC" -xc -E -DCFG_SIG_TEXT="\"$SIG\"" cfgsig_test.asm 2>/dev/null | sed '/^#.*/d' > __t.asm
./qasm __t.asm cfgsig_test.out cfgsig_test.lis > qasm.log 2>&1 || { cat qasm.log; exit 1; }
timeout 20 ./qnice -b 0x8000 monitor.out cfgsig_test.out < /dev/null 2>&1 | grep -a "CFGSIG TEST" || echo "CFGSIG TEST: FAIL (no result)"
