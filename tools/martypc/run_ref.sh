#!/bin/bash
# Run headless MartyPC on the build host and fetch a reference trace.
#
#   tools/martypc/run_ref.sh -b BIOS -c CLOCKS [-n NAME] [options]
#
#   -b BIOS            BIOS image (8/16/32/64 KB, mapped to the top of 1 MB)
#   -c CLOCKS          8088 clocks to run (MartyPC benchmark "Cycles")
#   -n NAME            run name (default: <bios basename>-<clocks>)
#   --no-refresh       dram_refresh_simulation = false
#   --no-wait-states   wait_states = false (also disables refresh DMA)
#   --cga-clock MODE   CGA clock_mode: Cycle (default), Dynamic, Character, Default
#   --no-itrace        skip the instruction trace run
#   --no-raw           do not fetch MartyPC's raw cycle trace (.log.gz)
#   --keep             keep the outputs on the host too ($MARTY_RWORK/NAME)
#
# Output: $MARTY_OUT (default ~/pcxt-work/martypc-traces)/NAME/
#   cycles.txt       normalized cycle trace (doc/martypc-reference.md)
#   instr.txt        normalized instruction trace (registers before each instruction)
#   CycleText.log.gz MartyPC's own cycle trace (unless --no-raw)
#   martypc.toml, pc10_ref.toml, romdef_pc10.toml, run.log, itrace-run.log
#
# Needs tools/martypc/setup_fedora.sh to have been run once.
set -euo pipefail
HOST=${MARTY_HOST:-fedora}
RSRC=${MARTY_RSRC:-/home/user/pcxt-work/ext/martypc-full}
RWORK=${MARTY_RWORK:-/home/user/pcxt-work/martypc-run}
OUT=${MARTY_OUT:-$HOME/pcxt-work/martypc-traces}
HERE=$(cd "$(dirname "$0")" && pwd)

BIOS= CLK= NAME= ITRACE=1 RAW=1 KEEP=0 OPTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -b) BIOS=$2; shift 2 ;;
        -c) CLK=$2; shift 2 ;;
        -n) NAME=$2; shift 2 ;;
        --no-refresh|--no-wait-states) OPTS+=("$1"); shift ;;
        --cga-clock) OPTS+=(--cga-clock "$2"); shift 2 ;;
        --no-itrace) ITRACE=0; shift ;;
        --no-raw) RAW=0; shift ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ -n "$BIOS" ] && [ -n "$CLK" ] || { sed -n '2,25p' "$0"; exit 2; }
[ -n "$NAME" ] || NAME="$(basename "${BIOS%.*}")-$CLK"
R="$RWORK/$NAME"

ssh "$HOST" "rm -rf '$R' && mkdir -p '$R/tools'"
scp -q "$HERE/remote_run.py" "$HERE/marty2norm.py" "$HOST:$R/tools/"
scp -q "$BIOS" "$HOST:$R/tools/bios.rom"

ssh "$HOST" bash -s -- "$R" "$RSRC" "$CLK" "$ITRACE" "$RAW" "${OPTS[@]}" <<'EOF'
set -euo pipefail
R=$1 RSRC=$2 CLK=$3 ITRACE=$4 RAW=$5; shift 5
cd "$R"
python3 tools/remote_run.py --marty "$RSRC" --bios tools/bios.rom --cycles "$CLK" --out cyc "$@" > /dev/null
python3 tools/marty2norm.py cyc/output/traces/CycleText.log -o cycles.txt
if [ "$RAW" = 1 ]; then gzip -1 -c cyc/output/traces/CycleText.log > CycleText.log.gz; fi
cp cyc/martypc.toml cyc/configs/machines/pc10_ref.toml cyc/configs/rom_definitions/romdef_pc10.toml cyc/run.log .
if [ "$ITRACE" = 1 ]; then
    python3 tools/remote_run.py --marty "$RSRC" --bios tools/bios.rom --cycles "$CLK" --mode Instruction --out ins "$@" > /dev/null
    python3 tools/marty2norm.py --itrace ins/output/traces/Instruction.log -o instr.txt
    cp ins/run.log itrace-run.log
fi
rm -rf cyc ins
grep -E '^(pc10-iii|Ran)' run.log
EOF

mkdir -p "$OUT/$NAME"
ssh "$HOST" "cd '$R' && tar cf - --exclude=tools ." | tar xf - -C "$OUT/$NAME"
[ "$KEEP" = 1 ] || ssh "$HOST" "rm -rf '$R'"
ls -la "$OUT/$NAME"
