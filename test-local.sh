#!/usr/bin/env bash
# Launch N Cuple instances side-by-side for local testing (default 2). Logs
# from every process land in one file, prefixed with [i]. Stopping this
# script (Ctrl-C or exit) shuts all instances down.
#
# Usage: ./test-local.sh [count]
set -euo pipefail

COUNT="${1:-2}"
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    echo "count must be a positive integer, got '$COUNT'" >&2
    exit 2
fi

# Enable job control so each backgrounded pipeline gets its own process
# group. We then kill the whole group on exit to take down Cuple + sed +
# stdbuf in one shot — `$!` of a pipeline only points at the last stage,
# not the Cuple binary itself.
set -m

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

LOG="${CUPLE_LOG:-/tmp/cuple-merged.log}"
BIN=".build/debug/Cuple"

if [ ! -x "$BIN" ]; then
    echo "Building Cuple..."
    make build
fi

: > "$LOG"

pgids=()
cleanup() {
    echo
    echo "Shutting down Cuple instances..."
    for pgid in "${pgids[@]}"; do
        kill -TERM -- "-$pgid" 2>/dev/null || true
    done
    sleep 1
    for pgid in "${pgids[@]}"; do
        kill -KILL -- "-$pgid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    echo "Logs: $LOG"
}
trap cleanup EXIT INT TERM

launch() {
    local id="$1"
    CUPLE_INSTANCE="$id" stdbuf -oL -eL "$BIN" 2>&1 \
        | stdbuf -oL sed "s/^/[$id] /" >> "$LOG" &
    # `$!` is the PID of the last stage (sed); its pgid is shared with Cuple
    # because we're in job-control mode.
    local pgid
    pgid=$(ps -o pgid= -p "$!" | tr -d ' ')
    pgids+=("$pgid")
}

for i in $(seq 1 "$COUNT"); do
    echo "Launching instance $i (wisp-$i)..."
    launch "$i"
done

echo
echo "$COUNT instances running. Merged log: $LOG"
echo "Ctrl-C to stop."
if [ "$COUNT" -eq 1 ]; then
    echo "In menubar: click Start Sharing or Browse Shares."
elif [ "$COUNT" -eq 2 ]; then
    echo "In menubar: click Start Sharing on one, Browse Shares on the other."
else
    echo "In menubar: click Start Sharing on one instance, Browse Shares + Connect on the others."
fi
echo

# Stream the merged log until Ctrl-C. trap handles the shutdown.
tail -f "$LOG"
