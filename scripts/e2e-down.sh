#!/usr/bin/env bash
# Tear down local headscale and drop the persisted volume.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker compose -f "$REPO_ROOT/e2e/docker-compose.yml" down -v
