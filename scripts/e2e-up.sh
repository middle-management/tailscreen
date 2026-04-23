#!/usr/bin/env bash
# Start local headscale + emit env vars for the Cuple connectivity test.
# Usage: eval "$(./scripts/e2e-up.sh)"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose -f $REPO_ROOT/e2e/docker-compose.yml"
USER_NAME="cuple-test"

# All informational output goes to stderr so the caller can `eval $(...)` to
# pick up only the export lines.
log() { echo "[e2e-up] $*" >&2; }

log "bringing up headscale..."
$COMPOSE up -d >&2

log "waiting for headscale health..."
for _ in $(seq 1 60); do
    if $COMPOSE exec -T headscale headscale users list >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Create user if missing. `users create` fails if it already exists; ignore.
$COMPOSE exec -T headscale headscale users create "$USER_NAME" >/dev/null 2>&1 || true

# Newer headscale requires numeric user ID, not name.
USER_ID=$(
    $COMPOSE exec -T headscale headscale --output json users list 2>/dev/null \
    | python3 -c "import sys,json; [print(u['id']) for u in json.load(sys.stdin) if u['name']=='$USER_NAME']"
)
if [ -z "$USER_ID" ]; then
    log "ERROR: could not resolve user id for $USER_NAME"
    exit 1
fi

log "minting pre-auth key (reusable, ephemeral) for user id $USER_ID..."
KEY=$(
    $COMPOSE exec -T headscale \
        headscale --output json preauthkeys create \
            --user "$USER_ID" --reusable --ephemeral 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["key"])'
)

if [ -z "$KEY" ]; then
    log "ERROR: failed to mint pre-auth key"
    exit 1
fi

log "ready. control_url=http://localhost:8080"
echo "export CUPLE_TS_AUTHKEY=$KEY"
echo "export CUPLE_TS_CONTROL_URL=http://localhost:8080"
