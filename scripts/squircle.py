#!/usr/bin/env python3
"""squircle.py — emit Apple's continuously-cornered rounded rect as an SVG path.

The tile in docs/assets/app-icon.svg is this shape, not an `rx` rounded rect.
A plain circular corner changes curvature abruptly where it meets the straight
edge; Apple's corner eases into it, and that easing is most of what makes an
icon read as "native" beside the system ones.

The shape is three cubic beziers per corner. The constants below are the ones
`UIBezierPath(roundedRect:cornerRadius:)` actually emits, recovered by Liam
Rosenfeld (https://liamrosenfeld.com/posts/apple_icon_quest/) — his measured
error against Apple's real shape is 0 px, versus ~322 px for a circular corner
and ~1365 px for a true superellipse, so do not be tempted to substitute
either. They are expressed in units of the corner radius, so they scale.

Note the corner reaches 1.528665r along each edge, well past r. A radius large
enough to make that exceed half the side has no straight edge left and this
construction degenerates; --check rejects it.

Usage:
    scripts/squircle.py                      # the app-icon tile
    scripts/squircle.py --x 0 --y 0 --w 500 --h 500 --r 100 --precision 8
    scripts/squircle.py --check              # self-test, no output path

Paste the result into the tile `<path d="...">`; nothing reads this at build
time, it is a generator you run when the tile geometry changes.
"""

import argparse
import sys

EDGE = 1.528665  # how far the corner reaches along each edge, in units of r
C1A, C1B = 1.08849296, 0.86840694  # outer cubic's controls (far, then near)
P1U, P1V = 0.63149379, 0.07491139  # junction between the outer and middle cubics
C2A, C2B = 0.37282383, 0.16905956  # middle cubic's controls


def corner(origin, u, v, r):
    """One corner, as [start, (c1, c2, end) x3].

    `u` is the inward unit direction along the edge we arrive on, `v` the one
    along the edge we leave by, so a single expression serves all four corners.
    The middle cubic is symmetric about the corner's 45-degree diagonal and the
    outer two are mirror images of each other across it.
    """
    def p(a, b):
        return (origin[0] + a * r * u[0] + b * r * v[0],
                origin[1] + a * r * u[1] + b * r * v[1])

    return [
        p(EDGE, 0),
        (p(C1A, 0), p(C1B, 0), p(P1U, P1V)),
        (p(C2A, C2B), p(C2B, C2A), p(P1V, P1U)),
        (p(0, C1B), p(0, C1A), p(0, EDGE)),
    ]


def path(x, y, w, h, r, precision=3):
    """The full closed path, clockwise from the top-left corner's left edge."""
    if EDGE * r > min(w, h) / 2:
        raise ValueError(
            "radius %g leaves no straight edge on a %gx%g rect "
            "(the corner reaches %.1f, half the side is %.1f)"
            % (r, w, h, EDGE * r, min(w, h) / 2))
    x1, y1 = x + w, y + h
    corners = [((x, y), (0, 1), (1, 0)), ((x1, y), (-1, 0), (0, 1)),
               ((x1, y1), (0, -1), (-1, 0)), ((x, y1), (1, 0), (0, -1))]

    def f(t):
        return ("%.*f" % (precision, t)).rstrip("0").rstrip(".")

    out = []
    for i, (origin, u, v) in enumerate(corners):
        segments = corner(origin, u, v, r)
        start = segments[0]
        out.append(("M %s %s" if i == 0 else "L %s %s") % (f(start[0]), f(start[1])))
        for c1, c2, end in segments[1:]:
            out.append("C %s %s %s %s %s %s"
                       % (f(c1[0]), f(c1[1]), f(c2[0]), f(c2[1]), f(end[0]), f(end[1])))
    return " ".join(out) + " Z"


def check():
    """Self-test: the corner's internal symmetry, then Apple's own numbers.

    The second half is the one that matters — it reproduces the path
    UIBezierPath emits for a 500x500 rect at radius 100, coordinate for
    coordinate, so a typo in any constant above fails here.
    """
    a = [(EDGE, 0), (C1A, 0), (C1B, 0), (P1U, P1V)]
    b = [(P1U, P1V), (C2A, C2B), (C2B, C2A), (P1V, P1U)]
    c = [(P1V, P1U), (0, C1B), (0, C1A), (0, EDGE)]

    def mirror(p):
        return (p[1], p[0])

    assert [mirror(p) for p in reversed(a)] == c, "outer cubics are not mirrored"
    assert [mirror(p) for p in reversed(b)] == b, "middle cubic is not self-mirrored"
    assert a[-1] == b[0] and b[-1] == c[0], "cubics are not contiguous"

    expected = (
        "M 0 152.8665 C 0 108.849296 0 86.840694 7.491139 63.149379 "
        "C 16.905956 37.282383 37.282383 16.905956 63.149379 7.491139 "
        "C 86.840694 0 108.849296 0 152.8665 0 L 347.1335 0 "
        "C 391.150704 0 413.159306 0 436.850621 7.491139 "
        "C 462.717617 16.905956 483.094044 37.282383 492.508861 63.149379 "
        "C 500 86.840694 500 108.849296 500 152.8665 L 500 347.1335 "
        "C 500 391.150704 500 413.159306 492.508861 436.850621 "
        "C 483.094044 462.717617 462.717617 483.094044 436.850621 492.508861 "
        "C 413.159306 500 391.150704 500 347.1335 500 L 152.8665 500 "
        "C 108.849296 500 86.840694 500 63.149379 492.508861 "
        "C 37.282383 483.094044 16.905956 462.717617 7.491139 436.850621 "
        "C 0 413.159306 0 391.150704 0 347.1335 Z")
    got = path(0, 0, 500, 500, 100, precision=8)
    assert got == expected, "does not match UIBezierPath:\n  want %s\n  got  %s" % (expected, got)

    for bad in ((100, 100, 40), (10, 100, 4)):
        try:
            path(0, 0, bad[0], bad[1], bad[2])
        except ValueError:
            pass
        else:
            raise AssertionError("degenerate radius %g not rejected" % bad[2])
    print("ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # Defaults are the app-icon tile: the Big Sur grid's 824x824 at radius
    # 185.4, centred on a 1024 canvas.
    ap.add_argument("--x", type=float, default=100)
    ap.add_argument("--y", type=float, default=100)
    ap.add_argument("--w", type=float, default=824)
    ap.add_argument("--h", type=float, default=824)
    ap.add_argument("--r", type=float, default=185.4)
    ap.add_argument("--precision", type=int, default=3)
    ap.add_argument("--check", action="store_true", help="run the self-test and exit")
    args = ap.parse_args()

    if args.check:
        check()
        return
    try:
        print(path(args.x, args.y, args.w, args.h, args.r, args.precision))
    except ValueError as exc:
        sys.exit("squircle.py: %s" % exc)


if __name__ == "__main__":
    main()
