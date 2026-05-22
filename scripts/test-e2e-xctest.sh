#!/usr/bin/env bash
# Local screen-share E2E (XCTest). Brings up local headscale and runs the
# XCTest suites that exercise the share pipeline beyond what unit tests
# cover — synthetic frames over real tsnet, real capture-helper subprocess,
# picker-helper subprocess smoke, multi-viewer fan-out + audio relay,
# annotation + PLI control paths, and request-to-share.
#
# The synthetic/fan-out/control/request suites are CI-eligible (they only
# need headscale + working VideoToolbox); the capture-helper and picker tests
# self-skip on GITHUB_ACTIONS / CI runners. Set TAILSCREEN_ALLOW_CAPTURE_TEST=1
# to force the capture-helper test locally even if those env vars are set.

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
TAILSCREEN_ALLOW_CAPTURE_TEST="${TAILSCREEN_ALLOW_CAPTURE_TEST:-1}" \
    swift test \
        --filter ScreenShareSyntheticFramesTests \
        --filter ScreenShareCaptureHelperTests \
        --filter ScreenShareFanoutTests \
        --filter ScreenShareControlChannelTests \
        --filter ScreenShareRequestToShareTests \
        --filter PickerHelperSmokeTests
