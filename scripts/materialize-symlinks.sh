#!/usr/bin/env bash
# Replace git symlinks with real copies.
#
# Windows checkouts don't get symlinks unless core.symlinks is on AND the
# account may create them (Developer Mode or admin). Without that, git writes
# each symlink as a plain text file whose contents are the target path, and
# SwiftPM then fails at manifest-load time with
#
#   error: 'tailscalekit': invalid custom path 'Sources/TailscaleKit'
#
# which aborts the WHOLE package graph — including targets that don't depend on
# TailscaleKit at all.
#
# Enabling core.symlinks is the better fix when it works, so CI tries that
# first; this script is the fallback that always works. It's a no-op on a
# checkout where the symlinks are real, so it's safe to run unconditionally.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

changed=0
while read -r path; do
  [ -n "$path" ] || continue
  # A real symlink needs nothing doing.
  if [ -L "$path" ]; then
    continue
  fi
  if [ ! -f "$path" ]; then
    echo "  ?? $path is neither a symlink nor a file; skipping" >&2
    continue
  fi

  target="$(cat "$path")"
  resolved="$(dirname "$path")/$target"

  # lib/libtailscale.a points at a BUILD ARTIFACT that doesn't exist on a fresh
  # checkout. That's expected: the Makefile produces it later, and by then the
  # path this script would have created is in the way. Leave it alone.
  if [ ! -e "$resolved" ]; then
    echo "  -- $path -> $target (target absent; leaving as-is)"
    continue
  fi

  echo "  => $path -> $target"
  rm -f "$path"
  cp -R "$resolved" "$path"
  changed=$((changed + 1))
done < <(git ls-files -s | awk '$1=="120000"{ $1=""; $2=""; $3=""; sub(/^ +/, ""); print }')

echo "materialized $changed symlink(s)"
