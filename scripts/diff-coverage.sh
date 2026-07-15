#!/usr/bin/env bash
# diff-coverage.sh — coverage gate on CHANGED lines only.
#
# Joins the lcov `DA:` records (executable-line hit counts) against the line
# ranges this branch changed in Sources/*.swift, and fails when the covered
# fraction of changed executable lines falls below the threshold. Lines that
# lcov has no DA: record for (comments, declarations, blank) don't count
# against the gate.
#
# Usage: diff-coverage.sh <lcov-file> [base-ref] [threshold-pct]
#   lcov-file      lcov export (e.g. `xcrun llvm-cov export -format=lcov …`)
#   base-ref       diff base (default origin/main); requires a full-history
#                  checkout (fetch-depth: 0 on CI)
#   threshold-pct  minimum covered % of changed executable lines (default 70)
set -euo pipefail

LCOV_FILE="${1:?usage: diff-coverage.sh <lcov-file> [base-ref] [threshold-pct]}"
BASE_REF="${2:-origin/main}"
THRESHOLD="${3:-70}"

if [ ! -f "$LCOV_FILE" ]; then
    echo "diff-coverage: lcov file not found: $LCOV_FILE" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"

# 1. Changed line ranges: "<file>\t<line>" per added/modified line in
#    Sources/*.swift. -U0 keeps hunks tight; the @@ header's +start,count
#    names the new-file line range.
CHANGED_LINES="$(
    git diff -U0 --no-color "${BASE_REF}...HEAD" -- 'Sources/*.swift' 2>/dev/null |
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
    echo "diff-coverage: no changed Sources/*.swift lines vs ${BASE_REF} — nothing to gate."
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
