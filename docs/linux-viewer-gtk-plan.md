---
title: Live Linux viewer on swift-cross-ui / GTK
nav_order: 12
permalink: /linux-viewer-gtk-plan/
---

# Building the live Linux viewer on swift-cross-ui / GTK

A working plan (not a commitment) for turning today's headless
`tailscreen-viewer` CLI into a **native-feeling desktop viewer** on Linux —
a real window with letterboxed video, zoom/pan, a stats overlay, connection
placards, and (later) annotations + a sharer picker — reusing the portable
`ViewerSession` data plane the mac app now shares.

The chrome is built with **[swift-cross-ui](https://github.com/stackotter/swift-cross-ui)**
(a SwiftUI-like declarative framework that renders **native GTK4 widgets** on
Linux), and the video is a custom **`GtkVideoView`** — a downstream `View` that
hosts a `GtkGLArea` and draws decoded frames with an OpenGL YUV→RGB shader.

## Why this foundation (and why not SDL)

The viewer is video-first, so SDL (window + input + a fast YUV surface) was the
obvious base. But SDL is not a widget toolkit — every button, panel, and line
of text is hand-drawn, and it never looks native. swift-cross-ui gives real
native GTK widgets from declarative Swift that reads like the mac app's SwiftUI,
which is the on-theme choice for a Tailscreen viewer.

The one risk that made this look expensive — *"can a low-latency GPU video
surface live inside swift-cross-ui without forking it?"* — was **retired by a
spike** (see below). With that gone, the swift-cross-ui/GTK path costs about the
same as SDL + an immediate-mode GUI, but yields a native-looking, Swift-declarative
UI and a **CI-gated render test** SDL couldn't offer.

## The spike (done) — what's already proven

A throwaway package against **stock `swift-cross-ui@main` (no fork)** established,
end to end and verified by pixel read-back, that:

- A **downstream** `struct GtkVideoView: View` (≈70 lines) conforms to the public
  `View` protocol, downcasts the generic backend to the concrete `GtkBackend`,
  constructs a real `Gtk.GLArea`, and returns it as `Backend.Widget` via a
  runtime cast — **compiles and links**, no `@_spi`, no framework patch.
- Under a virtual display (Xvfb + Mesa `llvmpipe` software GL) the app launches,
  GTK realises the GLArea, creates a **live GL ES 3.2 context**, and fires our
  render callback.
- A synthetic **YUV420 frame** uploaded as three `GL_R8` textures and converted
  by a **BT.709** fragment shader renders correct pixels — `glReadPixels`
  returned white `255,254,255`, black `1,0,1`, red `255,62,131`, blue
  `131,103,255`, matching the hand-computed BT.709 outputs to the digit.

The only difference from production is the *source* of the YUV bytes (synthetic
in the spike vs. FFmpeg's `DecodedVideoFrame` planes in the viewer) — a pointer
hand-off the GL path is indifferent to. GTK4 + epoxy + Mesa + Xvfb installed in
the CI container in ~1 minute.

## Architecture

```
tailscreen-viewer-gtk (swift-cross-ui App, DefaultBackend = GtkBackend)
 ├─ App / WindowGroup ................ native GTK window + declarative chrome
 │   ├─ GtkVideoView (GtkGLArea) ..... GL YUV→RGB render of the latest frame
 │   ├─ StatsOverlay ................. swift-cross-ui Text/VStack over the video
 │   ├─ Placards ..................... awaiting-approval / declined / degraded …
 │   └─ Toolbar / SharerPicker ....... native buttons + list (later phases)
 └─ background Task: TsnetTransport (REUSED)
       PacketListener(UDP/7447) → ViewerSession.receiveRTP / tick
         ├─ FFmpegVideoDecoder (REUSED) → DecodedVideoFrame (I420)
         │     → LatestFrameBox (locked) → queue_render on GTK thread
         ├─ built-in Opus → ALSAAudioSink (REUSED)
         └─ onControlToSend → UDP (HELLO / NACK / PLI / RR)
```

**Everything below the window is reused unchanged** from today's `Apps/linux`:
`ViewerSession`, `FFmpegVideoDecoder`, the Opus/`ALSAAudioSink` audio path, and
`TsnetTransport`. The GTK app only replaces the **sink** (`ThreadedSDLVideoSink`
→ the GLArea renderer) and adds chrome around it.

### Threading model (the main new integration point)

swift-cross-ui owns the main thread (the GTK main loop runs inside
`App.main()`). The tsnet transport is async and must run **concurrently**:

- Spawn `TsnetTransport.run(...)` on a background `Task` before/around the GTK
  loop.
- `FFmpegVideoDecoder` decodes synchronously inside `ViewerSession.receiveRTP`
  on the transport task; the decoded `DecodedVideoFrame` is stored in a locked
  **latest-frame box** (the `ThreadedSDLVideoSink` pattern).
- A redraw is requested on the **GTK thread** via `g_main_context_invoke` /
  an idle source → `gl_area.queueRender()`; the GLArea's render callback pulls
  the latest frame and uploads it. GTK calls never happen off the main thread.

This — *live decoded frames over tsnet feeding the GLArea* — is the one thing
the spike did **not** exercise (it used a static synthetic frame), so it's the
explicit deliverable of Phase L0, not an afterthought.

## What's portable / reused vs. new

| Concern | Reused / portable today | New (this effort) |
|---|---|---|
| Receive data plane | `ViewerSession` (NACK/RR/PLI/FEC) | — |
| Decode | `FFmpegVideoDecoder` | — |
| Audio | Opus → `ALSAAudioSink` | — |
| Transport | `TsnetTransport` (refactor into Core) | frame→GTK marshalling |
| Video present | `DecodedVideoFrame` (I420) | `GtkVideoView` + GL YUV renderer |
| Zoom/pan | **`ViewerZoomMath`** (already in `TailscreenProtocol`, CI-tested) | GTK event → math wiring |
| Stats | `ViewerStats` + 1 s-bucket aggregation (mac-side; **hoist to portable**) | GTK overlay rendering |
| Placards | state machine (mac-side; **hoist to portable**) | GTK overlay rendering |
| Chrome | — | swift-cross-ui views (HUD, toolbar, picker) |
| Back-channel | server-side `TailscreenControlListener` exists | viewer-side TCP dialer |

## Phased delivery

Each phase is a PR. The GLArea render path is **CI-gated headlessly** (Xvfb +
`llvmpipe`) via the spike's pixel-readback test promoted to an XCTest — a
guarantee the SDL path never had.

### L0 — Foundation: app skeleton + live video
- Add `swift-cross-ui` as a dependency; add a `tailscreen-viewer-gtk` target to
  `Apps/linux` reusing `TailscreenViewerCore` (refactor `TsnetTransport` into
  Core so both the SDL CLI and the GTK app share it).
- Productise `GtkVideoView` from the spike: GLArea + GL YUV renderer fed by a
  locked latest-frame box; per-frame `glTexSubImage2D` upload.
- Wire the background transport Task + the frame→`queue_render` marshalling.
- **Deliverable:** a native GTK window showing live decoded video from a real
  Mac sharer over tsnet (local run) — the load-bearing integration.
- **CI:** new `linux-gtk-viewer` job (apt `libgtk-4-dev libepoxy-dev
  libgl1-mesa-dri xvfb`); build the app; run the **YUV-readback render test**
  under Xvfb. Deterministic pixel assertions gate the render path.
- **Audio (done, post-L5):** the reused `ALSAAudioSink` is now wired into the
  GTK viewer's `transport.run` (`--no-audio` to disable). Because the transport
  loop runs on the GTK main thread, the sink is fronted by a `ThreadedAudioSink`
  (in `TailscreenViewerCore`) so ALSA's blocking device write happens off the
  main thread — otherwise ~50 audio writes/s would stall video. Best-effort: a
  missing/busy device drops to video-only. Mic **capture** still needs an ALSA
  input path (not built yet).

### L1 — Aspect-fit, zoom/pan, window behavior
- Letterbox aspect-fit in the GLArea viewport (port the mac `aspectFitRect`
  math); auto-snap the window to the first frame's resolution.
- GTK scroll / modifier / double-click → **`ViewerZoomMath`** (reused) → GL
  transform (cursor-anchored zoom, clamped pan, smart-magnify).
- Window title "Viewing &lt;host&gt;", resizable, black letterbox.

### L2 — Stats overlay + connection placards
- Hoist `ViewerStats` + its 1 s-bucket aggregation into `TailscreenProtocol`
  (no Metal dependency — clean move); wire the `note*` feeders + the session's
  `onPLISent`/`onNACKSent`/`onFECRecovered` hooks.
- Stats HUD as a swift-cross-ui overlay (toggle key), matching the mac field set,
  thresholds, and sparklines.
- Hoist the placard state machine to portable; render awaiting-approval,
  declined/disconnected, degraded, stalled, and decode-failed as overlay views
  driven by session state surfaced from the transport.

### L3 — Outbound TCP back-channel + interactivity
- Viewer-side TCP dialer (TailscaleKit `OutgoingConnection` → `sharer:7447`,
  framing `ScreenShareMessage`) — the porting plan's named "last gap before
  shippable". Server-side `TailscreenControlListener` shows the wire format.
  **Done:** `ViewerBackChannel` (in `TailscreenViewerTsnet`) dials + frames +
  reconnects (with a min-healthy-uptime backoff guard over the mac client's
  pattern) and dispatches inbound annotation / control-grant / revoke;
  `TsnetTransport.run` starts it alongside the UDP path and surfaces the
  sharer's caps (`onAdmitted`) so chrome is caps-gated exactly like the mac
  viewer.
- Annotation toolbar (native buttons, caps-gated) + remote-control request
  affordance. **Done:** a caps-gated Request/Release-Control button wired to the
  back-channel with grant/revoke status, **plus input capture** — once control
  is granted, `GtkVideoView` attaches `EventControllerMotion` /
  `EventControllerKey` / three `GestureClick`s and translates pointer + keyboard
  events to neutral `InputEvent`s via the pure, unit-tested `ViewerInputMapping`
  (Core: aspect-fit pointer normalization, GDK button/modifier decode, evdev→USB-
  HID keycode table). `InputForwarder` gates them on a live grant and funnels
  them through one `AsyncStream` drained by a single consumer, honouring
  `ViewerBackChannel.sendInputEvent`'s ordering contract (never one `Task` per
  event, so a down/up pair can't invert). The mapping logic is CI-tested by the
  `linux-viewer` job; the GTK event-controller wiring is compile-gated (not
  verifiable headless, same boundary as L1's interactive zoom input). **Follow-
  up:** scroll capture (swift-cross-ui exposes no `EventControllerScroll` binding
  yet — needs a small C shim), and the annotation *drawing surface* (both
  directions). Mic toggle deferred until ALSA **capture** exists (playback-only
  today).

### L4 — Sharer picker + login polish
- Use `TailscalePeerDiscovery` (exists, unused) → a native list to pick a sharer
  instead of the CLI host arg. **Done:** `TsnetTransport` split into `prepare`
  (bring the node up without a session) + `discoverPeers` (→ `[DiscoveredSharer]`)
  + `run` (dial a chosen host); `run` calls `prepare` itself so the SDL CLI is
  unchanged. Launched with no host arg, the GTK app enters picker mode
  (`PickerModel` phase machine + a swift-cross-ui `ScrollView`/`ForEach` list);
  selecting a row dials the sharer's **tailnet IP** (also sidestepping the
  `from == dest` hostname-match limitation).
- Interactive tsnet login URL surfaced as an in-window prompt (today: stderr +
  `xdg-open`). **Done:** `prepare(onLoginURL:)` routes the URL to the picker
  placard (`PickerModel.loginURL`); the stderr banner + `xdg-open` remain the
  default when no handler is supplied (the SDL CLI).
- **Follow-up:** live IPN-bus refresh of the list (today's discovery is a
  one-shot `backendStatus` seed); reconnect/back-to-picker after a session ends.
  Picker + login are live-only (a real tailnet with sharers), so compile +
  render-self-test verified; a live run needs a tailnet.

### L5 — Windows (later, separate)
- The same `GtkVideoView` *feature* on `WinUIBackend` becomes a WinUI video view
  (`SwapChainPanel` + D3D). Different backend, same architecture. Out of scope
  until Linux is solid. **Scoped:** the concrete porting plan — the reuse map
  (only the video surface + audio sink are new), the load-bearing
  `WinUIVideoView`/`SwapChainPanel` spike mirroring the GTK one, the D3D11
  YUV→RGB shim (`CSwapChainVideo`), the unchanged threading model
  (`DispatcherQueue.TryEnqueue` for `g_idle_add`), the `windows-latest` +
  **WARP** render-self-test CI story, and the W0–W3 sub-phases — lives in
  [`docs/viewer-windows-plan.md`](/viewer-windows-plan/). No Windows code can
  compile in the Linux dev/CI container (WinUIBackend is the pruned target), so
  the plan is the deliverable; implementation follows a Windows toolchain.

## CI story

- **`linux-gtk-viewer`** job: apt GTK4 + epoxy + Mesa + Xvfb, `swift build` the
  app, and run the headless GL YUV-readback XCTest under `xvfb-run` +
  `LIBGL_ALWAYS_SOFTWARE=1`. Proven to work in the spike.
- The existing `linux-viewer` job (real decode → `ViewerSession` →
  `PipelineIntegrationTests`) stays as the data-plane gate.
- The live tsnet run remains local-only (documented constraint), exactly as the
  SDL path and the mac E2E suites.

## Risks

- **swift-cross-ui is young and churns.** Our exposed surface is tiny
  (`GtkVideoView` ≈ 70 lines against the public `View` protocol) and pinned to a
  version; a `View`-protocol reshape touches only that file. Far lighter than a
  fork — no framework patch is carried.
- **GTK main loop ↔ Swift concurrency.** The transport-Task + frame-marshalling
  integration is the real new engineering; L0's deliverable is precisely to
  prove it with live frames, not synthetic ones.
- **Two viewers during transition.** The SDL CLI was kept as a
  headless/fallback path during bring-up; **now retired** — the GTK viewer is
  the sole Linux/Windows viewer, and `Apps/linux` is a library-only core it
  reuses (the SDL sink, CLI, and `Packages/SDLKit` were removed).
- **Dependency weight in CI.** GTK4 + swift-cross-ui + swift-syntax add build
  time; mitigated by caching and a dedicated job.

## Open decisions (resolved)

- **Package layout:** ~~same package vs. separate~~ → a **separate
  `Apps/linux-gtk` package** (swift-cross-ui + GTK4 shouldn't burden the core's
  `linux-viewer` CI job), reusing `Apps/linux`'s `TailscreenViewerCore` +
  `TailscreenViewerTsnet`.
- **Retire SDL or keep it?** → **retired.** The GTK viewer superseded it.
- **swift-cross-ui pin:** → pinned to an exact revision for reproducibility.
