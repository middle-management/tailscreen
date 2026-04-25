#!/usr/bin/env bash
# Launch N Tailscreen instances side-by-side for local testing (default 2). Logs
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
# group. We then kill the whole group on exit to take down Tailscreen + sed +
# stdbuf in one shot — `$!` of a pipeline only points at the last stage,
# not the Tailscreen binary itself.
set -m

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

LOG="${TAILSCREEN_LOG:-/tmp/tailscreen-merged.log}"
BIN=".build/debug/Tailscreen"

if [ ! -x "$BIN" ]; then
    echo "Building Tailscreen..."
    make build
fi

: > "$LOG"

pgids=()
cleanup() {
    echo
    echo "Shutting down Tailscreen instances..."
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
    # Set TAILSCREEN_DEBUG_ZOMBIES=1 before running this script to turn on Foundation's
    # zombie / malloc-stack-logging machinery. NSZombieEnabled makes every
    # deallocated Obj-C object log on any subsequent message instead of
    # crashing, so when Tailscreen segfaults in objc_release after disconnect
    # the console instead says
    #     -[SomeClass release]: message sent to deallocated instance 0x…
    # which is the real culprit we can't get from the crash stack alone.
    # MallocStackLoggingNoCompact + MallocScribble cost memory and CPU;
    # worth it for diagnosis, not for everyday use.
    local debug_env=""
    if [ "${TAILSCREEN_DEBUG_ZOMBIES:-0}" = "1" ]; then
        # Mode A: NSZombieEnabled. Lets every over-release *log* instead of
        # crashing. Run this first to see which class the zombie is.
        debug_env="NSZombieEnabled=YES \
MallocStackLogging=1 \
MallocStackLoggingNoCompact=1 \
MallocScribble=1 \
CFZombieLevel=17"
    fi
    if [ "${TAILSCREEN_DEBUG_ASAN:-0}" = "1" ]; then
        # Mode C: AddressSanitizer via Swift's -sanitize=address. Catches
        # the use-after-free at the exact instruction where it happens with
        # a full stack, unlike the post-mortem pool-pop crash. Needs a
        # separate debug build: `swift build -Xswiftc -sanitize=address`
        # (the ASan runtime is linked in). Much faster than libgmalloc and
        # plays nicely with ScreenCaptureKit's XPC.
        debug_env="$debug_env ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:print_stacktrace=1"
    fi

    if [ "${TAILSCREEN_DEBUG_GMALLOC:-0}" = "1" ]; then
        # Mode B: libgmalloc. In theory catches over-releases at the caller.
        # In practice it's too slow for ScreenCaptureKit's XPC path —
        # SCShareableContent timed out at connect and the server hung at
        # "Listening on Tailscale port 7447" with the screen-capture daemon
        # never responding. Prefer Instruments' Zombies template for
        # pinpointing: `instruments -t Zombies -D /tmp/zombies.trace \
        #   .build/debug/Tailscreen` (while debug symbols are intact).
        echo "WARNING: TAILSCREEN_DEBUG_GMALLOC=1 breaks ScreenCaptureKit." >&2
        echo "         Use Instruments' Zombies template instead." >&2
        debug_env="$debug_env DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib \
MALLOC_PROTECT_BEFORE=1 \
MALLOC_FILL_SPACE=1 \
MALLOC_STRICT_SIZE=1"
    fi

    env TAILSCREEN_INSTANCE="$id" $debug_env stdbuf -oL -eL "$BIN" 2>&1 \
        | stdbuf -oL sed "s/^/[$id] /" >> "$LOG" &
    # `$!` is the PID of the last stage (sed); its pgid is shared with Tailscreen
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
if [ "${TAILSCREEN_DEBUG_ZOMBIES:-0}" = "1" ]; then
    echo "Zombie diagnostics ENABLED. Over-released Obj-C objects will log"
    echo "'message sent to deallocated instance' instead of crashing."
fi
if [ "${TAILSCREEN_DEBUG_ASAN:-0}" = "1" ]; then
    echo "ASan ENABLED. Rebuild with:"
    echo "  swift build -Xswiftc -sanitize=address"
    echo "ASan will print a full stack at the use-after-free site on crash."
fi
if [ "${TAILSCREEN_DEBUG_GMALLOC:-0}" = "1" ]; then
    echo "libgmalloc ENABLED. Over-releases crash IMMEDIATELY at the caller"
    echo "that did the extra release, with a stack trace in the .ips report."
fi
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
