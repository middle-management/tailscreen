#!/usr/bin/env bash
# Apply the self-contained Windows App SDK patch to the resolved swift-winui
# checkout (swift-winui-selfcontained.patch, same directory).
#
# Why a checkout patch and not a fork: the decision is recorded in
# plans/viewer-windows-plan.md (W9d). The checkout's content is deterministic —
# Apps/windows/Package.resolved pins swift-winui by revision (df7642f via
# swift-cross-ui's requirement), so this is the same patch-a-pinned-tree
# discipline TailscaleKit already uses, minus the submodule. The patch is
# behaviour-neutral when no runtime payload is staged beside the exe, so an
# unpatched local dev build and a patched one act identically outside the
# self-contained layout.
#
# Idempotent: a second run is a no-op (marker check). Drift is a hard failure,
# never a silent skip — if SwiftPM resolves a different swift-winui and the
# hunks stop applying, this exits non-zero and CI goes red, which is the point:
# the patch must be re-derived against the new pin, not quietly dropped.
#
# SwiftPM can re-extract checkouts after cache restores or resolution changes,
# which is why CI runs this AFTER `swift package resolve` (or the first build's
# implicit resolve) and BEFORE the build that must carry the patch.
set -euo pipefail

checkout="${1:-Apps/windows/.build/checkouts/swift-winui}"
target="$checkout/Sources/WinAppSDK/Initialize.swift"
patch_file="$(cd "$(dirname "$0")" && pwd)/swift-winui-selfcontained.patch"

if [ ! -f "$target" ]; then
  echo "no swift-winui checkout at $checkout — run swift package resolve first" >&2
  exit 1
fi

if grep -q 'tailscreen-selfcontained' "$target"; then
  echo "swift-winui already patched (marker present) — nothing to do"
  exit 0
fi

# git apply: present on every runner and CRLF-exact, unlike GNU patch which is
# not guaranteed in Git Bash. --directory applies the a/... paths inside the
# checkout; the checkout lives under .build (gitignored), which git apply does
# not care about since it edits the working tree only.
git apply --verbose --directory="$checkout" "$patch_file"

if ! grep -q 'tailscreen-selfcontained' "$target"; then
  echo "git apply reported success but the marker is missing — refusing to continue" >&2
  exit 1
fi
echo "swift-winui patched for self-contained Windows App SDK"
