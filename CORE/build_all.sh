#!/usr/bin/env bash
# Build the PC10-III bitstream(s) in Vivado batch mode (simplified from Megamiga's
# build_all.sh: no re-roll, no placement margin, no reference builds yet).
#
# Usage: ./build_all.sh [board ...]        boards: R6 (default; only CORE-R6.xpr exists)
#
#   cd CORE && source <Vivado>/settings64.sh && ./build_all.sh R6
#
# Environment: JOBS=<n> parallel Vivado jobs per run (default 8).
#              REF_DIR=<CORE dir of an earlier build>: incremental synthesis and implementation
#              from its checkpoints (synth_1/mega65_<b>.dcp, impl_1/mega65_<b>_routed.dcp);
#              NO_REF_SYNTH=1 synthesizes anew but still places/routes incrementally.
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
    b=$(printf '%s' "$board" | tr '[:upper:]' '[:lower:]')
    unset REF_DCP REF_SYNTH_DCP
    if [ -n "${REF_DIR:-}" ]; then
        s="${REF_DIR}/CORE-${board}.runs/synth_1/mega65_${b}.dcp"
        r="${REF_DIR}/CORE-${board}.runs/impl_1/mega65_${b}_routed.dcp"
        [ -f "$r" ] || { echo "ERROR: no routed checkpoint $r" >&2; exit 1; }
        export REF_DCP=$(cd "$(dirname "$r")" && pwd)/$(basename "$r")
        if [ -f "$s" ] && [ "${NO_REF_SYNTH:-0}" != 1 ]; then
            export REF_SYNTH_DCP=$(cd "$(dirname "$s")" && pwd)/$(basename "$s")
        fi
        echo "=== ${board}: reference ${REF_DCP} (synthesis: ${REF_SYNTH_DCP:-none}) ==="
    fi
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
