---
title: Architecture
nav_order: 4
permalink: /architecture/
---

# Architecture
{: .no_toc }

1. TOC
{:toc}

Tailscreen is small: a couple of dozen Swift files, one Go-built C archive,
and no external services. Most of the interesting work happens in the video
pipeline; everything else is plumbing.

## The whole picture

Capture and encoding live in a separate **helper subprocess** spawned per
share. Process death is the only reliable signal that clears `replayd`'s
per-bundle slot, so isolating `SCStream` + VideoToolbox in a child means
"Stop Sharing" always works — no stuck menubar recording badge.

```
TailscreenApp (@main)
 ├─ Main process
 │   └─ AppState (@MainActor)
 │        ├─ TailscaleScreenShareServer
 │        │    ├─ HelperScreenCapture ──spawn──▶ capture-helper subprocess
 │        │    │     (encoded AUs come back over framed stdout)
 │        │    └─ RTPPacket → UDP/7447
 │        │       + TCP/7447 (annotations + metadata)
 │        ├─ TailscaleScreenShareClient
 │        │    └─ UDP/7447 → RTP depacketize → VideoDecoder → MetalViewerRenderer
 │        │       + TCP/7447 (annotations out)
 │        ├─ VoiceChannel          ── PCM ↔ AAC ↔ RTP, bidi over UDP/7447
 │        ├─ TailscalePeerDiscovery ── LocalAPI + TCP probe
 │        ├─ TailscaleIPNWatcher    ── IPN bus subscription
 │        ├─ TailscaleAuth          ── browser-based login
 │        └─ TailscreenMetadataService ── share name, resolution, request-to-share
 └─ capture-helper subprocess
      └─ SCStream → VideoEncoder → framed wire → stdout
```

If you've used a low-latency video stack before, this will look familiar.
If you haven't, the rest of this page is the tour.

## SwiftUI menubar

The app entry point owns the menubar lifecycle and very little else. The
truth — are we sharing, are we connecting, who are the peers, which display
— lives in a single `@MainActor` coordinator.

There is *one* file holding every SwiftUI view in the app. We deliberately
did not split it into one-file-per-view; the view code is short enough that
the cognitive cost of jumping between files would outweigh the cost of
scrolling.

The native `NSMenu` (File → Disconnect, etc.) is built by hand because some
things SwiftUI's `MenuBarExtra` still doesn't do well in 2026.

The viewer window is a regular `NSWindow` and we hold it for the entire
process lifetime. That's not laziness — releasing it on disconnect raced
with VideoToolbox/Metal teardown in autoreleasepool and crashed. Holding
the window is the fix.

## Capture

Capture is a thin wrapper over `ScreenCaptureKit`, running entirely
inside the helper subprocess. We capture at native Retina (2×) at a 60
fps target. The buffers come out as `CVPixelBuffer`s and go straight into
the encoder — no copies, no Swift heap allocations per frame. The
encoder also runs in the helper, so encoded access units are written
directly from the encoder thread to a framed stdout pipe; the parent
process never sees raw pixels. If you're staring at the encoder
wondering why it doesn't make defensive copies, that's why.

The main process probes display permission with
`CGPreflightScreenCaptureAccess` and enumerates displays from `NSScreen`.
**It must never call `SCShareableContent`** — that registers the parent
with `replayd`, and the helper child's subsequent `SCStream` then fails
with "application connection being interrupted".

## Video encode/decode

VideoToolbox configured for the lowest latency we can talk it into:

- **HEVC by default, H.264 as a fallback.** The sharer tries to set up a
  hardware HEVC encoder at startup; if VideoToolbox refuses (mostly older
  Intel Macs without HW HEVC), it transparently retries with H.264. The
  viewer doesn't need to know in advance — it picks up the codec from the
  RTP payload type and configures the decoder on the fly.
- Hardware encoder where available (everywhere on Apple Silicon).
- Frame reordering disabled. No B-frames. Each frame depends only on
  earlier frames, which means a packet loss can't strand future frames
  waiting for a frame from the past.
- Adaptive bitrate based on resolution and a bits-per-pixel target. The
  defaults are **0.06 bpp for HEVC** and **0.10 bpp for H.264** — HEVC's
  intra-prediction modes earn back roughly 30% on screen content vs H.264,
  so the same visual quality gets a smaller bitrate budget.
- Profile is **HEVC Main** / **H.264 High** at AutoLevel.
- Keyframe roughly every 2 seconds, or earlier when the receiver sends a
  PLI (Picture Loss Indication).

RTP packetization follows RFC 6184 (H.264) and RFC 7798 (HEVC). It knows
about FU-A fragmentation, STAP-A aggregation, and the codec's parameter
sets. Parameter sets go in-band on every keyframe — **SPS+PPS** for H.264,
**VPS+SPS+PPS** for HEVC — so a viewer that connects partway through can
spin up a decoder without an out-of-band handshake.

The decode path is the symmetric VideoToolbox side. It builds its
`CMFormatDescription` from whichever parameter-set flavor came in on the
wire, so the decoder follows the encoder's choice. The decoded
`CVPixelBuffer`s feed straight into a `CAMetalLayer` for the actual blit.

## Tailscale integration

This is the part that, if Tailscale didn't exist, we would have written and
hated.

[TailscaleKit](https://github.com/tailscale/libtailscale) is a Swift
wrapper around `libtailscale` (the same C library used by Tailscale's own
embeds). We pull it in as a local SwiftPM package at
`./TailscaleKitPackage/` so we can apply our patches on top of the upstream
Swift sources. The patches are all small — things like a `Foundation`
import, glue imports for the C bridge, `send`/`receive` on connections, a
public `logout`, listener poll-timeout handling, and our `tsnet
ListenPacket` Swift wrapper for the UDP video path. They live in
`TailscaleKitPackage/Patches/`.

Each Tailscreen session spins up an **ephemeral tsnet node**: a fresh
Tailscale identity that lives only as long as the session. The Tailscale
control plane registers it, hands it a key, and removes it again the
moment Tailscreen closes. Your admin console doesn't fill up with
"Tailscreen-2024-12-15-15-32-44" devices.

Peer discovery enumerates peers via the tsnet LocalAPI and opens TCP/7447
to each in parallel with a short timeout. Anything that accepts and
replies with the Tailscreen handshake gets shown in **Browse Shares**.

We also subscribe to the IPN bus so the menu reflects peers coming online
and offline immediately, not after the next discovery sweep.

The sharp edge in the auth flow is that interactive login only works after
a tsnet node is initialized, which means after `Start Sharing` or `Connect
to...` has been clicked at least once. There is no chicken-and-egg fix;
that's just how `libtailscale` works.

## Annotations

The drawing UI is a SwiftUI canvas hosted inside an AppKit `NSPanel`. The
AppKit wrapper exists because a borderless overlay panel needs to receive
keyDown and first-mouse events that SwiftUI alone can't reach. The viewer
floats this overlay over the video window for local low-latency feedback;
the sharer floats the same overlay over the actual display, so the
captured frames include the strokes — every viewer (including the
original drawer) sees the same annotations through the H.264 stream, with
the local-side overlay just smoothing out latency for whoever's holding
the pen.

The wire format is TCP, framed, JSON-encoded. We use TCP rather than
RTCP-style RTP feedback because losing a stroke segment is worse than the
latency cost of TCP retransmits — the viewer would be drawing on
something the sharer never sees.

## Metadata

The metadata channel exchanges three things over TCP/7447:

- The share's display name (so the **Browse Shares** list says "Mike's
  laptop" rather than `100.83.12.4`).
- The display resolution.
- Request-to-share prompts. The sharer can require manual confirmation
  before any video is sent, so a Mac that's left "sharing" all day doesn't
  silently start streaming the moment a peer connects.

## Concurrency

Swift 6 strict concurrency. Some specifics worth knowing if you're
modifying:

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
