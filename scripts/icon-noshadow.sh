#!/usr/bin/env bash
# icon-noshadow.sh — emit the app icon SVG with the macOS drop shadow removed.
#
# docs/assets/app-icon.svg carries the drop shadow Apple's icon template bakes
# into the artwork. That is a macOS convention: Windows Start tiles and Linux
# hicolor icons are flat, and a Mac shadow in them reads as a rendering
# mistake rather than a style. Every non-Apple consumer of the SVG therefore
# renders through this filter:
#
#     scripts/icon-noshadow.sh docs/assets/app-icon.svg | rsvg-convert ...
#
# Writes to stdout. Fails loudly if the filter reference is not found, because
# the failure mode we care about is a silent no-op quietly shipping the shadow
# everywhere after someone renames the filter.
set -euo pipefail

SRC="${1:?usage: icon-noshadow.sh <app-icon.svg>}"
MARKER=' filter="url(#tileShadow)"'

if ! grep -qF "$MARKER" "$SRC"; then
  echo "icon-noshadow.sh: no ${MARKER# } in $SRC" >&2
  echo "  The macOS shadow filter was renamed or removed. If the icon no longer" >&2
  echo "  has a baked shadow, drop this script and render $SRC directly;" >&2
  echo "  otherwise update MARKER to match." >&2
  exit 1
fi

sed "s|${MARKER}||" "$SRC"
