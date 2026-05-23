#!/usr/bin/env bash
# Docker-free local headscale for CI (and anyone without Docker). Downloads the
# pinned headscale release binary, writes a config with absolute temp paths,
# starts `headscale serve` in the background, mints a reusable/ephemeral
# pre-auth key, and emits the same env exports as scripts/e2e-up.sh:
#
#   eval "$(./scripts/e2e-up-native.sh)"
#
# Tear down with scripts/e2e-down-native.sh (kills the pid in the run dir).
#
# Keep HEADSCALE_VERSION in lockstep with e2e/docker-compose.yml so local
# (Docker) and CI (native) exercise an identical control plane.
set -euo pipefail

HEADSCALE_VERSION="${HEADSCALE_VERSION:-0.26.1}"
USER_NAME="tailscreen-test"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$REPO_ROOT/e2e/.native-run"
BIN_DIR="$REPO_ROOT/e2e/.native-bin"
CONFIG="$RUN_DIR/config.yaml"
PIDFILE="$RUN_DIR/headscale.pid"

# Informational output → stderr so `eval $(...)` only picks up the exports.
log() { echo "[e2e-up-native] $*" >&2; }

# Map uname → headscale release asset suffix.
case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) log "ERROR: unsupported OS $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
    arm64 | aarch64) arch="arm64" ;;
    x86_64 | amd64) arch="amd64" ;;
    *) log "ERROR: unsupported arch $(uname -m)"; exit 1 ;;
esac

BIN="$BIN_DIR/headscale-$HEADSCALE_VERSION-$os-$arch"
if [ ! -x "$BIN" ]; then
    mkdir -p "$BIN_DIR"
    url="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_${os}_${arch}"
    log "downloading headscale $HEADSCALE_VERSION ($os/$arch)..."
    curl -fsSL "$url" -o "$BIN"
    chmod +x "$BIN"
fi

# Fresh run dir each invocation so a stale db/socket can't wedge startup.
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

# Derive a native config from the committed container config: rewrite the
# absolute container paths (/var/lib/headscale, /var/run) to the temp run dir.
sed \
    -e "s#/var/lib/headscale#$RUN_DIR#g" \
    -e "s#/var/run/headscale.sock#$RUN_DIR/headscale.sock#g" \
    "$REPO_ROOT/e2e/headscale/config.yaml" > "$CONFIG"

log "starting headscale serve..."
"$BIN" --config "$CONFIG" serve >"$RUN_DIR/headscale.log" 2>&1 &
echo "$!" > "$PIDFILE"

log "waiting for headscale health..."
ready=""
for _ in $(seq 1 60); do
    if "$BIN" --config "$CONFIG" users list >/dev/null 2>&1; then
        ready="yes"
        break
    fi
    sleep 1
done
if [ -z "$ready" ]; then
    log "ERROR: headscale never became healthy; log tail:"
    tail -n 40 "$RUN_DIR/headscale.log" >&2 || true
    exit 1
fi

# Create user if missing (idempotent).
"$BIN" --config "$CONFIG" users create "$USER_NAME" >/dev/null 2>&1 || true

USER_ID=$(
    "$BIN" --config "$CONFIG" --output json users list 2>/dev/null \
        | python3 -c "import sys,json; [print(u['id']) for u in json.load(sys.stdin) if u['name']=='$USER_NAME']"
)
if [ -z "$USER_ID" ]; then
    log "ERROR: could not resolve user id for $USER_NAME"
    exit 1
fi

log "minting pre-auth key (reusable, ephemeral) for user id $USER_ID..."
KEY=$(
    "$BIN" --config "$CONFIG" --output json preauthkeys create \
        --user "$USER_ID" --reusable --ephemeral 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])'
)
if [ -z "$KEY" ]; then
    log "ERROR: failed to mint pre-auth key"
    exit 1
fi

log "ready. control_url=http://localhost:8080"
echo "export TAILSCREEN_TS_AUTHKEY=$KEY"
echo "export TAILSCREEN_TS_CONTROL_URL=http://localhost:8080"
