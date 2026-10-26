#!/usr/bin/env bash
# Firmware-only changes without synthesis (from Megamiga's CORE/patch_firmware.sh):
# patch the QNICE firmware of an existing build into its bitstream.
#
# Usage:
#   ./patch_firmware.sh save <dir> [board]    after a build: keep what a patch needs
#   ./patch_firmware.sh patch <dir> [out.bit] assemble the current firmware and write a
#                                             bitstream of that build with it
#
#   save   copies the routed checkpoint, the bitstream and the firmware image the build
#          was made with (m2m-rom.rom) from CORE-<board>.runs into <dir> (board R6).
#   patch  runs m2m-rom/make_rom.sh, then Vivado opens the saved checkpoint, checks that
#          its QNICE ROM block RAMs hold exactly the saved image, puts the new one in and
#          writes the bitstream (default <dir>/patched.bit). Nothing else changes, so the
#          timing of the saved build holds.
#
# What can be patched: m2m-rom.asm, and the C_MENU_*/OPTM_G_*/C_DEV_PC_* constants
# make_rom.sh scrapes, as long as the HDL does not change with them. Everything else in
# the HDL (config.vhd: the menu text, help, version) needs a build. The PC10-III has no
# read-only data device and no code banks.
#
# Vivado must be on the PATH (source ~/xilinx-env.sh on fedora).

set -eu
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/ s/^# \{0,1\}//p' "$(basename "$0")"; exit 1; }
tohex() { python3 -c "
import sys
for l in open(sys.argv[1]):
    l = l.strip()
    if l: print('%04X' % int(l, 2))" "$1" > "$2"; }

[ $# -ge 2 ] || usage
cmd=$1; dir=$2

case "${cmd}" in
save)
    board=$(echo "${3:-R6}" | tr a-z A-Z); b=$(echo "${board}" | tr A-Z a-z)
    impl=CORE-${board}.runs/impl_1
    dcp=${impl}/mega65_${b}_postroute_physopt.dcp
    [ -f "${dcp}" ] || dcp=${impl}/mega65_${b}_routed.dcp
    [ -f "${dcp}" ] || die "no routed checkpoint in ${impl}"
    [ -f "${impl}/mega65_${b}.bit" ] || die "no bitstream in ${impl}"
    [ "${impl}/mega65_${b}.bit" -nt m2m-rom/m2m-rom.rom ] || \
        die "m2m-rom.rom is newer than the bitstream: the firmware changed after the build"
    mkdir -p "${dir}"
    cp "${dcp}" "${dir}/routed.dcp"
    cp "${impl}/mega65_${b}.bit" m2m-rom/m2m-rom.rom "${dir}/"
    echo "saved ${board} build to ${dir}"
    ;;
patch)
    out=${3:-${dir}/patched.bit}
    for f in routed.dcp m2m-rom.rom; do
        [ -f "${dir}/${f}" ] || die "${dir}/${f} missing - was the build saved with 'save'?"
    done
    command -v vivado >/dev/null 2>&1 || die "vivado is not on the PATH"
    tmp=$(mktemp -d)
    ( cd m2m-rom && ./make_rom.sh > "${tmp}/make_rom.log" 2>&1 ) || \
        { tail -20 "${tmp}/make_rom.log"; die "firmware does not assemble"; }
    grep "Shell ROM" "${tmp}/make_rom.log" || true
    tohex "${dir}/m2m-rom.rom" "${tmp}/rom_ref.hex"
    tohex m2m-rom/m2m-rom.rom "${tmp}/rom_new.hex"
    vivado -mode batch -nojournal -log "${tmp}/vivado.log" -source patch_firmware.tcl \
        -tclargs "${dir}/routed.dcp" "$(realpath -m "${out}")" "${tmp}/rom_ref.hex" \
        "${tmp}/rom_new.hex" - - - - > /dev/null 2>&1 || true
    grep "^PATCH:\|^ERROR" "${tmp}/vivado.log" || true
    grep -q "^PATCH: OK" "${tmp}/vivado.log" || die "patch failed, see ${tmp}/vivado.log"
    rm -rf "${tmp}"
    ;;
*)  usage ;;
esac
