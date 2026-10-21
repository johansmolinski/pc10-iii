#!/bin/bash
# One-time setup of headless MartyPC on the build host (default: ssh fedora).
#
#   tools/martypc/setup_fedora.sh [MARTYPC_SRC]
#
# MARTYPC_SRC: local MartyPC checkout (default ~/pcxt-work/ext/martypc-full,
# commit 05c0d08). It is copied to the host (without target/ and .git/),
# patched with headless-trace.patch and built in release mode.
# Installs Rust user-locally with rustup (never a system Rust) and the one
# system package the build needs (systemd-devel, for libudev/serialport).
set -euo pipefail
HOST=${MARTY_HOST:-fedora}
SRC=${1:-$HOME/pcxt-work/ext/martypc-full}
RSRC=${MARTY_RSRC:-/home/user/pcxt-work/ext/martypc-full}
HERE=$(cd "$(dirname "$0")" && pwd)

ssh "$HOST" 'test -x ~/.cargo/bin/cargo || curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal'
ssh "$HOST" 'rpm -q systemd-devel >/dev/null || sudo dnf install -y systemd-devel'

ssh "$HOST" "rm -rf '$RSRC' && mkdir -p '$RSRC'"
tar cf - -C "$SRC" --exclude=./target --exclude=./.git . | ssh "$HOST" "tar xf - -C '$RSRC'"
ssh "$HOST" "cd '$RSRC' && patch -p1" < "$HERE/headless-trace.patch"
# rust-toolchain.toml pins 1.92.0 (+ the wasm32 target); rustup fetches it on the first build.
ssh "$HOST" "cd '$RSRC' && ~/.cargo/bin/cargo build --release -p martypc_headless 2>&1 | tail -3"
ssh "$HOST" "ls -la '$RSRC/target/release/martypc_headless'"
# Second binary for sst_trace.sh: MartyPC's SingleStepTests runner with trace comments.
ssh "$HOST" "cd '$RSRC' && ~/.cargo/bin/cargo build --release -p martypc_headless \
    --features cpu_tests,cpu_trace_comments --target-dir target-sst 2>&1 | tail -1"
