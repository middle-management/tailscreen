#!/usr/bin/env bash
# Local end-to-end harness: launches two real Tailscreen processes against a
# local headscale, drives one as the sharer (auto-picks main display, starts
# sharing on launch) and the other as the viewer (auto-discovers + connects),
# and waits for an `E2E_MARKER firstFrame` log line from the viewer.
#
# Local-only: full UI pipeline including SCStream, replayd, real display.
# Won't run on GitHub Actions macOS runners — no Screen Recording TCC.
#
# First run will pop a Screen Recording prompt for .build/debug/Tailscreen
# and time out. Grant permission and re-run; subsequent runs are unattended.

set -euo pipefail
set -m  # job control: each pipeline gets its own process group

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${TAILSCREEN_E2E_LOG:-/tmp/tailscreen-e2e.log}"
TIMEOUT_SECS="${TAILSCREEN_E2E_TIMEOUT:-90}"
BIN="$REPO_ROOT/.build/debug/Tailscreen"
SHARER_HOSTNAME_PREFIX="tailscreen-"  # matches TailscreenInstance.serverHostnamePrefix

if [ ! -x "$BIN" ]; then
    echo "[harness] Building Tailscreen..."
    make -C "$REPO_ROOT" build
fi

: > "$LOG"

pgids=()
cleanup() {
    echo
    echo "[harness] Tearing down…"
    for pgid in "${pgids[@]}"; do
        kill -TERM -- "-$pgid" 2>/dev/null || true
    done
    # Wait for the capture-helper's SCStream.stopCapture watchdog (~3 s)
    # before SIGKILL — same reason test-local.sh sleeps 4 s on shutdown.
    sleep 4
    for pgid in "${pgids[@]}"; do
        kill -KILL -- "-$pgid" 2>/dev/null || true
    done
    "$REPO_ROOT/scripts/e2e-down.sh" || true
    wait 2>/dev/null || true
    echo "[harness] Logs: $LOG"
}
trap cleanup EXIT INT TERM

echo "[harness] Bringing up headscale…"
# shellcheck disable=SC1091
eval "$("$REPO_ROOT/scripts/e2e-up.sh")"

launch() {
    local id="$1"
    shift
    env \
        TAILSCREEN_INSTANCE="$id" \
        TAILSCREEN_TS_AUTHKEY="$TAILSCREEN_TS_AUTHKEY" \
        TAILSCREEN_TS_CONTROL_URL="$TAILSCREEN_TS_CONTROL_URL" \
        "$@" \
        stdbuf -oL -eL "$BIN" 2>&1 \
        | stdbuf -oL sed "s/^/[$id] /" >> "$LOG" &
    local pgid
    pgid=$(ps -o pgid= -p "$!" | tr -d ' ')
    pgids+=("$pgid")
}

echo "[harness] Launching sharer (instance 1)…"
launch 1 \
    TAILSCREEN_AUTOSHARE_DISPLAY=1 \
    TAILSCREEN_AUTOSTART_SHARE=1

# Give the sharer a head start so its tsnet node registers before the viewer
# starts discovery. 5 s is overkill on a warm machine and harmless on a cold one.
sleep 5

echo "[harness] Launching viewer (instance 2)…"
# Prefix match against TailscreenInstance.serverHostnamePrefix. On a fresh
# headscale tailnet the only other tailscreen-* node is the sharer (the
# viewer's own node is excluded from its own peer list).
launch 2 \
    TAILSCREEN_AUTOCONNECT_TO="$SHARER_HOSTNAME_PREFIX"

echo "[harness] Waiting up to ${TIMEOUT_SECS}s for E2E_MARKER firstFrame on viewer…"
deadline=$((SECONDS + TIMEOUT_SECS))
while [ $SECONDS -lt $deadline ]; do
    if grep -q "^\[2\] .*E2E_MARKER firstFrame" "$LOG"; then
        echo "[harness] SUCCESS — viewer decoded a frame."
        exit 0
    fi
    sleep 1
done

echo "[harness] TIMEOUT — viewer never decoded a frame within ${TIMEOUT_SECS}s." >&2
echo "[harness] Tail of merged log:" >&2
tail -n 80 "$LOG" >&2
exit 1
