# Continuous zoom (pinch/scroll) and pan in the viewer window

> Status: implemented in this PR.

## Problem & motivation

The viewer's "zoom" today is not zoom at all — it is window resizing. The three View-menu
presets (Actual Size ⌘0, 50% ⌘-, 200% ⌘+; `Sources/AppMenu.swift:188-207`) post a
`.tailscreenViewerSetZoom` notification (`Sources/ViewerCommands.swift:91-113,190`) that
`AppState.setViewerZoom` (`Sources/AppState.swift:1124-1133`) turns into a window resize via
`snapViewerWindow` (`Sources/AppState.swift:1153-1189`). The video always renders aspect-fit
inside whatever window size results. There is no way to magnify a *region* of the shared
screen — reading small text on a 5K share squeezed into a 1440p viewer is impossible, and
the 200% preset just makes the window bigger (clamped to `visibleFrame`, so on a small
display it can't even reach 200%).

We want continuous pinch-to-zoom / modifier-scroll zoom anchored under the cursor, panning
while zoomed, and a quick reset — the interaction model of Preview/Maps — without breaking
the annotation overlay's normalized coordinate mapping.

## Goals / Non-goals

**Goals**
- Continuous content zoom 1×(fit)–8×, driven by pinch (`magnify(with:)`) and ⌥+scroll.
- Zoom anchored at the cursor position (the point under the cursor stays put).
- Pan while zoomed: two-finger scroll (no modifier) and space/middle-drag are out; plain
  two-finger scroll is enough for v1.
- Double-tap smart-magnify (`smartMagnify(with:)`) toggles fit ↔ 2× at the tap point.
- ⌘0 / the existing presets reset content zoom to fit (in addition to their current
  window-snap behavior).
- Annotation drawing and remote annotation rendering stay pixel-correct at any zoom/pan.
- Pure, CI-testable zoom/pan geometry.

**Non-goals**
- Changing the wire protocol, encoder, or requesting a higher-resolution region from the
  sharer (no "zoom = re-encode ROI").
- Zoom on the sharer's preview or overlay panel.
- Scroll-bar chrome or minimap.
- Persisting zoom across sessions.

## Current state (with file:line references)

- **Presets → window resize.** `ViewerCommands.viewerZoomActualSize/Half/Double`
  (`Sources/ViewerCommands.swift:91-113`) post `.tailscreenViewerSetZoom` with a factor;
  AppState observes it (`Sources/AppState.swift:349-355`) and calls `setViewerZoom(_:)`
  (`Sources/AppState.swift:1124-1133`), which resets `userResizedViewer` and snaps the
  window to `videoSize × factor` through `programmaticSnap` (`1139-1143`) /
  `snapViewerWindow` (`1153-1189`, `backingScaleFactor` at `1156`). Menu validation always
  enables these items (`Sources/ViewerCommands.swift:172-180`).
- **Rendering.** `MetalViewerRenderer` owns a `CAMetalLayer` with
  `contentsGravity = .resizeAspect` (`Sources/MetalViewerRenderer.swift:213-225`), sizes
  `drawableSize` to the video's pixel dims (`366-378`, firing `onVideoSizeChanged`), and
  draws a fixed fullscreen quad — NDC positions and UVs are hardcoded in the shader
  (`508-541`). No per-frame transform exists.
- **Layout.** `AspectFitHostView` (`Sources/AppState.swift:1894-1984`) is the window's
  content view. Its `layout()` (`1904-1915`) frames **both** the metal layer and the
  annotation overlay (`contentSubview`) to `aspectFitRect()` (`1957-1983`), computed inside
  `usableRect()` (`1951-1955`, window `contentLayoutRect` minus the unified-toolbar inset).
  This single rect is the linchpin: video and overlay always share it.
- **Annotation coordinates.** `AnnotationCanvasView` normalizes pointer input to its own
  bounds (`Sources/AnnotationCanvasView.swift:41-53,99-106`) and renders shapes by scaling
  normalized points back to its layout rect (`117-201`). Because the overlay's frame ==
  the video rect, normalized coords == video-relative coords. `AnnotationOverlayHostView`
  (`Sources/AnnotationOverlayHostView.swift:18-75`) handles `keyDown`/`rightMouseDown` but
  does **not** override `scrollWheel`/`magnify`, so those events bubble up the responder
  chain to `AspectFitHostView`.
- **Window/overlay wiring.** `ensureViewer()` (`Sources/AppState.swift:940-1118`) builds
  the host (`997-1002`), sets `host.contentSubview = overlay` (`1046-1049`), adds the
  stats/shortcuts/placard overlays as *sibling* subviews pinned to the host (`1065-1097`,
  these must not zoom), and `onVideoSizeChanged` updates `host.videoSize` + snaps the
  window (`1010-1028`). The window lives for the process lifetime (`935-954`).

## Design

**Apply the transform as a layer/frame transform in `AspectFitHostView`, not a Metal
vertex transform.** Rationale, having read the renderer:

1. The renderer's drawable is already exactly the video's pixel size; the *compositor*
   (via layer frame + `.resizeAspect`) does all scaling today. Enlarging/offsetting
   `metalLayer.frame` reuses that path — zero changes to `MetalViewerRenderer`, its shader,
   or the display-link loop, and no new state shared with the decoder thread.
2. The annotation overlay's correctness falls out for free: `layout()` already gives
   `contentSubview` the same frame as the metal layer. A zoomed/panned video rect keeps the
   overlay congruent with the video, so `AnnotationCanvasView`'s normalized coordinates
   remain video-relative with **no changes to annotation code at all**. A Metal vertex
   transform would instead require duplicating the zoom math in the overlay's hit-testing
   and rendering — two implementations to keep in sync.
3. Cost: the compositor samples one layer at scale — the same work `.resizeAspect` does
   now. (Magnified sampling quality is the compositor's bilinear filter, same as today's
   upscale case.)

**New pure geometry type — `ViewerZoomModel` (new file `Sources/ViewerZoomModel.swift`):**

```swift
struct ViewerZoomState: Equatable {
    var scale: CGFloat = 1.0          // 1.0 == aspect-fit
    var offset: CGPoint = .zero       // pan, in viewport points
}
enum ViewerZoomMath {
    static let minScale: CGFloat = 1.0
    static let maxScale: CGFloat = 8.0
    /// Zoomed video rect: aspect-fit rect scaled about its center, then offset, then
    /// clamped so no letterbox gap opens on an axis where video ≥ viewport.
    static func videoRect(fit: CGRect, state: ViewerZoomState) -> CGRect
    /// New state after zooming by `delta` (multiplicative) anchored at `anchor`
    /// (viewport point): the video point under `anchor` stays under `anchor`.
    static func zoomed(state: ViewerZoomState, by delta: CGFloat, anchor: CGPoint,
                       fit: CGRect) -> ViewerZoomState
    static func panned(state: ViewerZoomState, by delta: CGSize, fit: CGRect) -> ViewerZoomState
}
```

All clamping (scale to [1, 8]; offset so edges never detach) lives here — this is the
CI-testable core per CLAUDE.md's extract-the-decision pattern.

**Event handling in `AspectFitHostView`:** add `zoomState: ViewerZoomState` and override
`magnify(with:)`, `smartMagnify(with:)`, and `scrollWheel(with:)`. `scrollWheel` with ⌥
zooms (anchor = cursor via `convert(event.locationInWindow, from: nil)`); without a
modifier and `scale > 1` it pans; at `scale == 1` it calls `super` (nothing scrolls today,
so behavior is unchanged). Events land on `AnnotationOverlayHostView` first but bubble to
the host since the overlay doesn't override them — verify a zero-distance `DragGesture`
(`Sources/AnnotationCanvasView.swift:41`) doesn't swallow `scrollWheel` (it doesn't; SwiftUI
drag gestures ignore scroll). `layout()` changes one line: use
`ViewerZoomMath.videoRect(fit: aspectFitRect(), state: zoomState)` for both the metal layer
and `contentSubview`. Set `layer?.masksToBounds = true` on the host (`Sources/AppState.swift:998-1000`)
so the enlarged metal layer clips at the window edge; the overlay NSView is clipped by the
window anyway, but mark it `clipsToBounds`-safe by keeping stats/shortcuts/placard as
siblings (already true, `1065-1097`).

**Reset & presets:** `setViewerZoom` (`Sources/AppState.swift:1124-1133`) additionally sets
`host.zoomState = .init()` before snapping, so ⌘0/⌘-/⌘+ keep their window-sizing meaning
and also un-zoom content. `smartMagnify` toggles fit ↔ 2× anchored at the event point.
On `onVideoSizeChanged` (`1010-1028`) reset `zoomState` — a sharer-side resolution change
invalidates the pan space. On `disconnect()` (`1198-1218`) reset too.

**Menu/toolbar:** add "Zoom In ⇧⌘+ / Zoom Out ⇧⌘-" items to the View menu
(`Sources/AppMenu.swift:184-207`) targeting new `ViewerCommands.viewerContentZoomIn/Out`
selectors that post a new `.tailscreenViewerContentZoom` notification (delta ±1.25×, anchor
= viewport center); AppState routes to the host. A cursor-anchored zoom needs no toolbar
item for v1; the shortcuts overlay (`Sources/ViewerShortcutsOverlay.swift`) gets two rows.

## Implementation steps (ordered checklist)

1. [ ] Add `Sources/ViewerZoomModel.swift` with `ViewerZoomState` + `ViewerZoomMath`
   (`videoRect`, `zoomed(state:by:anchor:fit:)`, `panned`, clamp constants). Pure, no AppKit
   types beyond `CGRect`/`CGPoint`.
2. [ ] Add `Tests/TailscreenTests/ViewerZoomMathTests.swift`: identity at scale 1; anchor
   invariance (point under anchor maps to itself after zoom); clamping at min/max scale;
   pan clamping at all four edges; zoom-out re-centers; letterboxed (fit ≠ viewport) cases
   both axes; state survives fit-rect change proportionally.
3. [ ] `AspectFitHostView` (`Sources/AppState.swift:1894-1984`): add `zoomState` (didSet →
   `needsLayout = true`), change `layout()` (`1904-1915`) to use
   `ViewerZoomMath.videoRect`, override `magnify`, `smartMagnify`, `scrollWheel`.
4. [ ] `ensureViewer()` (`Sources/AppState.swift:997-1002`): `host.layer?.masksToBounds = true`.
5. [ ] `setViewerZoom` (`Sources/AppState.swift:1124-1133`): reset `host.zoomState` first;
   keep a `weak` host reference on AppState (it already holds the window; add
   `private weak var viewerHost: AspectFitHostView?` set in `ensureViewer`).
6. [ ] Reset `zoomState` in `onVideoSizeChanged` closure (`Sources/AppState.swift:1010-1028`)
   and in `disconnect()` (`1198-1218`).
7. [ ] `Sources/ViewerCommands.swift`: add `viewerContentZoomIn/Out` selectors + the
   `.tailscreenViewerContentZoom` notification name (next to `:190`); extend
   `validateMenuItem` (`:172-180`) — enable always, same rationale as the presets.
8. [ ] `Sources/AppMenu.swift:184-207`: add the two items (⇧⌘+ / ⇧⌘-), keeping the three
   presets untouched; add `L("Zoom In")` / `L("Zoom Out")` keys to
   `Sources/Resources/en.lproj/Localizable.strings` (LocalizationCatalogTests enforces sync).
9. [ ] `Sources/ViewerShortcutsOverlay.swift`: document pinch/⌥-scroll/double-tap rows.
10. [ ] Manual pass with `./test-local.sh 2` + `scripts/net-impair.sh` off: zoom/pan while
    annotating on both ends; confirm strokes land on identical video pixels at 4×.

## Files to change / add

| File | Change |
|---|---|
| `Sources/ViewerZoomModel.swift` | **new** — pure zoom/pan geometry |
| `Sources/AppState.swift` | `AspectFitHostView` events+layout (1894-1984); host ref; resets in `setViewerZoom` (1124), `onVideoSizeChanged` (1010), `disconnect` (1198); `masksToBounds` (997) |
| `Sources/ViewerCommands.swift` | new selectors + notification name (near 108-113, 190); validation (172-180) |
| `Sources/AppMenu.swift` | View-menu items (184-207) |
| `Sources/ViewerShortcutsOverlay.swift` | cheat-sheet rows |
| `Sources/Resources/en.lproj/Localizable.strings` | new keys |
| `Tests/TailscreenTests/ViewerZoomMathTests.swift` | **new** — CI-able geometry tests |

## Testing strategy

- **CI-able (pure decision, per CLAUDE.md):** `ViewerZoomMathTests` covers every branch of
  `videoRect`/`zoomed`/`panned` — anchor invariance, clamps, letterbox interaction with
  `aspectFitRect`-shaped inputs. Add it to CLAUDE.md's pure-suite list (the file instructs
  this when a new decision is extracted). `LocalizationCatalogTests` picks up the new keys
  automatically.
- **Local E2E:** extend `ScreenShareCaptureHelperTests` (the only suite with a real
  on-screen `NSWindow` and live render path) with one assertion: after first
  `onVideoSizeChanged`, set `host.zoomState` programmatically via a small test seam
  (`AspectFitHostView.zoomState` is internal already since it lives in `Sources/`) and
  assert `metalLayer.frame == contentSubview.frame` and both equal
  `ViewerZoomMath.videoRect(...)`. No new tsnet machinery. Gesture *events* themselves stay
  manual (xctest can't synthesize trusted pinch events) — covered by the manual pass in
  step 10.
- **No CI regression risk:** nothing here touches tsnet, SCStream, or the helpers, so the
  Build workflow's `make test` covers the new unit suite directly.

## Risks & pitfalls

- **Annotation congruence is the invariant.** Any path where `metalLayer.frame` and
  `contentSubview.frame` diverge silently breaks stroke alignment (the exact bug the
  aspect-fit host was built to fix, `Sources/AppState.swift:980-996`). Keep both assignments
  in `layout()` on the same computed rect — never set one elsewhere.
- **Overlay hit area grows with zoom.** The overlay NSView's frame extends past the window
  at high zoom; AppKit clips events to the window so this is safe, but the stats/shortcuts/
  placard overlays must remain host-pinned siblings (`Sources/AppState.swift:1065-1097`),
  never children of `contentSubview`.
- **CATransaction discipline.** `layout()` already wraps layer-frame changes in
  `setDisableActions(true)` (`Sources/AppState.swift:1910-1913`); zoom updates go through the
  same path or pinch will rubber-band via implicit animations.
- **Don't touch the renderer's threading.** `zoomState` is `@MainActor`-confined view state;
  the renderer/decoder never read it. No new `@unchecked Sendable`.
- **Window resize vs. content zoom interplay.** `userResizedViewer` /
  `suppressViewerResizeTracking` (`Sources/AppState.swift:227,231`) semantics are unchanged —
  content zoom must not set either flag, or auto-snap on the next share breaks.
- **Process-lifetime window.** The viewer window is never torn down
  (`Sources/AppState.swift:935-939`); zoom state must be reset on disconnect or the next
  session inherits a 6× view.
- CLAUDE.md constraints (no `SCShareableContent`/picker/main-process capture) are untouched
  by this plan — it is viewer-window-only.

## Estimated scope

**M** — ~350-450 LOC total: ~120 new geometry + ~150 tests + ~120 view/menu/wiring
changes. One iteration, no protocol or helper changes.

## Deviations

Recorded while implementing; everything else landed as planned.

- **File name.** The pure geometry lives in `Sources/ViewerZoomMath.swift` (named for
  the `ViewerZoomMath` enum it contains), not `Sources/ViewerZoomModel.swift`.
- **`AspectFitHostView` stays `private`.** The plan's local-E2E step assumed the class
  was already internal ("`AspectFitHostView.zoomState` is internal already since it
  lives in `Sources/`") — it is in fact `private` at file scope in `Sources/AppState.swift`.
  Rather than widen its access for one assertion, the planned
  `ScreenShareCaptureHelperTests` congruence check was dropped: `layout()` assigns both
  `metalLayer.frame` and `contentSubview.frame` from the *single* rect
  `ViewerZoomMath.videoRect` returns (same one-rect discipline as before), and the rect
  math itself is covered by `ViewerZoomMathTests` on CI.
- **Center reset instead of proportional survival across fit changes.** `videoRect`
  re-clamps a stale `offset` against the current fit rect (so a window resize can never
  open a letterbox gap), but the offset is not proportionally rescaled — the plan's
  "state survives fit-rect change proportionally" test became the re-clamp test
  `testVideoRectReclampsStaleOffsetAfterFitShrinks`.
- **`smartMagnify` toggle threshold.** Toggles back to fit from *any* scale > 1 (not
  only from exactly 2×), matching Preview's behavior.
- **Shortcuts overlay.** Got a dedicated "Zoom" section (6 rows: pinch, ⌥-scroll,
  scroll-pan, double-tap, ⇧⌘+/⇧⌘-, ⌘0) instead of "two rows" folded into existing
  sections — the gesture surface warranted its own group.
- **Menu wiring symmetry.** `viewerContentZoomIn/Out` post `.tailscreenViewerContentZoom`
  with a multiplicative `delta` (1.25 / 1÷1.25) and AppState routes it to the host via a
  weak `viewerHost` reference, exactly as planned; the anchor for menu-driven zoom is the
  fit rect's center (computed in the host, not passed in the notification).
- **Manual pass (step 10) not performed.** This change was authored in a Linux
  environment with no macOS host; CI covers build + unit tests. The two things that
  need a hands-on check on real hardware: scroll/pan *direction* (natural-scrolling sign
  conventions; the pan negates `scrollingDeltaY` for the non-flipped host view) and the
  ⌥-scroll zoom sensitivity constant (2× per ~100 points of scroll).
