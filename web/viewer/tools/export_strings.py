#!/usr/bin/env python3
"""Export the catalog strings the browser viewer uses to dist/strings.json.

The page's user-facing text comes from TailscreenL10n — the ONE catalog all
three apps read — so a string translated once is translated in the browser
too. This pulls exactly the keys viewer.js uses (listed in strings.txt) out of
every <lang>.lproj/Localizable.strings and writes {lang: {key: value}}.
Missing keys fall back to English (which is the key itself) in the page.

    python3 web/viewer/tools/export_strings.py   # run by `make web-viewer`
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
RESOURCES = os.path.join(ROOT, "Packages", "TailscreenL10n", "Sources", "TailscreenL10n", "Resources")
OUT = os.path.join(HERE, "..", "dist", "strings.json")

LINE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def unescape(s: str) -> str:
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def load(path: str) -> dict:
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = LINE.match(line)
            if m:
                out[unescape(m.group(1))] = unescape(m.group(2))
    return out


def main() -> int:
    with open(os.path.join(HERE, "strings.txt"), encoding="utf-8") as f:
        wanted = [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]
    result = {}
    for entry in sorted(os.listdir(RESOURCES)):
        if not entry.endswith(".lproj"):
            continue
        lang = entry[: -len(".lproj")]
        table = load(os.path.join(RESOURCES, entry, "Localizable.strings"))
        result[lang] = {k: table[k] for k in wanted if k in table}
        missing = [k for k in wanted if k not in table]
        if missing and lang == "en":
            print(f"export_strings: keys missing from the English catalog: {missing}", file=sys.stderr)
            return 1
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(f"strings.json: {len(wanted)} keys × {sorted(result)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
