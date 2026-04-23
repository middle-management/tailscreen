#!/usr/bin/env bash
# One-shot: bring headscale up, run the connectivity test, tear down.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
    "$REPO_ROOT/scripts/e2e-down.sh" || true
}
trap cleanup EXIT

# shellcheck disable=SC1091
eval "$("$REPO_ROOT/scripts/e2e-up.sh")"

cd "$REPO_ROOT"
PKG_CONFIG_PATH="$REPO_ROOT/TailscaleKitPackage" \
    swift test --filter TailscaleConnectivityTests
