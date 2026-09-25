# Continuous zoom (pinch/scroll) and pan in the viewer window

> Status: **shipped**, including review fixes. No known gaps.

## Problem it solved

The viewer's "zoom" was window resizing, not content zoom: the View-menu
presets and Metal render path always drew the video aspect-fit inside
whatever window size resulted. There was no way to magnify a *region* of the
shared screen — unreadable small text on a high-res share squeezed into a
smaller viewer window, and the 200% preset just grew the window (clamped to
`visibleFrame`, so a small display couldn't even reach it).

## What shipped

Continuous content zoom 1×–8×, pinch (`magnify(with:)`) and ⌥+scroll,
anchored under the cursor; two-finger scroll pans while zoomed; double-tap
(`smartMagnify`) toggles fit ↔ 2×; ⌘0/presets reset content zoom; menu items
for zoom in/out. Annotation drawing/rendering stays pixel-correct at any
zoom/pan.

## Key decision and why

**The zoom/pan transform is applied as a layer/frame transform in
`AspectFitHostView` (the window's content view), not a Metal vertex
transform in the renderer.** Two reasons, in order of importance:

1. The annotation overlay's correctness falls out for free. `layout()`
   already gives the annotation `contentSubview` the *same* frame as the
   video's Metal layer — the single-rect discipline that made annotations
   pixel-correct in the first place. A zoomed/panned video rect keeps the
   overlay congruent with zero changes to `AnnotationCanvasView`'s normalized
   coordinate math. A Metal vertex transform would instead require
   duplicating the zoom math in the overlay's hit-testing and rendering —
   two implementations to keep in sync, the exact class of bug the
   single-rect design was built to avoid.
2. The renderer's drawable is already exactly the video's pixel size; the
   compositor (`.resizeAspect`) already does all the scaling today, so
   enlarging/offsetting `metalLayer.frame` reuses that path with zero changes
   to `MetalViewerRenderer`, its shader, or the display-link loop.

The pure geometry (`ViewerZoomMath`: `videoRect`, `zoomed(anchor:)`,
`panned`, clamping) is CI-testable and holds every branch — scale clamped to
[1, 8], offset clamped so no letterbox gap opens, anchor invariance (the
point under the cursor stays under the cursor).

## Non-obvious fixes from implementation and review

- **8× zoom on a large retina window can exceed Core Animation's ~16384 px
  per-axis texture limit.** `ViewerZoomMath.effectiveMaxScale(fit:backingScale:)`
  computes a per-window ceiling; every gesture/menu path passes it through
  rather than hardcoding 8.
- **⇧⌘+ was already taken** — "+" is a shifted character, so ⇧⌘+ collided
  with the existing "Zoom to 200%" window preset (keyEquivalent "+", plain
  ⌘). Menu chord is ⌥⌘+ / ⌥⌘- instead.
- **Non-precise scroll devices (classic mice) report line-unit deltas**,
  ~16x smaller than trackpad deltas — `scrollWheel` scales them up for both
  zoom and pan so a mouse wheel isn't effectively dead.
- **A stale pan offset must re-clamp against the *current* fit rect before
  the anchor math runs**, not after — otherwise a window resize between two
  gestures makes the next gesture jump instead of continuing smoothly
  (`testZoomAfterFitShrinkKeepsAnchorStable`).
- **Zoom state must reset on resolution change, session reconnect, and
  disconnect** — the viewer window lives for the whole process lifetime, so
  without an explicit reset the next share inherits a stale zoom/pan.
- Not done: the planned hands-on macOS verification of scroll direction sign
  and ⥁-scroll zoom sensitivity — this was implemented in a Linux
  environment with no macOS host; CI covers build + the pure geometry suite
  only. Worth a manual pass on real hardware if scroll direction ever looks
  wrong.

## Where it lives now

- `Sources/ViewerZoomMath.swift` — pure geometry (`ViewerZoomState`,
  `ViewerZoomMath`), tested in `Tests/TailscreenTests/ViewerZoomMathTests.swift`.
- `Sources/AppState.swift` — `AspectFitHostView` (`zoomState`, `layout()`,
  `magnify`/`smartMagnify`/`scrollWheel` overrides), reset call sites
  (`setViewerZoom`, `videoSize.didSet`, `connect(to:)`).
- `Sources/ViewerCommands.swift` / `Sources/AppMenu.swift` — zoom in/out menu
  items, routed directly to `appState?.zoomViewerContent(by:)`.
- `Sources/ViewerShortcutsOverlay.swift` — the "Zoom" cheat-sheet section.
- The Windows/GTK equivalent of this geometry (`ViewerZoomMath` reused
  as-is) is part of `plans/platform-alignment.md` Phase 1.2.
