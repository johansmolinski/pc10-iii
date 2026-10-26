#!/usr/bin/env bash
# run_rtcwb.sh: the firmware's real-time clock write-back (PC_RTC_WB in CORE/m2m-rom/pc_rtc.asm)
# on the QNICE emulator (headless batch mode, built here from M2M/QNICE), its device addresses
# moved into RAM (rtcwb_test.asm). Optional argument: another pc_rtc.asm (mutants).
set -e
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
FW=${1:-$R/CORE/m2m-rom/pc_rtc.asm}
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
# the device registers into RAM: pc_rtc.vhd at 0xC000, M2M's RTC at 0xC100
sed -e 's/^\(PC_M2M_RTC_REG *\.EQU *\)0x8000/\10xC100/' -e 's/^\(PC_M2M_RTC_CMD *\.EQU *\)0x8008/\10xC108/' \
    -e 's/^\(PC_RTC_ST *\.EQU *\)0x8000/\10xC000/' -e 's/^\(PC_RTC_TIME *\.EQU *\)0x8001/\10xC001/' \
    "$FW" > pc_rtc_moved.asm
[ "$(grep -c '0xC[01]0[018]' pc_rtc_moved.asm)" = 4 ] || { echo "RTCWB TEST: FAIL (constants not found)"; exit 1; }
cp "$H/rtcwb_test.asm" .
"$CC" -xc -E rtcwb_test.asm 2>/dev/null | sed '/^#.*/d' > __t.asm
./qasm __t.asm rtcwb_test.out rtcwb_test.lis > qasm.log 2>&1 || { cat qasm.log; exit 1; }
timeout 20 ./qnice -b 0x8000 monitor.out rtcwb_test.out < /dev/null 2>&1 | grep -a "RTCWB TEST" || echo "RTCWB TEST: FAIL (no result)"
