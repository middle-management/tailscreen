#!/usr/bin/env bash
# End-to-end Linux sharer → Linux viewer over a local headscale, on one box.
#
# This is the first test that exercises the REAL sharer data plane off macOS:
# the portable `TailscaleScreenShareServer` (Packages/TailscreenKit's
# TailscreenSharer target) driven by the X11 `CaptureEncoding` backend, serving
# the real receive path (TsnetTransport + ViewerSession + FFmpeg decode).
# `TailscreenTestSharer` stands in for a sharer; this *is* one.
#
# What it proves that the unit tests can't: admission, the HELLO/HELLO_ACK
# capability handshake, RTP fan-out over a real tsnet link, and that pixels
# captured from an X display come out the far end as decodable frames.
#
#   ./scripts/e2e-linux-sharer.sh
#
# Local-only, like every tsnet path in this repo — CI can't run it (see
# CLAUDE.md on why tsnet suites are local-only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${TAILSCREEN_E2E_DIR:-/tmp/tailscreen-linux-e2e}"
DISPLAY_NUM="${TAILSCREEN_E2E_DISPLAY:-:77}"
FRAMES="${TAILSCREEN_E2E_FRAMES:-15}"
TIMEOUT="${TAILSCREEN_E2E_TIMEOUT:-90}"
FPS="${TAILSCREEN_E2E_FPS:-10}"

log() { echo "[e2e-linux-sharer] $*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: $1 not found"; exit 1; }; }
need Xvfb
need swift

cleanup() {
    local rc=$?
    log "tearing down..."
    [ -n "${SHARER_PID:-}" ] && kill "$SHARER_PID" 2>/dev/null || true
    [ -n "${CONTENT_PID:-}" ] && kill "$CONTENT_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
    "$REPO_ROOT/scripts/e2e-down-native.sh" >/dev/null 2>&1 || true
    exit $rc
}
trap cleanup EXIT INT TERM

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

log "building the sharer + probe..."
export PKG_CONFIG_PATH="$REPO_ROOT/Packages/TailscaleKit${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# One product per invocation: `swift build` honours only the last `--product`,
# so passing both silently leaves one binary stale — which is exactly the kind
# of thing that makes a harness lie about what it tested.
swift build --package-path "$REPO_ROOT/Packages/TailscreenLinuxBackends" --product tailscreen-sharer-linux
swift build --package-path "$REPO_ROOT/Packages/TailscreenLinuxBackends" --product tailscreen-viewer-probe
BIN="$REPO_ROOT/Packages/TailscreenLinuxBackends/.build/debug"

log "starting headscale..."
# Deliberately NOT `eval "$(e2e-up-native.sh)"`: command substitution swallows
# the script's exit status, so a control plane that failed to bind (a stale
# instance still holding :3478, say) would silently yield empty exports and the
# run would carry on to fail much later, somewhere misleading. Capture, check,
# then eval.
HS_ENV="$RUN_DIR/headscale-env.sh"
if ! "$REPO_ROOT/scripts/e2e-up-native.sh" > "$HS_ENV"; then
    log "ERROR: headscale failed to start (is one already running? check :8080 and :3478)"
    exit 1
fi
if ! grep -q TAILSCREEN_TS_AUTHKEY "$HS_ENV"; then
    log "ERROR: headscale started but minted no auth key; contents:"
    cat "$HS_ENV" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$HS_ENV"

log "starting Xvfb on $DISPLAY_NUM with test content..."
Xvfb "$DISPLAY_NUM" -screen 0 1280x720x24 >/dev/null 2>&1 &
XVFB_PID=$!
sleep 2
# Real content on the root window, so "we received video" can mean real pixels
# rather than a uniform grey rectangle that would pass a frame-count assertion.
if command -v convert >/dev/null 2>&1 && command -v display >/dev/null 2>&1; then
    convert -size 1280x720 gradient:red-blue "$RUN_DIR/pattern.png"
    DISPLAY="$DISPLAY_NUM" display -immutable -geometry +0+0 "$RUN_DIR/pattern.png" >/dev/null 2>&1 &
    CONTENT_PID=$!
    sleep 2
else
    log "NOTE: ImageMagick absent — capturing a blank root; the nonUniform check will be vacuous"
fi

log "starting the Linux sharer..."
DISPLAY="$DISPLAY_NUM" "$BIN/tailscreen-sharer-linux" \
    --hostname ts-sharer --state-dir "$RUN_DIR/sharer-state" --fps "$FPS" \
    > "$RUN_DIR/sharer.log" 2>&1 &
SHARER_PID=$!

log "waiting for the sharer to come up..."
for _ in $(seq 1 60); do
    grep -q "READY" "$RUN_DIR/sharer.log" 2>/dev/null && break
    kill -0 "$SHARER_PID" 2>/dev/null || { log "ERROR: sharer died"; tail -20 "$RUN_DIR/sharer.log" >&2; exit 1; }
    sleep 2
done
SHARER_IP="$(grep -a -o 'ip4=[^ ]*' "$RUN_DIR/sharer.log" | head -1 | cut -d= -f2)"
[ -n "$SHARER_IP" ] || { log "ERROR: sharer never reported an address"; tail -20 "$RUN_DIR/sharer.log" >&2; exit 1; }
log "sharer up at $SHARER_IP"

log "running the viewer probe..."
# Its own state dir: two tsnet nodes sharing one directory reuse a machine key
# and never see each other.
set +e
"$BIN/tailscreen-viewer-probe" \
    --host "$SHARER_IP" --hostname ts-probe --state-dir "$RUN_DIR/probe-state" \
    --frames "$FRAMES" --timeout "$TIMEOUT" > "$RUN_DIR/probe.log" 2>&1
PROBE_RC=$?
set -e

echo
grep -a -E "^\[sharer\]" "$RUN_DIR/sharer.log" || true
grep -a -E "^\[probe\]" "$RUN_DIR/probe.log" || true
echo

if [ $PROBE_RC -ne 0 ] || ! grep -aq "PROBE_OK" "$RUN_DIR/probe.log"; then
    log "FAIL — logs in $RUN_DIR"
    exit 1
fi
if ! grep -aq "nonUniform=true" "$RUN_DIR/probe.log"; then
    log "FAIL — frames decoded but every one was a flat colour (capture produced no content)"
    exit 1
fi
# Capability honesty, end to end. THIS sharer — `tailscreen-sharer-linux`, the
# headless automation binary — supplies no injector and no annotation overlay,
# so it must advertise neither bit. A viewer that sees them enables affordances
# whose input goes nowhere, and the symptom is not an error but a toolbar that
# silently does nothing. Both bits defaulted to claimed at some point;
# asserting on the wire is what stops that recurring.
#
# Note this is now a claim about the headless binary specifically, not about
# Linux: the GTK app DOES render annotations (`CGtkOverlay`) and advertises the
# bit whenever it managed to build an overlay. A headless sharer has no window
# to put one in, which is exactly why it must keep saying so.
if grep -aq "serverCaps=.*remoteControl" "$RUN_DIR/probe.log"; then
    log "FAIL — sharer advertised .remoteControl with no injector supplied"
    exit 1
fi
if grep -aq "serverCaps=.*annotations" "$RUN_DIR/probe.log"; then
    log "FAIL — sharer advertised .annotations with no overlay to render them on"
    exit 1
fi
log "PASS — real X11 capture reached the viewer as decodable, non-blank frames,"
log "       and the sharer advertised only capabilities it actually has"
