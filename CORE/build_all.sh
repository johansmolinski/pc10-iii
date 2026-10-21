#!/usr/bin/env bash
# Build the PC10-III bitstream(s) in Vivado batch mode (simplified from Megamiga's
# build_all.sh: no re-roll, no placement margin, no reference builds yet).
#
# Usage: ./build_all.sh [board ...]        boards: R6 (default; only CORE-R6.xpr exists)
#
#   cd CORE && source <Vivado>/settings64.sh && ./build_all.sh R6
#
# Environment: JOBS=<n> parallel Vivado jobs per run (default 8).
# Prints "RESULT <board> OK|FAILED|TIMING-FAILED|SIGNOFF-FAILED ..." per board and a summary.
set -u
cd "$(dirname "$0")"

boards=("$@")
[ "${#boards[@]}" -gt 0 ] || boards=(R6)
command -v vivado >/dev/null 2>&1 || { echo "ERROR: vivado is not on the PATH." >&2; exit 1; }

# assemble the firmware once up front: a firmware error stops here, not in synthesis
( cd m2m-rom && ./make_rom.sh ) || exit 1

jobs="${JOBS:-8}"
rc=0
for board in "${boards[@]}"; do
    board=$(printf '%s' "$board" | tr '[:lower:]' '[:upper:]')
    [ -f "CORE-${board}.xpr" ] || { echo "ERROR: no CORE-${board}.xpr" >&2; exit 1; }
    echo "=== ${board}: build started $(date) ==="
    vivado -mode batch -notrace -source build_bitstream.tcl \
           -log "build_${board}.log" -journal "build_${board}.jou" \
           -tclargs "${board}" "${jobs}" || rc=1
    echo "=== ${board}: build finished $(date) ==="
done

echo "=== Summary ==="
for board in "${boards[@]}"; do
    board=$(printf '%s' "$board" | tr '[:lower:]' '[:upper:]')
    grep -h "^RESULT ${board} " "build_${board}.log" 2>/dev/null | tail -n 1 || echo "RESULT ${board} NONE"
done
exit $rc
