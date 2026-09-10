#!/usr/bin/env python3
"""Catch closures that inherit actor isolation and are then called off that actor.

The trap
--------
A closure literal written inside an actor-isolated type (`@MainActor final
class …`, or an `actor`) inherits that isolation. When it is handed to a
framework API whose callback parameter is not `@Sendable` — which is every
imported Objective-C block — the compiler plants a dynamic executor
precondition at the closure's entry (SE-0423). The framework then invokes it
on its own queue, `swift_task_isCurrentExecutorWithFlags` reaches
`dispatch_assert_queue`, and the process dies with `EXC_BREAKPOINT (SIGTRAP)`.

Nothing catches this today. Verified against Swift 6.3 with `-swift-version 6
-strict-concurrency=complete`: the broken form and the fixed form both compile
with zero diagnostics, and no frontend flag turns it into one
(`-disable-dynamic-actor-isolation` only removes the check, which trades the
crash for a silent data race). The failure is entirely at runtime, and only
when the framework actually calls back — which is why v0.10.0-rc.11 shipped
one that took a discarded audio buffer at teardown to reach.

What this rejects
-----------------
A closure LITERAL passed to one of the callbacks in API_CALLBACKS below, from
code that is actor-isolated. Three call shapes:

    api(args) { … }              trailing closure
    api(label: { … })            inline closure argument
    api { … }                    trailing closure, no argument list

What this accepts
-----------------
  * a named handler bound as an explicitly `@Sendable` local, then passed by
    name — `SharerNoticeCenter.ensureAuthorization`, `MicCapture.scheduleSamples`
  * a call inside a `nonisolated` function — `MicCapture.installTap`
  * a call in a type that is not actor-isolated — `ScreenCapture`, which is
    `@unchecked Sendable` and nonisolated, so its closures inherit nothing

Maintenance
-----------
API_CALLBACKS is the cost of this check: it knows the callbacks we actually
adopt, not every callback that exists. Add a row when you adopt a framework
callback that fires off the calling actor. Getting the list wrong fails open
(a missed API is simply not checked), never closed.
"""

import re
import sys
from pathlib import Path

# Imported ObjC callbacks this app adopts that fire off the calling actor.
API_CALLBACKS = [
    "scheduleBuffer",            # AVAudioPlayerNode — AVFAudio's CompletionHandlerQueue
    "installTap",                # AVAudioNode — the audio render thread
    "requestAuthorization",      # UNUserNotificationCenter — UN's service queue
    "getNotificationSettings",   # UNUserNotificationCenter — UN's service queue
    "requestAccess",             # AVCaptureDevice — com.apple.root.default-qos
    "startCapture",              # SCStream — ScreenCaptureKit's own queue
    "stopCapture",               # SCStream — ScreenCaptureKit's own queue
]

ROOTS = ["Apps", "Packages"]
SKIP_PARTS = {".build", "upstream"}

_APIS = "|".join(API_CALLBACKS)
# `[^;{}]` keeps a multi-line argument list in scope without running past the
# end of the statement; the bound stops a pathological match from spanning a
# whole file.
CALL_SHAPES = [
    ("trailing closure", re.compile(r"\b(?:%s)\s*\((?:[^;{}]{0,400}?)\)\s*\{" % _APIS, re.S)),
    ("inline closure argument", re.compile(r"\b(?:%s)\s*\((?:[^;{}]{0,400}?):\s*\{" % _APIS, re.S)),
    ("trailing closure", re.compile(r"\b(?:%s)\s*\{" % _APIS)),
]

MODIFIERS = r"(?:public|internal|private|fileprivate|open|final|static|class|override|nonisolated|convenience|required|@\w+(?:\([^)]*\))?)"
TYPE_DECL = re.compile(r"^\s*(?:%s\s+)*(class|struct|enum|actor|extension)\s+" % MODIFIERS)
FUNC_DECL = re.compile(r"^\s*(?:%s\s+)*(?:func|init)\b" % MODIFIERS)


def blank_line_comments(text):
    """Blank `//` comments in place so a comment naming an API is not a hit.

    Length-preserving, so reported offsets still map to real lines.
    """
    out = []
    for line in text.split("\n"):
        i = line.find("//")
        out.append(line if i < 0 else line[:i] + " " * (len(line) - i))
    return "\n".join(out)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def isolation_of(lines, index):
    """Is the code at `index` actor-isolated, per its ENCLOSING declarations?

    Enclosure is read off indentation, which `make format-check` guarantees is
    uniform. Walking back for the nearest declaration of any indentation is not
    the same thing and gets this wrong: a nested type that has already closed
    (`MicCapture.TestToneState`) sits between the call and the type that really
    encloses it, and answering "nonisolated" there is a false negative on the
    exact bug this check exists for.

    A `nonisolated` function wins over its type: that is the seam used to
    escape the trap.
    """
    level = indent_of(lines[index])
    func_line = None
    for i in range(index - 1, -1, -1):
        line = lines[i]
        stripped = line.strip()
        # A wrapped signature's closer (`    ) {`) sits at the declaration's own
        # indentation, so letting it lower the level hides the declaration on
        # the next line up — which is how `MicCapture.installTap`, the
        # `nonisolated` seam itself, read as isolated. Compiler directives are
        # skipped for the same reason: they carry no indentation.
        if not stripped or stripped[0] in ")}],#" or indent_of(line) >= level:
            continue
        level = indent_of(line)
        if func_line is None and FUNC_DECL.match(line):
            if re.search(r"\bnonisolated\b", line):
                return False, "nonisolated func"
            if "@MainActor" in line:
                return True, "@MainActor func"
            func_line = i
            continue
        m = TYPE_DECL.match(line)
        if not m:
            continue
        if m.group(1) == "actor":
            return True, "actor"
        if "@MainActor" in line:
            return True, "@MainActor type"
        # The repo's convention puts the attribute on its own line above.
        for j in range(i - 1, -1, -1):
            prev = lines[j].strip()
            if not prev:
                continue
            return ("@MainActor" in prev), (
                "@MainActor type" if "@MainActor" in prev else "nonisolated type")
        return False, "nonisolated type"
    return False, "no enclosing type"


def scan(path, text):
    lines = text.split("\n")
    scannable = blank_line_comments(text)
    seen = set()
    findings = []
    for shape, rx in CALL_SHAPES:
        for m in rx.finditer(scannable):
            line = scannable[: m.start()].count("\n")
            if line in seen:
                continue
            # A declaration of a function that happens to share the name.
            if FUNC_DECL.match(lines[line]):
                continue
            isolated, why = isolation_of(lines, line)
            if not isolated:
                continue
            seen.add(line)
            findings.append((path, line + 1, shape, why, " ".join(m.group(0).split())[:70]))
    return findings


def main(argv):
    findings = []
    if argv and argv[0] == "-":
        findings = scan("<stdin>", sys.stdin.read())
    else:
        for root in argv or ROOTS:
            for path in sorted(Path(root).rglob("*.swift")):
                if SKIP_PARTS & set(path.parts):
                    continue
                findings += scan(str(path), path.read_text())
    for path, line, shape, why, snippet in findings:
        print("%s:%d: error: %s handed to a framework callback from %s — it "
              "inherits that isolation and traps when the framework calls it "
              "off that actor. Bind it to an explicitly `@Sendable` local, or "
              "make the enclosing function `nonisolated`.\n    %s"
              % (path, line, shape, why, snippet))
    if findings:
        print("\n%d isolation-inheriting callback(s). See "
              ".claude/rules/macos-app.md, \"a closure a @MainActor type hands "
              "to an imported ObjC API\"." % len(findings))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
