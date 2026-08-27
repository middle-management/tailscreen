#!/usr/bin/env bash
# Convert Packages/TailscaleKit/Patches/*.patch into commits on a branch of a
# libtailscale fork — Phase 0 of plans/share-by-token.md.
#
# Produces (in a work directory) a full-history clone of
# github.com/tailscale/libtailscale with a branch $BRANCH based on the
# submodule's pinned commit, carrying one commit per patch file, applied with
# exactly the Makefile's semantics (`patch -p1 -N -F0` from a root where the
# tree sits at upstream/libtailscale/). It then verifies the result is
# byte-identical to what `make apply-patches` produces today, and prints the
# push command.
#
# It does NOT push and does NOT touch the tailscreen tree (the submodule is
# used read-only as the pin reference). Idempotent: delete $WORK and re-run.
#
# Usage:
#   scripts/fork-libtailscale.sh [WORK_DIR]
#   FORK_URL=git@github.com:middle-management/libtailscale.git \
#     scripts/fork-libtailscale.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES_DIR="$REPO_ROOT/Packages/TailscaleKit/Patches"
SUBMODULE="$REPO_ROOT/Packages/TailscaleKit/upstream/libtailscale"
UPSTREAM_URL="https://github.com/tailscale/libtailscale"
FORK_URL="${FORK_URL:-https://github.com/middle-management/libtailscale}"
BRANCH="${BRANCH:-tailscreen-main}"
# The clone lives at <workroot>/upstream/libtailscale — a REAL directory at
# the prefix the patch paths carry, because GNU patch refuses to write
# through symlinks (directory-traversal hardening), so the tempting
# symlinked-root trick fails with "can't find file to patch".
WORKROOT="${1:-$(mktemp -d)}"
WORK="$WORKROOT/upstream/libtailscale"

# The commit the tailscreen submodule pins — the branch base, so the
# submodule pointer moves by exactly "our commits on top of what we ship".
PIN="$(git -C "$REPO_ROOT" ls-tree HEAD Packages/TailscaleKit/upstream/libtailscale | awk '{print $3}')"
[ -n "$PIN" ] || { echo "cannot read submodule pin" >&2; exit 1; }
echo "==> submodule pin: $PIN"

echo "==> cloning $UPSTREAM_URL (full history) to $WORK"
mkdir -p "$WORKROOT/upstream"
git clone "$UPSTREAM_URL" "$WORK"
git -C "$WORK" cat-file -e "$PIN" || { echo "pin not in upstream history" >&2; exit 1; }
git -C "$WORK" checkout -q -b "$BRANCH" "$PIN"

# Replay each patch with the Makefile's exact mechanics: paths inside the
# patches are upstream/libtailscale/..., applied -p1 from the workroot,
# where the clone sits at exactly that prefix.
shopt -s nullglob
PATCHES=("$PATCHES_DIR"/*.patch)
[ ${#PATCHES[@]} -gt 0 ] || { echo "no patches found in $PATCHES_DIR" >&2; exit 1; }

for p in "${PATCHES[@]}"; do
  base="$(basename "$p")"
  echo "==> $base"
  # -F0: a fuzz-fitted hunk is a hard error, same rule as the Makefile.
  (cd "$WORKROOT" && patch -p1 -N -F0 -r - --no-backup-if-mismatch < "$p")
  # Subject: "013 tsnet listen packet go" style, from the filename.
  num="${base%%-*}"
  words="$(echo "${base#*-}" | sed 's/\.patch$//; s/-/ /g')"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "$words

Converted from Packages/TailscaleKit/Patches/$base (patch $num of the
middle-management/tailscreen series). Content byte-identical to the
patch-applied tree; see that repo's plans/share-by-token.md, Phase 0." \
    -m "Co-Authored-By: Claude <noreply@anthropic.com>"
done

echo "==> verifying against make apply-patches"
# Reference tree: the real submodule with patches applied by the Makefile,
# restored to pristine afterwards regardless of prior state.
git -C "$SUBMODULE" stash -q --include-untracked || true
rm -f "$REPO_ROOT/Packages/TailscaleKit/.patches-applied"
make -C "$REPO_ROOT/Packages/TailscaleKit" apply-patches >/dev/null
# Exclude build artifacts a prior `make c-archive` may have left in the
# submodule (the cgo-generated header and the archive are untracked outputs,
# not patch content).
if diff -r --exclude=.git --exclude=libtailscale.a --exclude=libtailscale.h \
    "$SUBMODULE" "$WORK" > /tmp/fork-verify.diff 2>&1; then
  echo "    byte-identical ✅"
else
  echo "❌ trees differ (see /tmp/fork-verify.diff)"; RC=1
fi
git -C "$SUBMODULE" checkout -q -- . && git -C "$SUBMODULE" clean -fdq
rm -f "$REPO_ROOT/Packages/TailscaleKit/.patches-applied"
git -C "$SUBMODULE" stash pop -q 2>/dev/null || true
[ "${RC:-0}" = 0 ] || exit 1

echo "==> build check (go build; go test)"
(cd "$WORK" && go build ./... && go test ./...)

cat <<EOF

Done. ${#PATCHES[@]} commits on '$BRANCH' in $WORK, verified and building.

To publish (fork must exist — GitHub "Fork" of tailscale/libtailscale into
the org, or an empty repo at $FORK_URL):

  git -C "$WORK" remote add fork "$FORK_URL"
  git -C "$WORK" push fork main "$BRANCH"

Then point the submodule at it (Phase 0, next step):
  .gitmodules url -> $FORK_URL, submodule to $BRANCH tip,
  retire the Patches/ machinery in Packages/TailscaleKit/Makefile.
EOF
