#!/usr/bin/env bash
# Build a PC10-III checkout on the Fedora build host ("ssh fedora"); a variant of Megamiga's
# ~/aexp-work/remote/rbuild.sh (see its README for the host: Vivado 2022.2 in ~/Xilinx,
# ~/xilinx-env.sh). Builds live in fedora:~/pcxt-builds/<name> (log <name>.log, pid <name>.pid),
# never in Megamiga's ~/builds.
#
#   rbuild.sh start <checkout> <name> [board ...]   copy <checkout> (repo root, submodules as
#                                                   files, no .git/.claude/Vivado run dirs) and
#                                                   start CORE/build_all.sh in the background
#   rbuild.sh status <name>      RUNNING/FINISHED, timing lines, the RESULT/summary
#   rbuild.sh wait <name>        block until build_all.sh has exited, print the summary
#   rbuild.sh fetch <name> <board> [dest]
#                                bit, reports and log to dest (default ~/pcxt-work/builds/<name>)
#   rbuild.sh stop <name>        kill this build's processes (only ours, by PID and cwd)
#
# Rules on the host: never stop a Megamiga build (running in parallel is fine: 16 cores,
# 62 GB); never print ~/xilinx.txt. JOBS is passed through to build_all.sh.
set -euo pipefail
H=fedora
B=pcxt-builds
cmd=${1:-}; shift || true

case "$cmd" in
start)
    src=$1 name=$2; shift 2
    [ -f "$src/CORE/build_all.sh" ] || { echo "no CORE/build_all.sh in $src" >&2; exit 1; }
    ssh $H "test ! -e ~/$B/$name" || { echo "fedora:~/$B/$name exists - pick another name" >&2; exit 1; }
    ssh $H "mkdir -p ~/$B/$name"
    tar -C "$src" -cf - --exclude='*.runs' --exclude='*.cache' --exclude='*.hw' \
        --exclude='*.ip_user_files' --exclude='*.sim' --exclude='*.gen' --exclude='.git' \
        --exclude='./.claude' --exclude='obj_*' --exclude='.tools' . \
        | ssh -o Compression=no $H "tar -xf - -C ~/$B/$name"
    env=""
    [ -n "${JOBS:-}" ] && env+="JOBS=$JOBS "
    ssh $H "( cd ~/$B/$name/CORE && source ~/xilinx-env.sh && exec env $env ./build_all.sh $* ) > ~/$B/$name.log 2>&1 < /dev/null & echo \$! > ~/$B/$name.pid; echo started pid \$(cat ~/$B/$name.pid)"
    ;;
status)
    name=$1
    ssh $H "if kill -0 \$(cat ~/$B/$name.pid) 2>/dev/null; then echo RUNNING; else echo FINISHED; fi;
            grep -E '^(RESULT|GATE)' ~/$B/$name.log || true;
            sed -n '/^=== Summary/,\$p' ~/$B/$name.log | head -20;
            for f in ~/$B/$name/CORE/CORE-R*.runs/*/runme.log; do [ -f \$f ] && { echo \"== \$f\"; grep 'Timing Summary' \$f | tail -2 || true; tail -1 \$f; }; done"
    ;;
wait)
    name=$1
    ssh $H "while kill -0 \$(cat ~/$B/$name.pid) 2>/dev/null; do sleep 60; done; sed -n '/^=== Summary/,\$p' ~/$B/$name.log | head -20"
    ;;
fetch)
    name=$1 board=$2 dest=${3:-$HOME/pcxt-work/builds/$name}
    b=$(printf '%s' "$board" | tr '[:upper:]' '[:lower:]')
    mkdir -p "$dest"
    d="$B/$name/CORE/CORE-$board.runs/impl_1"
    scp "$H:$d/mega65_$b.bit" "$H:$d/*timing_summary_routed.rpt" "$H:$d/*utilization_placed.rpt" \
        "$H:$d/utilization_hierarchical.rpt" "$H:$d/*route_status.rpt" "$dest/" 2>/dev/null || true
    scp "$H:$B/$name.log" "$dest/build.log"
    scp "$H:$B/$name/CORE/CORE-$board.runs/synth_1/runme.log" "$dest/synth_runme.log" 2>/dev/null || true
    ls -l "$dest"
    ;;
stop)
    name=$1
    ssh $H "for p in \$(pgrep -x vivado; pgrep -f '^.*/unwrapped/.*vivado' || true); do case \$(readlink /proc/\$p/cwd) in \$HOME/$B/$name/*) kill \$p;; esac; done; kill \$(cat ~/$B/$name.pid) 2>/dev/null; echo stopped"
    ;;
*)
    sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
