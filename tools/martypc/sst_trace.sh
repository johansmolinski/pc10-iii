#!/bin/bash
# Run single SingleStepTests 8088 v2 tests through MartyPC's test runner with
# a CycleText trace (bus/BIU annotations included, microcode text removed).
#
#   tools/martypc/sst_trace.sh XX INDEX [INDEX...]
#
#   XX     test file name without .json.gz (AA, 80.7, F6.6, ...)
#   INDEX  test index in that file (= "T <idx>" in ~/pcxt-work/sst-txt/XX.txt)
#
# Each trace goes to $MARTY_OUT/sst/XX-INDEX.txt (default
# ~/pcxt-work/martypc-traces) and to stdout. Format: doc/martypc-reference.md
# section 7. Needs setup_fedora.sh; builds the test-runner binary
# (target-sst/, features cpu_tests + cpu_trace_comments) on first use.
set -euo pipefail
HOST=${MARTY_HOST:-fedora}
RSRC=${MARTY_RSRC:-/home/user/pcxt-work/ext/martypc-full}
RWORK=${MARTY_RWORK:-/home/user/pcxt-work/martypc-run}
SUITE=${SST_SUITE:-$HOME/pcxt-work/ext/sst8088/v2}
BIOS=${MARTY_BIOS:-$HOME/pcxt-work/bios/GLABIOS_0.4.2_8X.ROM}  # only to satisfy MartyPC's start-up
OUT=${MARTY_OUT:-$HOME/pcxt-work/martypc-traces}/sst
HERE=$(cd "$(dirname "$0")" && pwd)

[ $# -ge 2 ] || { sed -n '2,15p' "$0"; exit 2; }
XX=$1; shift
EXE="$RSRC/target-sst/release/martypc_headless"
ssh "$HOST" "test -x '$EXE' || (cd '$RSRC' && ~/.cargo/bin/cargo build --release -p martypc_headless \
    --features cpu_tests,cpu_trace_comments --target-dir target-sst 2>&1 | tail -1)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tools" "$OUT"
cp "$HERE/remote_run.py" "$HERE/sst_annot.py" "$TMP/tools/"
cp "$BIOS" "$TMP/tools/bios.rom"
for i in "$@"; do
    mkdir -p "$TMP/t$i"
    python3 "$HERE/sst_extract.py" "$SUITE" "$XX" "$i" "$TMP/t$i" > "$TMP/t$i/header.txt"
done
R="$RWORK/sst-$XX-$$"
ssh "$HOST" "rm -rf '$R' && mkdir -p '$R'"
tar cf - -C "$TMP" . | ssh "$HOST" "tar xf - -C '$R'"

ssh "$HOST" bash -s -- "$R" "$RSRC" "$EXE" "$XX" "$@" <<'EOF'
set -euo pipefail
R=$1 RSRC=$2 EXE=$3 XX=$4; shift 4
OP=${XX%%.*}
cd "$R"
for i in "$@"; do
    python3 tools/remote_run.py --marty "$RSRC" --exe "$EXE" --bios tools/bios.rom --cycles 1 \
        --out "run$i" --tests "t$i" --test-opcode "$OP" > "t$i/run.log" 2>&1 || true
    {
        cat "t$i/header.txt"
        res=$(grep -h "^File: " "t$i/run.log" || true)
        if grep -q "Failed: 0 " <<< "$res" && grep -q "Passed: *1 " <<< "$res"; then
            echo "# MartyPC: PASS"
        else
            echo "# MartyPC: FAIL ($(echo $res | sed 's/  */ /g'))"
            grep -hE "FAILED|do not match|mismatch|failed" "t$i/test_run.log" 2>/dev/null | sed 's/^/#   /' | head -8 || true
        fi
        echo "# columns: c = test cycle (0 = first QS=F clock), mN = MartyPC cycle, then MartyPC's CycleText line"
        echo "#   (microcode text removed: uc NNN = microcode line), ';' = MartyPC trace comments, || exp = the test's cycle"
        python3 tools/sst_annot.py "run$i/output/traces/CycleText.log" "t$i/expected.txt"
    } > "out-$XX-$i.txt"
    rm -rf "run$i"
done
EOF

for i in "$@"; do
    ssh "$HOST" "cat '$R/out-$XX-$i.txt'" > "$OUT/$XX-$i.txt"
    cat "$OUT/$XX-$i.txt"
done
ssh "$HOST" "rm -rf '$R'"
