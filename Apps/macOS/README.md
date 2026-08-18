# Tailscreen (macOS)

The native macOS app — the reference implementation, and the sibling of
`Apps/linux` and `Apps/windows`. SwiftUI (a docked hub window plus a
`MenuBarExtra` sharer tool), ScreenCaptureKit capture, VideoToolbox
encode/decode, Metal render. The portable core all three apps share is
`Packages/TailscreenKit`.

This file covers what is macOS-*specific*. The cross-platform design is on
the published site — [Architecture](https://tailscreen.dev/architecture/)
and [Network Protocol](https://tailscreen.dev/protocol/) — and
`.claude/rules/macos-app.md` carries the same material in denser,
AI-assistant-facing form.

## Process architecture

Capture and encoding live in a separate **helper subprocess** spawned per
share. Process death is the only reliable signal that clears `replayd`'s
per-bundle slot, so isolating `SCStream` + VideoToolbox in a child means
"Stop Sharing" always works — no stuck menubar recording badge. The native
content picker runs in a second short-lived helper for the same defensive
reason.

```
TailscreenApp (@main)
 ├─ Main process
 │   └─ AppState (@MainActor)
 │        ├─ presentNativePicker() ──spawn──▶ picker-helper subprocess
 │        │       (returns the selection as framed JSON on stdout)
 │        ├─ TailscaleScreenShareServer
 │        │    ├─ HelperScreenCapture ──spawn──▶ capture-helper subprocess
 │        │    │     (encoded AUs + system-audio AUs come back over framed stdout)
 │        │    ├─ per-viewer send chains → RTP → UDP/7447
 │        │    │     + RetransmitBuffer / FEC parity / congestion sweep
 │        │    └─ TCP/7447 (annotations, metadata, remote control)
 │        ├─ TailscaleScreenShareClient
 │        │    └─ UDP/7447 → FECGroupBuffer → RTP depacketize → VideoDecoder
 │        │       → MetalViewerRenderer, + NACKScheduler / RRAccounting
 │        │       + TCP/7447 (annotations + input events out)
 │        ├─ RemoteControlInjector ── CGEvent injection (Accessibility TCC)
 │        ├─ VoiceChannel          ── PCM ↔ Opus ↔ RTP, bidi over UDP/7447
 │        ├─ TailscalePeerDiscovery ── LocalAPI + TCP probe
 │        ├─ TailscaleIPNWatcher    ── IPN bus subscription
 │        ├─ TailscaleAuth          ── browser-based login
 │        └─ TailscreenMetadataService ── share name, resolution, request-to-share
 ├─ picker-helper subprocess (short-lived: exits when the user picks)
 │    └─ SCContentSharingPicker
 └─ capture-helper subprocess (lives for one share)
      └─ SCStream (video + optional system audio) → VideoEncoder / Opus → framed stdout
```

The rules that keep it working:

- **The main process must never touch the ScreenCaptureKit family of
  APIs.** Calling `SCShareableContent` from the parent registers the parent
  with `replayd`, and the helper child's subsequent `SCStream` then fails
  with "application connection being interrupted". The picker
  (`SCContentSharingPicker`) runs in its own short-lived `--picker-helper`
  subprocess, which also drives the Screen Recording TCC prompt on first
  use, so the parent never preflight-checks the permission at all.
- **Heartbeat + watchdog.** The helper emits a ~1 Hz heartbeat off any
  delivered SCStream sample — including the idle frames a completely static
  screen still produces — so the parent can tell "healthy but nothing
  changing" from "SCStream wedged". A live helper that goes silent for 15 s
  gets restarted; an exiting helper gets up to 3 auto-restarts in a 30 s
  window. The mid-share "Change Source…" flow rides the same restart path:
  swap the cached picker selection, restart the helper, let viewers resync
  off the fresh keyframe's in-band parameter sets.
- **Zero-copy capture.** We capture at native Retina (2×) at a 60 fps
  target; the quality knobs travel to the helper as environment variables
  at spawn time. Buffers come out of `SCStream` as `CVPixelBuffer`s and go
  straight into the encoder in the same process — no copies, no Swift heap
  allocations per frame — and encoded access units are written from the
  encoder thread to the framed stdout pipe. If you're staring at the
  encoder wondering why it doesn't make defensive copies, that's why.
- **System audio is captured in the helper too** (`SCStream` grabs it with
  the video via `capturesAudio`, excluding Tailscreen's own output so
  viewers' voices never loop back), encoded to Opus, and framed over the
  same stdout pipe as video. The mute toggle is an emission latch in the
  helper — instant, no capture reconfiguration — re-sent after every helper
  respawn so restarts preserve it.

## App shell

The entry point owns two scenes — the docked hub window (sign-in, accounts,
the peer list) and the menubar item that acts as the sharing tool — and
very little else. The truth — are we sharing, are we connecting, who are
the peers, which display — lives in a single `@MainActor` coordinator.

- The native `NSMenu` (File → Disconnect, etc.) is built by hand because
  some things SwiftUI's `MenuBarExtra` still doesn't do well in 2026.
- The viewer window is a regular `NSWindow`, held for the entire process
  lifetime. That's not laziness — releasing it on disconnect raced with
  VideoToolbox/Metal teardown and crashed. Holding it is the fix.
- The annotation overlay is a SwiftUI canvas hosted inside an AppKit
  `NSPanel`: a borderless overlay panel needs to receive keyDown and
  first-mouse events that SwiftUI alone can't reach.

## Remote control

Input injection is the one capture-adjacent feature that deliberately
lives in the **main process**, not a helper: `CGEvent` posting needs
Accessibility permission, not Screen Recording, and has no `replayd`
coupling — so there's no stuck-state failure mode to isolate, and a helper
would just add IPC latency to every mouse move.

`RemoteControlInjector` maps the wire's normalized coordinates onto the
captured region's live global rect per share kind, translates the
platform-neutral key model into mac keycodes and `CGEventFlags`
(`MacKeyCodeMapping` — constructive translation, so a hostile viewer can't
smuggle arbitrary flag bits), and posts `CGEvent`s from a serial queue.
Revocation is TOCTOU-safe: a sealed injector drops anything that raced the
revoke and synthesizes a button-up for any button held mid-drag, so revoke
never leaves a stuck mouse button.

## Swift concurrency conventions

Swift 6 strict concurrency. Some specifics worth knowing if you're
modifying the app:

- Anything that touches UI is `@MainActor`. That includes the central
  coordinator and anywhere an `NSWindow` is constructed.
- Networking classes that handle their own thread safety (the screen-share
  server and client) are `@unchecked Sendable`. We're owning the
  invariants, the compiler isn't checking them.
- `CVPixelBuffer` is **not** `Sendable`. If you need to hop a captured
  frame to `@MainActor` (we do this for preview thumbnails), convert to
  `CGImage` first.
- No `Task { ... self ... }` in `deinit`. The instance is being torn down;
  capturing `self` after `deinit` starts is undefined behavior in Swift.
  Cleanup in `deinit` is synchronous or it doesn't happen.

## Building it

From the repo root, always through `make` (`make build`, `make run`,
`make test`, …) — bare `swift` commands must run from this directory, and
`swift build` fails to link until `make tailscale` has produced
`libtailscale.a`. The rest of the build story is in
[Contributing](https://tailscreen.dev/contributing/).
