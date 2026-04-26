---
title: Architecture
nav_order: 4
permalink: /architecture/
---

# Architecture
{: .no_toc }

1. TOC
{:toc}

Tailscreen is small. Twenty-six Swift files, one Go-built C archive, no
external services. Most of the interesting work happens in the video
pipeline; everything else is plumbing.

## The whole picture

```
TailscreenApp (@main)
  └─ AppState (@MainActor)
       ├─ TailscaleScreenShareServer
       │    └─ ScreenCapture → VideoEncoder → RTPPacket → UDP/7447
       │       + TCP/7447 (annotations + metadata)
       ├─ TailscaleScreenShareClient
       │    └─ UDP/7447 → RTP depacketize → VideoDecoder → MetalViewerRenderer
       │       + TCP/7447 (annotations out)
       ├─ TailscalePeerDiscovery   ── LocalAPI + TCP probe
       ├─ TailscaleIPNWatcher      ── IPN bus subscription
       ├─ TailscaleAuth            ── browser-based login
       └─ TailscreenMetadataService ── share name, resolution, request-to-share
```

If you've used a low-latency video stack before, this will look familiar.
If you haven't, the rest of this page is the tour.

## SwiftUI menubar

`TailscreenApp.swift` is the `@main` entry point. It owns the menubar
lifecycle and not much else. The actual coordinator is `AppState.swift`,
which is `@MainActor` and holds the truth: are we sharing, are we
connecting, who are the peers, which display.

`MenuBarView.swift` is where every SwiftUI view in the app lives. We
deliberately did not split it into one-file-per-view; the view code is
short enough that the cognitive cost of jumping between files would
outweigh the cost of scrolling.

`AppMenu.swift` builds the native `NSMenu` (File → Disconnect, etc.)
because some things SwiftUI's `MenuBarExtra` still doesn't do well in 2026.

The viewer window is a regular `NSWindow` and we hold it for the entire
process lifetime. That's not laziness — releasing it on disconnect raced
with VideoToolbox/Metal teardown in autoreleasepool and crashed. Holding
the window is the fix.

## Capture

`ScreenCapture.swift` is a thin wrapper over `ScreenCaptureKit`. We
capture at native Retina (2×) at a 60 fps target. The buffers come out as
`CVPixelBuffer`s and go straight into the encoder — no copies, no Swift
heap allocations per frame. If you're staring at the encoder wondering why
it doesn't make defensive copies, that's why.

## Video encode/decode

`VideoEncoder.swift` is VideoToolbox configured for the lowest latency we
can talk it into:

- Hardware encoder where available (everywhere on Apple Silicon).
- Frame reordering disabled. No B-frames. Each frame depends only on
  earlier frames, which means a packet loss can't strand future frames
  waiting for a frame from the past.
- ~4 bits per pixel adaptive bitrate, scaled by resolution.
- Keyframe roughly every 2 seconds, or earlier when the receiver sends a
  PLI (Picture Loss Indication).

`RTPPacket.swift` does packetize and depacketize per RFC 3984 — it knows
about FU-A fragmentation, STAP-A aggregation, and SPS/PPS parameter sets.
SPS/PPS go in-band on every keyframe so a viewer that connects partway
through can sync without an out-of-band handshake.

`VideoDecoder.swift` is the symmetric VideoToolbox decode path. The decoded
`CVPixelBuffer`s feed straight into `MetalViewerRenderer.swift`, which uses
a `CAMetalLayer` for the actual blit.

## Tailscale integration

This is the part that, if Tailscale didn't exist, we would have written and
hated.

[TailscaleKit](https://github.com/tailscale/libtailscale) is a Swift
wrapper around `libtailscale` (the same C library used by Tailscale's own
embeds). We pull it in as a local SwiftPM package at
`./TailscaleKitPackage/` so we can apply our patches on top of the upstream
Swift sources. (We have 16 patches at last count. They're all small. They
add things like a `Foundation` import, glue imports for the C bridge,
`send`/`receive` on connections, a public `logout`, listener poll-timeout
handling, and our `tsnet ListenPacket` Swift wrapper for the UDP video
path. The patches live in `TailscaleKitPackage/Patches/`.)

Each Tailscreen session spins up an **ephemeral tsnet node**: a fresh
Tailscale identity that lives only as long as the session. The Tailscale
control plane registers it, hands it a key, and removes it again the
moment Tailscreen closes. Your admin console doesn't fill up with
"Tailscreen-2024-12-15-15-32-44" devices.

`TailscalePeerDiscovery.swift` enumerates peers via the tsnet LocalAPI and
opens TCP/7447 to each in parallel with a short timeout. Anything that
accepts and replies with the Tailscreen handshake gets shown in **Browse
Shares**.

`TailscaleIPNWatcher.swift` subscribes to the IPN bus so the menu reflects
peers coming online and offline immediately, not after the next discovery
sweep.

`TailscaleAuth.swift` handles the browser-based login. The sharp edge here
is that interactive login only works after a tsnet node is initialized,
which means after `Start Sharing` or `Connect to...` has been clicked at
least once. There is no chicken-and-egg fix; that's just how `libtailscale`
works.

## Annotations

`Annotation.swift` defines the data model — strokes, colors, op types.
`DrawingOverlayView.swift` is the viewer-side drawing UI;
`SharerOverlayWindow.swift` is the transparent `NSWindow` on the sharer's
machine that the strokes get rendered into.

The wire format is in `ScreenShareProtocol.swift`. It's TCP, framed,
JSON-encoded. We use TCP rather than RTCP-style RTP feedback because losing
a stroke segment is worse than the latency cost of TCP retransmits — the
viewer would be drawing on something the sharer never sees.

## Metadata

`TailscreenMetadata.swift` and the in-process `TailscreenMetadataService`
exchange three things over TCP/7447:

- The share's display name (so the **Browse Shares** list says "Mike's
  laptop" rather than `100.83.12.4`).
- The display resolution.
- Request-to-share prompts. The sharer can require manual confirmation
  before any video is sent, so a Mac that's left "sharing" all day doesn't
  silently start streaming the moment a peer connects.

## Concurrency

Swift 6 strict concurrency. Some specifics worth knowing if you're
modifying:

- Anything that touches UI is `@MainActor`. That includes `AppState`,
  `MenuBarView`, and anywhere an `NSWindow` is constructed.
- Networking classes that handle their own thread safety (the screen-share
  server and client) are `@unchecked Sendable`. We're owning the
  invariants, the compiler isn't checking them.
- `CVPixelBuffer` is **not** `Sendable`. If you need to hop a captured
  frame to `@MainActor` (we do this for preview thumbnails), convert to
  `CGImage` first.
- No `Task { ... self ... }` in `deinit`. The instance is being torn down;
  capturing `self` after `deinit` starts is undefined behavior in Swift.
  Cleanup in `deinit` is synchronous or it doesn't happen.

## What's not here

- **No iOS, no iPadOS.** macOS 15+ only. ScreenCaptureKit on iOS is a
  different beast, and we're not going there.
- **No central relay.** Tailscale's DERP is the only fallback when direct
  P2P fails. Even DERP traffic is end-to-end encrypted; the relay only
  sees ciphertext.
- **No recording.** Frames go from camera → encoder → wire → decoder →
  screen and are never written to disk. The Tailscale state directory at
  `~/Library/Application Support/Tailscreen/tailscale` holds ephemeral
  node state and that's it.
