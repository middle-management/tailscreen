#!/usr/bin/env python3
"""Ask the compiler which closures carry a dynamic executor precondition.

`scripts/check-callback-isolation.py` looks for the SHAPE of the bug in
source, against a list of framework callbacks we happen to know about. This
looks for the bug itself.

Under Swift 6, a closure that inherits actor isolation and can be reached from
code the compiler cannot check — every imported ObjC block — gets a dynamic
executor precondition planted at its entry (SE-0423). That precondition is
invisible in diagnostics (the broken form and the fixed form both compile
silently) but it is right there in SIL, as a call to
`swift_task_isCurrentExecutor`. So: build with `-Xswiftc -emit-sil`, which
prints SIL to stdout while still emitting objects and modules, and report every
function in it that carries one.

Exact where the source scan is heuristic: no API list, no regex over call
shapes, no guessing at the enclosing type's isolation — and it names the
closure. What it cannot do is tell a precondition that will fire from one that
never will: `assumeIsolated`, `MainActor.assertIsolated`, and any callback the
framework genuinely does invoke on the right actor all look identical here.
That is what the baseline is for. New entries fail; the diff is the review.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

MARKER = "swift_task_isCurrentExecutor"
# `$ss…` is the Swift standard library's mangling prefix. Everything there is
# the MECHANISM of the check — `_checkExpectedExecutor` above all, which every
# precondition calls — never an instance of the bug, and it appears in every
# module that has one.
STDLIB_PREFIX = "$ss"


def symbols_with_preconditions(text):
    """Every SIL function whose body calls the executor check, in file order."""
    found, current, hit = [], None, False
    for line in text.split("\n"):
        start = re.match(r"^sil\b.*?(@\$s[A-Za-z0-9_$]+)\s*:", line)
        if start:
            current, hit = start.group(1)[1:], False
            continue
        if current and MARKER in line:
            hit = True
            continue
        end = re.match(r"^\} // end sil function '(.+)'", line)
        if end:
            if hit:
                found.append(end.group(1))
            current, hit = None, False
    return found


def readable(symbols):
    """Demangled names for display, keyed by symbol. Cosmetic on purpose.

    The BASELINE keys on the mangled symbol, which is stable and needs no
    toolchain; a demangled name would make the file depend on which Swift
    happens to be on PATH. So a machine with no `swift` still checks
    correctly, it just prints uglier.
    """
    if not symbols:
        return {}
    try:
        proc = subprocess.run(["swift", "demangle", "--compact"] + symbols,
                              capture_output=True, text=True)
    except (FileNotFoundError, OSError):
        return {}
    if proc.returncode != 0:
        return {}
    out = [line.strip() for line in proc.stdout.split("\n") if line.strip()]
    return dict(zip(symbols, out)) if len(out) == len(symbols) else {}


def interesting(symbols):
    seen, out = set(), []
    for sym in symbols:
        if sym.startswith(STDLIB_PREFIX) or sym in seen:
            continue
        seen.add(sym)
        out.append(sym)
    return sorted(out)


def read_baseline(path):
    if not path.exists():
        return None
    return sorted(
        line.strip() for line in path.read_text().split("\n")
        if line.strip() and not line.startswith("#")
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sil", nargs="?", help="SIL file; omit or '-' for stdin")
    ap.add_argument("--baseline", type=Path, help="expected set, one name per line")
    ap.add_argument("--update", action="store_true", help="rewrite the baseline")
    ap.add_argument("--report", action="store_true",
                    help="print the set and exit 0, whatever the baseline says")
    args = ap.parse_args()

    text = (sys.stdin.read() if args.sil in (None, "-")
            else Path(args.sil).read_text())
    if "end sil function" not in text:
        print("error: no SIL here. Build with `-Xswiftc -emit-sil` and pass "
              "its stdout.", file=sys.stderr)
        return 2

    names = interesting(symbols_with_preconditions(text))
    pretty = readable(names)

    def show(sym):
        return "%s\n      %s" % (pretty.get(sym, sym), sym) if sym in pretty else sym

    if args.update:
        if not args.baseline:
            print("error: --update needs --baseline", file=sys.stderr)
            return 2
        args.baseline.write_text(
            "# Functions carrying an SE-0423 dynamic executor precondition.\n"
            "# Written by `make sil-isolation-baseline`. Every line is a place\n"
            "# the compiler decided it could not prove the caller's isolation\n"
            "# statically. A NEW line is not automatically a bug — but it is\n"
            "# always a question, and the answer belongs in the PR that adds\n"
            "# it. See .claude/rules/macos-app.md.\n"
            + "".join(
                ("# %s\n%s\n" % (pretty[n], n)) if n in pretty else (n + "\n")
                for n in names))
        print("wrote %s (%d entries)" % (args.baseline, len(names)))
        return 0

    if args.report or not args.baseline:
        for name in names:
            print("  " + show(name))
        print("-- %d function(s) carrying a dynamic executor precondition" % len(names))
        return 0

    baseline = read_baseline(args.baseline)
    if baseline is None:
        print("error: no baseline at %s — run `make sil-isolation-baseline`"
              % args.baseline, file=sys.stderr)
        return 2

    added = [n for n in names if n not in baseline]
    removed = [n for n in baseline if n not in names]
    for name in added:
        print("error: a dynamic executor precondition the baseline does not "
              "have:\n"
              "    %s\n"
              "    %s\n"
              "    The compiler could not prove this closure's caller runs on "
              "its actor, so it planted a\n"
              "    runtime check. If a framework calls it off that actor, the "
              "process traps: SIGTRAP."
              % (pretty.get(name, name), name))
    if added:
        print("\n%d new precondition(s). Either make the closure non-isolated "
              "(bind an explicitly `@Sendable` local, or move it into a "
              "`nonisolated` helper), or — if this one is genuinely called on "
              "its own actor — add it with `make sil-isolation-baseline` and "
              "say why in the PR." % len(added))
    if removed:
        print("\nnote: %d baseline entry/entries no longer present. Refresh "
              "with `make sil-isolation-baseline`:" % len(removed))
        for name in removed:
            print("  - " + name)
    return 1 if added else 0


if __name__ == "__main__":
    sys.exit(main())
