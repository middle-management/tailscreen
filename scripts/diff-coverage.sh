#!/usr/bin/env bash
# diff-coverage.sh — coverage gate on CHANGED lines only.
#
# Joins the lcov `DA:` records (executable-line hit counts) against the line
# ranges this branch changed in the Swift trees listed in PATHSPECS below, and
# fails when the covered fraction of changed executable lines falls below the
# threshold. Lines that lcov has no DA: record for (comments, declarations,
# blank) don't count against the gate.
#
# Usage: diff-coverage.sh <lcov-file> [base-ref] [threshold-pct]
#   lcov-file      lcov export (e.g. `xcrun llvm-cov export -format=lcov …`)
#   base-ref       diff base (default origin/main); requires a full-history
#                  checkout (fetch-depth: 0 on CI)
#   threshold-pct  minimum covered % of changed executable lines (default 70)
#
# KNOWN SILENT-PASS PATHS (fine while the gate is warn-only; MUST become hard
# failures when the CI step's flip-to-required TODO lands):
#   1. `git diff … 2>/dev/null` below swallows errors (e.g. an unknown
#      base-ref on a shallow checkout) and reads as "no changed lines" →
#      exit 0. Required-mode should drop the 2>/dev/null and fail on git
#      errors instead.
#   2. The CI step exits 0 with a ::warning when the profdata/xctest bundle
#      can't be located — a coverage-collection regression would silently
#      disable the gate. Required-mode should fail there too.
set -euo pipefail

LCOV_FILE="${1:?usage: diff-coverage.sh <lcov-file> [base-ref] [threshold-pct]}"
BASE_REF="${2:-origin/main}"
THRESHOLD="${3:-70}"

if [ ! -f "$LCOV_FILE" ]; then
    echo "diff-coverage: lcov file not found: $LCOV_FILE" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Anchor at the repo root so the invoker's cwd (CI runs this from
# Apps/macOS) doesn't change what the git pathspec below matches.
LCOV_FILE="$(cd "$(dirname "$LCOV_FILE")" && pwd)/$(basename "$LCOV_FILE")"
cd "$REPO_ROOT"

# Which trees the gate can see. Everything outside this list is invisible to
# it: until 2026-08 the list was the single pathspec `Apps/macOS/Sources/*.swift`,
# so a PR that only touched Packages/ — where most of the testable code now
# lives — passed the gate by not being looked at.
#
# Widening is safe in a way that is worth stating, because it is the whole
# reason no per-tree opt-out list is needed: a changed line is only ever
# counted when lcov has a DA: record for it (step 3's `if (key in hits)`).
# Files the macOS coverage run does not compile — the two swift-cross-ui apps,
# the Windows and Linux backend packages — have no records at all, so they add
# nothing to either side of the ratio rather than counting as uncovered. What
# the widening actually turns on is the trees that ARE compiled into the macOS
# test binary and were being graded by nobody: TailscreenKit, TailscreenL10n
# and friends.
#
# Two exclusions that are NOT automatic:
#   • *.swift only, so every package's C/C++/ObjC shim (Sources/C*/*.c, *.h) is
#     out by construction — llvm-cov does emit records for C, and a shim is
#     driven from the platform's own leg rather than from a macOS unit test.
#   • Packages/TailscaleKit/Sources is a symlink tree into the libtailscale
#     submodule: upstream code, upstream's tests, not ours to cover.
# Test sources stay out too (Apps/*/Tests, Packages/*/Tests): llvm-cov happily
# reports coverage OF the test bundle, and gating "did your new test run?" is
# noise. CI's llvm-cov export already passes -ignore-filename-regex='Tests/'.
#
# NOTE the gate is currently advisory (`continue-on-error: true` on the CI
# step). When it flips to required, revisit this list first — a tree with no
# coverage records today is only invisible; the day a Linux coverage leg
# appears it starts counting.
PATHSPECS=(
    'Apps/macOS/Sources/*.swift'
    'Apps/linux/Sources/*.swift'
    'Apps/windows/Sources/*.swift'
    'Packages/*/Sources/*.swift'
    ':(exclude)Packages/TailscaleKit/Sources/*'
)

# 1. Changed line ranges: "<file>\t<line>" per added/modified line under
#    PATHSPECS. -U0 keeps hunks tight; the @@ header's +start,count names the
#    new-file line range.
CHANGED_LINES="$(
    git diff -U0 --no-color "${BASE_REF}...HEAD" -- "${PATHSPECS[@]}" 2>/dev/null |
        awk '
            /^\+\+\+ b\// { file = substr($2, 3); next }
            /^@@/ {
                # @@ -a,b +c,d @@ — take the +c,d side.
                plus = $3
                sub(/^\+/, "", plus)
                split(plus, parts, ",")
                start = parts[1] + 0
                count = (parts[2] == "" ? 1 : parts[2] + 0)
                for (i = 0; i < count; i++) print file "\t" (start + i)
            }
        '
)"

if [ -z "$CHANGED_LINES" ]; then
    echo "diff-coverage: no changed Swift source lines vs ${BASE_REF} — nothing to gate."
    exit 0
fi

# 2. lcov DA: records → "<repo-relative-file>\t<line>\t<hits>". SF: paths in
#    llvm-cov exports are absolute; strip the repo root.
COVERAGE_RECORDS="$(
    awk -v root="${REPO_ROOT}/" '
        /^SF:/ {
            file = substr($0, 4)
            if (index(file, root) == 1) file = substr(file, length(root) + 1)
            next
        }
        /^DA:/ {
            split(substr($0, 4), parts, ",")
            print file "\t" parts[1] "\t" parts[2]
        }
    ' "$LCOV_FILE"
)"

# 3. Join: for each changed line that HAS a DA record (i.e. is executable),
#    tally covered vs uncovered.
RESULT="$(
    {
        echo "$COVERAGE_RECORDS" | awk '{ print "DA\t" $0 }'
        echo "$CHANGED_LINES" | awk '{ print "CH\t" $0 }'
    } | awk -F '\t' '
        $1 == "DA" { hits[$2 "\t" $3] = $4; next }
        $1 == "CH" {
            key = $2 "\t" $3
            if (key in hits) {
                total++
                if (hits[key] + 0 > 0) covered++
                else uncovered = uncovered $2 ":" $3 "\n"
            }
        }
        END {
            printf "%d %d\n", covered + 0, total + 0
            printf "%s", uncovered
        }
    '
)"

read -r COVERED TOTAL <<< "$(echo "$RESULT" | head -n1)"
UNCOVERED_LIST="$(echo "$RESULT" | tail -n +2)"

if [ "$TOTAL" -eq 0 ]; then
    echo "diff-coverage: changed lines contain no executable code (per lcov) — nothing to gate."
    exit 0
fi

PCT=$((COVERED * 100 / TOTAL))
echo "diff-coverage: ${COVERED}/${TOTAL} changed executable lines covered (${PCT}%, threshold ${THRESHOLD}%)."

if [ "$PCT" -lt "$THRESHOLD" ]; then
    echo ""
    echo "Uncovered changed lines:"
    echo "$UNCOVERED_LIST"
    echo "diff-coverage: FAIL — below ${THRESHOLD}% on changed lines." >&2
    exit 1
fi

echo "diff-coverage: OK."
