#!/usr/bin/env bash
# Tear down the Docker-free headscale started by scripts/e2e-up-native.sh.
# Best-effort: safe to run even if nothing is up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$REPO_ROOT/e2e/.native-run"
PIDFILE="$RUN_DIR/headscale.pid"

log() { echo "[e2e-down-native] $*" >&2; }

if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
        log "stopping headscale (pid $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
fi

rm -rf "$RUN_DIR"
log "done."
