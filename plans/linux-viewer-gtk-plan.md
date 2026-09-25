# Building the live Linux viewer on swift-cross-ui / GTK

> **Status: shipped through L4** (foundation, zoom/pan, stats/placards,
> back-channel + input/annotations, sharer picker + hub chrome). SDL viewer
> retired — GTK is the sole Linux/Windows viewer. Windows port (L5) is a
> separate scoped plan: `plans/viewer-windows-plan.md`. Remaining gaps below.
> Referenced from `Apps/linux/Package.swift` and `GtkVideoView.swift`.

## Goal

Turn the headless `tailscreen-viewer` CLI into a native-feeling GTK4 desktop
viewer on Linux, reusing the portable `ViewerSession` data plane the mac app
shares, while adding a real window, zoom/pan, stats overlay, placards,
annotations, remote-control input, and a sharer picker.

## Key decisions & why

- **swift-cross-ui (native GTK4 widgets) over SDL.** SDL gives a fast video
  surface but no widget toolkit — every button/panel would be hand-drawn and
  never look native. swift-cross-ui renders real GTK widgets from
  SwiftUI-like declarative Swift, matching the mac app's idiom.
- **De-risked with a throwaway spike before committing**, against stock
  `swift-cross-ui@main` with no fork: a downstream `GtkVideoView : View`
  (~70 lines) hosts a real `Gtk.GLArea`, gets a live GL ES context under
  Xvfb + Mesa `llvmpipe`, and a YUV420→RGB BT.709 shader was verified pixel-
  exact via `glReadPixels`. This proved the one expensive-looking risk (can a
  low-latency GL surface live inside swift-cross-ui without forking it) and
  is now a permanent CI-gated render test (`linux-gtk-viewer` job) — a
  guarantee the SDL path never had.
- **Everything below the window is reused unchanged**: `ViewerSession`
  (NACK/RR/PLI/FEC), `FFmpegVideoDecoder`, Opus→`ALSAAudioSink`, and
  `TsnetTransport`. The GTK app only replaces the video *sink* and adds
  chrome. `ViewerZoomMath`, the placard state machine, and `ViewerStats`
  aggregation were hoisted into portable packages so the mac and GTK viewers
  share the same tested logic rather than duplicating it.
- **Threading: GTK owns the main thread; tsnet runs on a background Task.**
  The decoder runs synchronously on the transport task, writes into a locked
  latest-frame box, and a GTK idle source triggers `queueRender()` to pull
  and upload it — GTK calls never happen off the main thread. This
  live-frames-over-tsnet path is what the spike did *not* exercise (it used
  a static frame), so it was L0's explicit deliverable, not an afterthought.
- **Audio sink is fronted by a `ThreadedAudioSink`** because the transport
  loop runs on the GTK main thread and ALSA's blocking device write (~50
  writes/s) would otherwise stall video. Best-effort: a busy/missing device
  drops to video-only.
- **Scroll/zoom and remote-control scroll share one C shim
  (`cgtkvideo_attach_scroll`)** because swift-cross-ui has no
  `EventControllerScroll` binding and there is only one scroll callback to
  attach — can't split local-zoom and remote-forward across two controllers.
  A pure `ViewerInputMapping.scrollDisposition` owns the routing plus the
  GDK↔wire sign flip (GDK down-positive vs. wire up-positive).
- **Input/annotation forwarding go through one `AsyncStream` with a single
  consumer each** (`InputForwarder`, `AnnotationForwarder`) rather than a
  Task per event — required so a down/up key pair or an undo can't invert
  order, and so a re-bindable channel survives back-channel reconnects.
- **Separate `Apps/linux` package**, not folded into the core — swift-cross-ui
  + GTK4 shouldn't weigh down the core `linux-viewer` CI job. It reuses
  `TailscreenLinuxBackends`'s `TailscreenViewerCore`/`TailscreenViewerTsnet`.
- **Picker dials by tailnet IP, not hostname** — sidesteps a `from == dest`
  hostname-match limitation when the viewer and a listed sharer share a name.

## Open items / remaining gaps

- **Mic capture** has no ALSA input path yet (playback-only today); mic
  toggle in the annotation/audio UI stays deferred until it exists.
- **Non-pen annotation tools** (line/arrow/rect/oval/click) not built — only
  freehand pen ships. Thick-stroke GL line width is best-effort.
- **Sharer list is a one-shot snapshot**, not live IPN-bus refresh; no
  automatic reconnect/back-to-picker after a session ends.
- **L5 (Windows)** is fully separate scope; see `plans/viewer-windows-plan.md`.

## Where it lives

- App: `Apps/linux` (separate SwiftPM package).
- Video surface: `GtkVideoView.swift` (GTK4/GL, YUV→RGB shader), C shims for
  scroll (`cgtkvideo_attach_scroll`) and annotation drawing
  (`cgtkvideo_draw_annotations`).
- Reused portable core: `Packages/TailscreenLinuxBackends`
  (`TailscreenViewerCore`, `TailscreenViewerTsnet`), `ViewerZoomMath`,
  `ViewerInputMapping`, hoisted `ViewerStats`/placard state machine in
  `TailscreenProtocol`.
- Hub chrome: `ViewerChrome.swift` (picker, placards, multi-account
  `ProfileStore`); `--ui-preview` renders it headless with seeded fake data.
- CI: `linux-gtk-viewer` job (GTK4/epoxy/Mesa/Xvfb, headless GL readback
  test); `linux-viewer` job remains the data-plane gate. Live tsnet runs stay
  local-only, same constraint as the mac E2E suites.
- Linux specifics generally: `.claude/rules/linux.md`.
