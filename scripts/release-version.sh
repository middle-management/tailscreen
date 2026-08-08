#!/usr/bin/env bash
#
# Derive every release identifier from one tag, in one place.
#
# Prints `key=value` lines for: tag, version, prerelease, msix_identity,
# msix_version. release.yml appends them straight to $GITHUB_OUTPUT; the test
# script reads them the same way, which is the point of this being a file
# rather than twenty lines inside a workflow step.
#
#   $ scripts/release-version.sh v0.10.0
#   tag=v0.10.0
#   version=0.10.0
#   prerelease=false
#   msix_identity=Tailscreen.Tailscreen
#   msix_version=0.10.0.0
#
#   $ scripts/release-version.sh v0.10.0-rc.2
#   tag=v0.10.0-rc.2
#   version=0.10.0-rc.2
#   prerelease=true
#   msix_identity=Tailscreen.TailscreenRC
#   msix_version=0.10.0.2
#
# WHY A PRE-RELEASE GETS A DIFFERENT IDENTITY, NOT JUST A DIFFERENT VERSION
#
# MSIX has no pre-release concept, so the suffix has to go somewhere. It cannot
# go in the version: Windows keys upgrades on Identity Version, the fields are
# unsigned, and a stable release ends in `.0` — so every candidate for X.Y.Z is
# necessarily >= the release it precedes. Numbering candidates `.1`, `.2`, …
# does not fix that, it inverts it: the release then sorts BELOW its own
# candidates and Windows refuses it as a downgrade. (Exactly the shape of the
# tag-sort bug in pages.yml, one field to the right.)
#
# So the candidate gets its own Package Identity Name. Two identities have no
# upgrade relationship at all, which makes the collision impossible by
# construction rather than by arithmetic somebody has to keep straight, and
# lets a tester hold the release and the candidate side by side.
#
# The fourth field is then free INSIDE the candidate identity, where it orders
# rc.1 → rc.2 → rc.3. That is not a consolation prize: it means installing one
# candidate over another still exercises the real Windows upgrade path, so the
# thing a separate identity appears to cost is still covered. Windows reserves
# the fourth field for the Store, and make-msix.ps1 still enforces `.0` for the
# stable identity for that reason — a candidate is never Store-submitted, so
# the reservation does not bind it.
#
# PR BUILDS use the candidate identity too. A packaging rehearsal is not a
# release, and an artifact somebody sideloads to try a branch must not land on
# the identity their real install uses.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: ${0##*/} <tag>" >&2
  exit 2
fi

tag="$1"
version="${tag#v}"

# Identity names. The stable one is also the winget PackageIdentifier and is
# matched by verify-msix.ps1, so it is not free to change.
readonly IDENTITY_STABLE='Tailscreen.Tailscreen'
readonly IDENTITY_PRERELEASE='Tailscreen.TailscreenRC'

# SemVer: a hyphen after the version IS the pre-release marker. Same rule as
# pages.yml's tag filter, deliberately — one definition of "pre-release" across
# the repo beats two that agree until they don't.
if [[ "$version" == *-* ]]; then
  prerelease=true
else
  prerelease=false
fi

# A tag that is not a version at all (`pr-1234`, a name someone typed) must not
# fail the build on version syntax — packaging is the thing under test there,
# not the label. Fall back to 0.0.1.0 and treat it as a pre-release.
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+ ]]; then
  prerelease=true
fi

if [ "$prerelease" = true ]; then
  msix_identity="$IDENTITY_PRERELEASE"
else
  msix_identity="$IDENTITY_STABLE"
fi

# The candidate number, from the trailing digits of the suffix: -rc.2, -rc2 and
# -beta.2 all yield 2. An unnumbered suffix (-rc, -dev) yields 1 rather than 0,
# so that a second unnumbered build is at least distinguishable from no build.
revision=0
if [ "$prerelease" = true ]; then
  suffix="${version#*-}"
  if [[ "$suffix" =~ ([0-9]+)$ ]]; then
    revision="${BASH_REMATCH[1]}"
  else
    revision=1
  fi
  # Each MSIX version field is a 16-bit unsigned integer. Clamp rather than
  # emit something MakeAppx rejects at the end of a 25-minute build.
  if [ "$revision" -gt 65535 ]; then revision=65535; fi
fi

if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  msix_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${revision}"
elif [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
  msix_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.0.${revision}"
else
  msix_version="0.0.1.${revision}"
fi

echo "tag=$tag"
echo "version=$version"
echo "prerelease=$prerelease"
echo "msix_identity=$msix_identity"
echo "msix_version=$msix_version"
