#!/usr/bin/env bash
# Replace git symlinks with real copies.
#
# Windows checkouts don't reliably give you usable symlinks. Without
# core.symlinks, git writes each one as a plain text file containing the target
# path. WITH core.symlinks, git may still produce a link that Windows and
# SwiftPM won't traverse — a symlink to a directory has to be created as a
# directory symlink, and a file-flavoured one silently fails to resolve.
#
# Either way SwiftPM fails at manifest-load time with
#
#   error: 'tailscalekit': invalid custom path 'Sources/TailscaleKit'
#
# which aborts the WHOLE package graph, including targets that don't depend on
# TailscaleKit at all.
#
# Usage:
#   materialize-symlinks.sh           # fix only entries that aren't links
#   materialize-symlinks.sh --force   # replace every tracked symlink with a copy
#
# --force is what Windows CI uses. Deciding "is this link usable?" from a shell
# is exactly the guess that already failed once — a checkout can look like it
# has symlinks while SwiftPM disagrees — so on Windows we don't ask, we copy.
#
# Link targets are read from git's object store rather than the working tree,
# so this behaves identically whether the entry arrived as a link or as text.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

force=0
if [ "${1:-}" = "--force" ]; then
  force=1
fi

changed=0
while read -r path; do
  [ -n "$path" ] || continue

  if [ "$force" -eq 0 ] && [ -L "$path" ]; then
    continue
  fi

  # The stored link text, independent of how git materialised it on disk.
  target="$(git cat-file blob "HEAD:$path")"
  resolved="$(dirname "$path")/$target"

  # lib/libtailscale.a points at a BUILD ARTIFACT that doesn't exist on a fresh
  # checkout. That's expected — the Makefile produces it later, and anything
  # created here would be in its way.
  if [ ! -e "$resolved" ]; then
    echo "  -- $path -> $target (target absent; leaving as-is)"
    continue
  fi

  echo "  => $path -> $target"
  rm -rf "$path"
  cp -R "$resolved" "$path"
  changed=$((changed + 1))
done < <(git ls-files -s | awk '$1=="120000"{ $1=""; $2=""; $3=""; sub(/^ +/, ""); print }')

echo "materialized $changed symlink(s)"

# Assert the outcome rather than trusting it. The whole reason this script
# exists is that the previous check reported success while SwiftPM still
# couldn't find the sources.
if [ ! -d Packages/TailscaleKit/Sources/TailscaleKit ]; then
  echo "FAILED: Packages/TailscaleKit/Sources/TailscaleKit is not a usable directory" >&2
  exit 1
fi
if [ ! -f Packages/TailscaleKit/Sources/TailscaleKit/TailscaleNode.swift ]; then
  echo "FAILED: TailscaleKit sources are missing after materialization" >&2
  exit 1
fi
echo "verified: Packages/TailscaleKit/Sources/TailscaleKit is readable"
