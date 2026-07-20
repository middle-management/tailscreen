#!/usr/bin/env bash
# Stand up a real (headless) X server + VNC on a Linux host and run the portable
# tailscreen viewer into it — then watch from any VNC client (macOS Screen
# Sharing, Finder ⌘K → vnc://<host>:5900). This sidesteps XQuartz entirely:
# XQuartz's default DISPLAY is a Mac-only launchd socket (invisible from inside
# a Linux guest → SDL falls back to the non-displaying `offscreen` driver), and
# its indirect GLX is disabled by default (crashes SDL's window-create GL probe).
# A native Xvfb has neither problem, and it's reproducible.
#
# Run this INSIDE the Linux host/guest (e.g. `orb -m <machine> bash`), from the
# repo root. Requires: xvfb, x11vnc, fluxbox (apt install -y xvfb x11vnc fluxbox)
# and the viewer already built (cd Apps/linux && swift build).
#
# Usage:
#   scripts/linux-viewer-vnc.sh <sharer-host> [extra tailscreen-viewer args...]
#   TAILSCREEN_TS_AUTHKEY=tskey-... scripts/linux-viewer-vnc.sh 100.x.y.z --no-audio
#
# Env:
#   VNC_DISPLAY   X display number to use (default :1)
#   VNC_PORT      x11vnc RFB port (default 5900)
#   VNC_GEOMETRY  Xvfb screen geometry (default 1920x1080x24)
#
# Stop everything: scripts/linux-viewer-vnc.sh --stop
set -euo pipefail

DISPLAY_NUM="${VNC_DISPLAY:-:1}"
PORT="${VNC_PORT:-5900}"
GEOMETRY="${VNC_GEOMETRY:-1920x1080x24}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/Apps/linux/.build/debug/tailscreen-viewer"

use_systemd() { command -v systemd-run >/dev/null && [ -d /run/systemd/system ]; }

stop_all() {
    echo "Stopping X + VNC stack…"
    if use_systemd; then
        sudo systemctl stop 'tsviewer-*' 2>/dev/null || true
        sudo systemctl reset-failed 'tsviewer-*' 2>/dev/null || true
    else
        pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
        pkill x11vnc 2>/dev/null || true
        pkill fluxbox 2>/dev/null || true
    fi
}

if [ "${1:-}" = "--stop" ]; then stop_all; exit 0; fi
if [ $# -lt 1 ]; then
    echo "usage: $0 <sharer-host> [tailscreen-viewer args…]   (or --stop)" >&2
    exit 2
fi
SHARER_HOST="$1"; shift

if [ ! -x "$BIN" ]; then
    echo "Building the viewer first (cd Apps/linux && swift build)…"
    (cd "$REPO_ROOT/Apps/linux" && swift build)
fi

stop_all
sleep 1

# macOS Screen Sharing hangs against a no-auth VNC server (it expects the VNC
# password handshake), so always run x11vnc with a password. Default "tailscreen";
# override with VNC_PASSWORD.
VNC_PASS="${VNC_PASSWORD:-tailscreen}"
PASSFILE=/tmp/tsviewer-vncpass
x11vnc -storepasswd "$VNC_PASS" "$PASSFILE" >/dev/null 2>&1

echo "Starting Xvfb $DISPLAY_NUM ($GEOMETRY) + fluxbox + x11vnc:$PORT …"
if use_systemd; then
    sudo systemd-run --unit=tsviewer-xvfb Xvfb "$DISPLAY_NUM" -screen 0 "$GEOMETRY"
    sleep 2
    sudo systemd-run --unit=tsviewer-wm --setenv=DISPLAY="$DISPLAY_NUM" fluxbox
    sleep 1
    sudo systemd-run --unit=tsviewer-vnc \
        x11vnc -display "$DISPLAY_NUM" -forever -shared -rfbauth "$PASSFILE" -rfbport "$PORT" -listen 0.0.0.0
    sleep 2
else
    setsid Xvfb "$DISPLAY_NUM" -screen 0 "$GEOMETRY" >/tmp/tsviewer-xvfb.log 2>&1 < /dev/null &
    sleep 2
    setsid env DISPLAY="$DISPLAY_NUM" fluxbox >/tmp/tsviewer-wm.log 2>&1 < /dev/null &
    sleep 1
    setsid x11vnc -display "$DISPLAY_NUM" -forever -shared -rfbauth "$PASSFILE" -rfbport "$PORT" -listen 0.0.0.0 \
        >/tmp/tsviewer-vnc.log 2>&1 < /dev/null &
    sleep 2
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "───────────────────────────────────────────────────────────"
echo "  VNC ready. On your Mac: Finder ⌘K → vnc://${HOST_IP}:${PORT}"
echo "  Password: ${VNC_PASS}. Then approve the viewer on the sharer."
echo "───────────────────────────────────────────────────────────"
echo
echo "Running viewer into $DISPLAY_NUM (Ctrl-C to stop the viewer; run --stop to tear down X/VNC)…"
exec env DISPLAY="$DISPLAY_NUM" "$BIN" "$SHARER_HOST" "$@"
