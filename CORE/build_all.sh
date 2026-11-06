#!/usr/bin/env bash
# Build the PC10-III bitstream(s) in Vivado batch mode (simplified from Megamiga's
# build_all.sh: no placement margin; its re-roll since 2026-11-06).
#
# Usage: ./build_all.sh [--no-reroll] [board ...]   boards: R6 (default), R3 (CORE-R3.xpr
#                                                   from tools/xpr_board.py)
#
#   cd CORE && source <Vivado>/settings64.sh && ./build_all.sh R6
#
# Environment: JOBS=<n> parallel Vivado jobs per run (default 8).
#              REF_DIR=<CORE dir of an earlier build>: incremental synthesis and implementation
#              from its checkpoints (synth_1/mega65_<b>.dcp, impl_1/mega65_<b>_routed.dcp);
#              NO_REF_SYNTH=1 synthesizes anew but still places/routes incrementally.
#              REROLL_MAX_MISS=<ns> largest setup or hold miss that gets re-rolled (default
#              0.3); a bigger miss is a real timing problem.
# Re-roll: once all boards are built, every board that only missed timing (TIMING-FAILED,
# miss <= REROLL_MAX_MISS) is implemented again from its own build's checkpoints with other
# placer and router directives until one meets timing and the sign-off gates
# (reroll_bitstream.tcl; why: Megamiga's doc/developers/timing_closure.md, the HyperRAM read
# strobe). The winner replaces mega65_<b>.bit; mega65_<b>_reroll.txt says which attempt won.
# Prints "RESULT <board> OK|FAILED|TIMING-FAILED|SIGNOFF-FAILED|REROLL-FAILED ..." per board
# in the summary.
set -u
cd "$(dirname "$0")"

boards=()
reroll=1
for arg in "$@"; do
    case "$arg" in
        --no-reroll) reroll=0 ;;
        -*) echo "ERROR: unknown option '$arg'" >&2; exit 1 ;;
        *)  boards+=("$arg") ;;
    esac
done
[ "${#boards[@]}" -gt 0 ] || boards=(R6)
command -v vivado >/dev/null 2>&1 || { echo "ERROR: vivado is not on the PATH." >&2; exit 1; }

for i in "${!boards[@]}"; do
    boards[$i]=$(printf '%s' "${boards[$i]}" | tr '[:lower:]' '[:upper:]')
    [ -f "CORE-${boards[$i]}.xpr" ] || { echo "ERROR: no CORE-${boards[$i]}.xpr" >&2; exit 1; }
done

# assemble the firmware once up front: a firmware error stops here, not in synthesis
( cd m2m-rom && ./make_rom.sh ) || exit 1

jobs="${JOBS:-8}"
max_miss="${REROLL_MAX_MISS:-0.3}"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# The last "RESULT <board> ..." line of a Vivado log, empty if there is none.
result_of() { grep -h "^RESULT $1 " "$2" 2>/dev/null | tail -n 1; }

for board in "${boards[@]}"; do
    echo "=== ${board}: build started $(date) ==="
    b=$(lower "$board")
    # Re-roll files from an earlier run describe an older bitstream.
    rm -f "CORE-${board}.runs/impl_1/mega65_${b}_reroll"*
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
           -tclargs "${board}" "${jobs}"
    echo "=== ${board}: build finished $(date) ==="
done

# Second pass: re-roll the boards that only missed timing.
note=()
rerolled=()
for i in "${!boards[@]}"; do
    board=${boards[$i]}
    result=$(result_of "${board}" "build_${board}.log")
    case "${result}" in
        "RESULT ${board} TIMING-FAILED "*) ;;
        *) continue ;;
    esac
    if [ "${reroll}" = "0" ]; then
        note[$i]="not re-rolled: --no-reroll"
        continue
    fi
    wns=$(sed -n 's/.* WNS=\([^ ]*\).*/\1/p' <<< "${result}")
    whs=$(sed -n 's/.* WHS=\([^ ]*\).*/\1/p' <<< "${result}")
    if ! awk -v w="${wns}" -v h="${whs}" -v m="${max_miss}" \
            'BEGIN { exit !(w != "" && h != "" && w + 0 >= -m && h + 0 >= -m) }'; then
        note[$i]="not re-rolled: the miss is larger than REROLL_MAX_MISS=${max_miss} ns"
        continue
    fi
    # The re-roll continues from the checkpoints of this very build, so they
    # must be newer than the journal that its Vivado session started with.
    run="CORE-${board}.runs/impl_1"
    b=$(lower "${board}")
    stale=""
    for f in "${run}/mega65_${b}_opt.dcp" "${run}/mega65_${b}_physopt.dcp" \
             "${run}/mega65_${b}_postroute_physopt.dcp"; do
        [ "${f}" -nt "build_${board}.jou" ] || stale="${f}"
    done
    if [ -n "${stale}" ]; then
        note[$i]="not re-rolled: ${stale} is missing or older than this build"
        continue
    fi
    echo "=== ${board}: re-roll started $(date) ==="
    vivado -mode batch -notrace -source reroll_bitstream.tcl \
           -log "build_${board}_reroll.log" -journal "build_${board}_reroll.jou" \
           -tclargs "${board}" "${jobs}" "${wns}" "${whs}"
    echo "=== ${board}: re-roll finished $(date) ==="
    rerolled[$i]=1
done

echo "=== Summary ==="
failed=0
for i in "${!boards[@]}"; do
    board=${boards[$i]}
    first=$(result_of "${board}" "build_${board}.log")
    [ -n "${first}" ] || first="RESULT ${board} NONE - see build_${board}.log"
    final="${first}"
    if [ -n "${rerolled[$i]:-}" ]; then
        final=$(result_of "${board}" "build_${board}_reroll.log")
        [ -n "${final}" ] || final="RESULT ${board} REROLL-FAILED - see build_${board}_reroll.log"
    fi
    echo "${final}"
    if [ -n "${rerolled[$i]:-}" ]; then
        echo "    first pass: ${first#"RESULT ${board} "}"
        grep -h -e "^REROLL ${board} " -e "^GATE ${board}:" "build_${board}_reroll.log" 2>/dev/null \
            | sed 's/^/    /'
    fi
    if [ -n "${note[$i]:-}" ]; then echo "    ${note[$i]}"; fi
    case "${final}" in
        "RESULT ${board} OK "*) ;;
        *) failed=1 ;;
    esac
done
exit "${failed}"
