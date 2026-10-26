#!/usr/bin/env bash
# run_hdc.sh: the hard disk C: across power-off (CORE/m2m-rom/pc_hdc.asm with the firmware's
# PREP_LOAD_IMAGE and HANDLE_CORE_IO, M2M's cfgstr.asm) on the QNICE emulator's headless batch
# mode with an SD card image: a FAT32 file system (mkfs.vfat + mtools) with two hard disk
# images of 21,411,840 bytes, wrong sizes, a long folder name and folders that make a path of
# exactly 127 and 128 characters. The real monitor's FAT32 library does the file system work;
# FD_SETUP, the SD card slots (SDC$SLOT, SDC$MOUNT), the CRT/ROM CSR and the screen are stubs
# (hdc_test.asm). Optional arguments: another m2m-rom.asm, another pc_hdc.asm (mutants).
set -e
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
FW=${1:-$R/CORE/m2m-rom/m2m-rom.asm}
HDC=${2:-$R/CORE/m2m-rom/pc_hdc.asm}
Q=$R/M2M/QNICE
W=$(mktemp -d)
[ -n "${KEEP:-}" ] && echo "work: $W" || trap 'rm -rf "$W"' EXIT
CC=$(command -v cc || command -v gcc)
MKFS=$(command -v mkfs.vfat || echo /usr/sbin/mkfs.vfat)
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

# the SD card: an MBR with one FAT32 partition at block 2048 (as the QNICE FAT32 tests)
D111=$(printf 'Folder%0105d' 0)                 # SD1:/pc10/<111>/x.img = 127 characters
D112=$(printf 'Folder%0106d' 0)                 # 128 characters
python3 - sd.img <<'EOF'
import struct, sys
size = 64 * 1024 * 1024
with open(sys.argv[1], 'wb') as f:
    f.truncate(size)
    mbr = bytearray(512)
    mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\0\0\0', 0x0C, b'\0\0\0', 2048, size // 512 - 2048)
    mbr[510:512] = b'\x55\xaa'
    f.write(mbr)
EOF
"$MKFS" -F 32 -s 1 --offset 2048 sd.img > /dev/null
export MTOOLS_SKIP_CHECK=1
I="sd.img@@$((2048 * 512))"
truncate -s 21411840 hd.bin; truncate -s 1000 small.bin; truncate -s 368640 a360.bin
truncate -s 100 x.bin; truncate -s 10 root.bin
mmd -i "$I" ::pc10 "::pc10/Long Folder Name" "::pc10/$D111" "::pc10/$D112"
mcopy -i "$I" root.bin ::root.txt
mcopy -i "$I" hd.bin ::pc10/hd20.img
mcopy -i "$I" small.bin ::pc10/small.img
mcopy -i "$I" a360.bin ::pc10/a360.img
mcopy -i "$I" hd.bin "::pc10/Long Folder Name/My Hard Disk.img"
mcopy -i "$I" x.bin "::pc10/$D111/x.img"
mcopy -i "$I" x.bin "::pc10/$D112/x.img"
fallocate --dig-holes sd.img 2>/dev/null || true
rm -f hd.bin

# the code under test and the core's constants (as make_rom.sh makes them)
awk '/^; PREP_LOAD_IMAGE/ {p = 1} /^; FD_SETUP/ {exit} p {print}' "$FW" > hdc_pl.asm
awk '/^; HANDLE_CORE_IO \(M2M-UPSTREAM/ {p = 1} /^#include "pc_rtc.asm"/ {exit} p {print}' "$FW" > hdc_io.asm
grep -q '^PREP_LOAD_IMAGE' hdc_pl.asm && grep -q '^HANDLE_CORE_IO' hdc_io.asm || {
    echo "HDC TEST: FAIL (no PREP_LOAD_IMAGE / HANDLE_CORE_IO)"; exit 1; }
cp "$HDC" pc_hdc.asm
cp "$R/M2M/rom/cfgstr.asm" .
{
    awk '/constant C_MENU_/ {gsub("C_MENU_", "PC_OSM_"); gsub(";", ""); printf("%-31s .EQU %s\n", $2, $6)}' "$R/CORE/vhdl/mega65.vhd"
    awk '/constant OPTM_G_/ && !/16#/ {gsub("OPTM_G_", "PC_OPTM_G_"); gsub(";", ""); printf("%-31s .EQU %s\n", $2, $6)}' "$R/CORE/vhdl/config.vhd"
    awk '/constant C_DEV_PC_/ {name=$2; sub(/^C_DEV_PC_/, "", name); gsub(/.*x"/, ""); gsub(/".*/, ""); printf("%-31s .EQU 0x%s\n", "PC_DEV_" name, $0)}' "$R/CORE/vhdl/globals.vhd"
} > hdc_const.asm
{
    echo "T_D111          .ASCII_W \"/pc10/$D111\""
    echo "T_D112          .ASCII_W \"/pc10/$D112\""
    echo "T_X111          .ASCII_P \"menu=6\""
    echo "                .DW      0x000A"
    echo "                .ASCII_P \"hdc=SD1:/pc10/$D111/x.img\""
    echo "                .DW      0x000A, 0"
} > hdc_names.asm
cp "$H/hdc_test.asm" .
"$CC" -xc -E hdc_test.asm 2>/dev/null | sed '/^#.*/d' > __t.asm
./qasm __t.asm hdc_test.out hdc_test.lis > qasm.log 2>&1 || { cat qasm.log; exit 1; }
timeout 60 ./qnice -a sd.img -b 0x9000 monitor.out hdc_test.out < /dev/null 2>&1 | grep -a "HDC TEST" || echo "HDC TEST: FAIL (no result)"
