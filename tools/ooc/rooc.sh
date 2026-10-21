#!/usr/bin/env bash
# rooc.sh - run cpu_ooc.tcl on the Fedora build host ("ssh fedora", Vivado 2022.2)
# for the checkout this script is in.
#   rooc.sh <name> [synth|explore [placedir]]
#                            copy rtl/cpu + tools/ooc to fedora:~/pcxt-builds/<name>,
#                            run there, fetch out/*.rpt + the log to ~/pcxt-work/ooc/<name>/
#   rooc.sh clean <name>     remove fedora:~/pcxt-builds/<name>
set -euo pipefail
H=fedora
B=pcxt-builds
root=$(cd "$(dirname "$0")/../.." && pwd)
if [ "${1:-}" = clean ]; then ssh $H "rm -rf ~/$B/$2 ~/$B/$2.log"; exit 0; fi
name=$1; mode=${2:-}
ssh $H "rm -rf ~/$B/$name && mkdir -p ~/$B/$name/rtl ~/$B/$name/tools"
tar -C "$root" -cf - rtl/cpu tools/ooc/cpu_ooc.tcl tools/ooc/cpu_ooc_top.v | ssh $H "tar -xf - -C ~/$B/$name"
ssh $H "cd ~/$B/$name/tools/ooc && source ~/xilinx-env.sh && vivado -mode batch -nojournal -nolog -source cpu_ooc.tcl ${mode:+-tclargs $mode ${3:-}} > ~/$B/$name.log 2>&1" || true
dest=$HOME/pcxt-work/ooc/$name
mkdir -p "$dest"
scp -q "$H:$B/$name/tools/ooc/out/*.rpt" "$dest/" 2>/dev/null || true
scp -q "$H:$B/$name.log" "$dest/ooc.log"
grep -E "^ERROR|CRITICAL WARNING" "$dest/ooc.log" | head -20 || true
f=$dest/timing.rpt; [ -f "$f" ] || f=$dest/synth_timing.rpt
grep -A3 "WNS(ns)" "$f" | head -4
