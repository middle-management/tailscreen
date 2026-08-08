#!/usr/bin/env bash
#
# Gate for scripts/release-version.sh.
#
# This logic used to live inline in release.yml, where the only way to find out
# what it produced was to publish a release. The bug it shipped — a candidate
# and its release deriving the SAME MSIX Identity Version, so Windows refuses
# the release as an upgrade — was invisible until somebody installed both.
#
# The rules worth failing on, all of them orderings rather than syntax:
#   • a release and its candidates never share an identity
#   • candidates of one version order upward: rc.1 < rc.2 < rc.10
#   • a release always outranks the previous version
#   • a non-version tag never fails the build on version syntax
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-version.sh"
fails=0
checks=0

# Read one key out of the script's output.
field() { "$script" "$1" | sed -n "s/^$2=//p"; }

expect() { # <tag> <key> <want>
  local got
  checks=$((checks + 1))
  got="$(field "$1" "$2")"
  if [ "$got" != "$3" ]; then
    echo "FAIL  $1 → $2=$got, want $3"
    fails=$((fails + 1))
  fi
}

# MSIX compares field by field as integers, not as a string: 0.10.0.2 sorts
# above 0.10.0.10 lexically and below it numerically, and Windows uses the
# latter. Compare the way Windows does or the ordering assertions are theatre.
version_gt() { # <a> <b> → true when a > b
  local a b i x y
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2 3; do
    x=$((10#${a[i]:-0})); y=$((10#${b[i]:-0}))
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 1
}

ordered() { # <higher-tag> <lower-tag>
  local hi lo
  checks=$((checks + 1))
  hi="$(field "$1" msix_version)"
  lo="$(field "$2" msix_version)"
  if ! version_gt "$hi" "$lo"; then
    echo "FAIL  $1 ($hi) should outrank $2 ($lo)"
    fails=$((fails + 1))
  fi
}

same_identity() { # <tag-a> <tag-b>
  checks=$((checks + 1))
  if [ "$(field "$1" msix_identity)" != "$(field "$2" msix_identity)" ]; then
    echo "FAIL  $1 and $2 should share an identity"
    fails=$((fails + 1))
  fi
}

differing_identity() { # <tag-a> <tag-b>
  checks=$((checks + 1))
  if [ "$(field "$1" msix_identity)" = "$(field "$2" msix_identity)" ]; then
    echo "FAIL  $1 and $2 must NOT share an identity ($(field "$1" msix_identity))"
    fails=$((fails + 1))
  fi
}

# --- a stable release --------------------------------------------------------
expect v0.10.0 prerelease    false
expect v0.10.0 msix_identity Tailscreen.Tailscreen
expect v0.10.0 msix_version  0.10.0.0
expect v0.10.0 version       0.10.0

# The stable identity MUST keep its trailing zero: make-msix.ps1 enforces it
# there, because that is the package a Store submission would ever carry.
checks=$((checks + 1))
case "$(field v1.2.3 msix_version)" in
  *.0) ;;
  *) echo "FAIL  a stable release must end in .0, got $(field v1.2.3 msix_version)"; fails=$((fails + 1)) ;;
esac

# --- candidates --------------------------------------------------------------
expect v0.10.0-rc.1  prerelease    true
expect v0.10.0-rc.1  msix_identity Tailscreen.TailscreenRC
expect v0.10.0-rc.1  msix_version  0.10.0.1
expect v0.10.0-rc.2  msix_version  0.10.0.2
expect v0.10.0-rc.10 msix_version  0.10.0.10
expect v0.10.0-rc2   msix_version  0.10.0.2    # undotted spelling
expect v1.0.0-beta.3 msix_version  1.0.0.3     # any suffix, not just rc
expect v1.0.0-rc     msix_version  1.0.0.1     # unnumbered → 1, never 0

# --- the orderings that are the whole point ----------------------------------
# The bug this replaces: v0.10.0-rc.1 and v0.10.0 both derived 0.10.0.0.
differing_identity v0.10.0-rc.1 v0.10.0
same_identity      v0.10.0-rc.1 v0.10.0-rc.2
same_identity      v0.10.0      v0.10.1

# Candidates order upward within their own identity, so rc.1 → rc.2 is a real
# in-place upgrade and still exercises the Windows upgrade path.
ordered v0.10.0-rc.2  v0.10.0-rc.1
ordered v0.10.0-rc.10 v0.10.0-rc.2

# A release still outranks the previous release on the stable identity.
ordered v0.10.0 v0.9.1
ordered v0.10.1 v0.10.0
ordered v0.10.0 v0.2.0

# --- tags that are not versions ---------------------------------------------
# A packaging rehearsal must not die on version syntax, and must not land on
# the identity a real install uses. The PR number falling out as the revision
# is deliberate rather than incidental: two PR builds then differ, so installing
# one over another behaves like an upgrade instead of a same-version refusal.
expect pr-1234 msix_version  0.0.1.1234
expect pr-1234 msix_identity Tailscreen.TailscreenRC
ordered pr-1234 pr-99
# ...and any real version outranks every PR build, so a candidate installs over
# a rehearsal rather than being refused as a downgrade.
ordered v0.10.0-rc.1 pr-1234
expect v1.2    msix_version  1.2.0.0
expect v1.2    msix_identity Tailscreen.Tailscreen

# --- clamp -------------------------------------------------------------------
# Each field is a 16-bit unsigned integer; MakeAppx rejects anything wider.
expect v1.0.0-rc.70000 msix_version 1.0.0.65535

echo
if [ "$fails" -ne 0 ]; then
  echo "release-version: $fails/$checks checks FAILED"
  exit 1
fi
echo "release-version: $checks checks passed"
