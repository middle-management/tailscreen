#!/usr/bin/env python3
"""Normalize a SwiftLint baseline into the form this repo commits.

`swiftlint lint --write-baseline` emits a baseline that is unusable as a
committed artifact in two separate ways, and both used to be fixed by hand
(from a scratch directory, by whoever last refreshed it):

  1. It is ONE LINE. 56 KB of it. Every refresh — even one that moves a single
     violation down by a line — is a one-line diff no reviewer can read, so the
     refresh lands unreviewed and a real regression rides along unnoticed.

  2. It records ABSOLUTE paths (`file:///home/you/checkout/Apps/...`). SwiftLint
     matches a baseline entry against a fresh violation via the path RELATIVE
     to the current directory, so an absolute path recorded on one machine
     matches nothing on any other — the baseline silently stops suppressing on
     CI, and every frozen violation comes back as new.

So: rewrite absolute paths to repo-relative, sort, and pretty-print. Formatting
and ordering are invisible to SwiftLint (it decodes the file as JSON and keys it
by file), so none of this can change WHICH violations are frozen.

Usage: normalize-lint-baseline.py <input.json> <output.json> [repo-root]
       repo-root defaults to the current directory.
"""

import json
import os
import sys


def relativize(path: str, root: str) -> str:
    """Strip the repo root (in either the `file://` URL or bare form)."""
    for prefix in (f"file://{root}/", f"{root}/"):
        if path.startswith(prefix):
            return path[len(prefix):]
    return path


def sort_key(entry: dict) -> tuple:
    location = entry["violation"]["location"]
    return (
        location.get("file") or "",
        location.get("line") or 0,
        location.get("character") or 0,
        entry["violation"].get("ruleIdentifier") or "",
        entry.get("text") or "",
    )


def main(argv: list) -> int:
    if not 3 <= len(argv) <= 4:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = argv[1], argv[2]
    root = os.path.realpath(argv[3] if len(argv) == 4 else os.getcwd())

    with open(src, encoding="utf-8") as handle:
        entries = json.load(handle)

    if not isinstance(entries, list) or not entries:
        print(f"normalize-lint-baseline: {src} is not a non-empty JSON array", file=sys.stderr)
        return 1

    for entry in entries:
        location = entry["violation"]["location"]
        location["file"] = relativize(location["file"], root)

    # An absolute path that survives is a baseline that will not suppress
    # anything on any other machine — fail loudly rather than commit it.
    stragglers = [
        e["violation"]["location"]["file"]
        for e in entries
        if e["violation"]["location"]["file"].startswith(("/", "file://"))
    ]
    if stragglers:
        print(
            "normalize-lint-baseline: absolute paths survived (wrong repo root?):\n  "
            + "\n  ".join(sorted(set(stragglers))[:5]),
            file=sys.stderr,
        )
        return 1

    entries.sort(key=sort_key)

    with open(dst, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(entries, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")

    print(f"normalize-lint-baseline: {len(entries)} entries → {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
