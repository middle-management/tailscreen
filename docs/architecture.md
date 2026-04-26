---
title: Architecture
nav_order: 4
permalink: /architecture/
---

# Architecture
{: .no_toc }

1. TOC
{:toc}

## High-level data flow

```
TailscreenApp (@main)
  └─ AppState (@MainActor)
       ├─ TailscaleScreenShareServer
       │    └─ ScreenCapture → VideoEncoder → RTPPacket → UDP/7447 (TailscaleNode.listenPacket)
       │       + TCP/7447 (annotations + metadata)
       ├─ TailscaleScreenShareClient
       │    └─ UDP/7447 → RTP depacketize → VideoDecoder → MetalViewerRenderer
       │       + TCP/7447 (annotations out)
       ├─ TailscalePeerDiscovery   ── LocalAPI + TCP probe
       ├─ TailscaleIPNWatcher      ── IPN bus subscription
       ├─ TailscaleAuth            ── browser-based login
       └─ TailscreenMetadataService ── share name, resolution, request-to-share
```

## Components

### SwiftUI menubar

- `TailscreenApp.swift` — `@main` entry; menubar lifecycle.
- `MenuBarView.swift` — the SwiftUI views (menus, sheets, alerts).
- `AppMenu.swift` — the native `NSMenu` (File → Disconnect, etc.).
- `AppState.swift` — central `@MainActor` coordinator: sharing state,
  connections, peer list, displays.
- `MenuBarExtra` integration keeps the app out of the dock; the viewer is a
  regular `NSWindow` held for the process lifetime.

### Screen capture

- `ScreenCapture.swift` wraps `ScreenCaptureKit`.
- Captures at native Retina resolution (2× scaling) and a 60 FPS target.
- `CVPixelBuffer` outputs are pushed straight into the encoder — no copies,
  no Swift heap allocation per frame.

### Video pipeline

- `VideoEncoder.swift` — VideoToolbox H.264, low-latency profile, no frame
  reordering, ~4 bits per pixel adaptive bitrate, keyframe every ~2 s or on
  PLI from the receiver.
- `RTPPacket.swift` — RFC 3984 packetizer/depacketizer; SPS/PPS sent in-band
  on each keyframe.
- `VideoDecoder.swift` — VideoToolbox H.264 decode.
- `MetalViewerRenderer.swift` — `CAMetalLayer` rendering for the viewer
  window.

### Tailscale integration

- TailscaleKit (a local SwiftPM package wrapping `libtailscale`) provides an
  ephemeral tsnet node with its own state directory.
- `TailscalePeerDiscovery.swift` — enumerates peers via the tsnet LocalAPI
  and parallel-probes TCP/7447 to identify which peers are running
  Tailscreen.
- `TailscaleIPNWatcher.swift` — subscribes to the IPN bus for live
  online/offline events, so the menu reflects peer changes immediately.
- `TailscaleAuth.swift` — tracks login state and triggers the browser-based
  interactive login.

### Annotations / control

- `Annotation.swift` — stroke ops and the `AnnotationOp` data model.
- `DrawingOverlayView.swift` — the viewer-side drawing UI.
- `SharerOverlayWindow.swift` — a transparent `NSWindow` on the sharer's
  Mac that renders inbound annotations.
- `ScreenShareProtocol.swift` — TCP framing for annotation traffic.
- `ViewerCommands.swift`, `ViewerToolbar.swift` — viewer toolbar (brightness,
  magnifier, drawing tools).

### Metadata channel

`TailscreenMetadata.swift` plus `TailscreenMetadataService` exchange:

- The share's display name and resolution.
- Request-to-share prompts (so the sharer can confirm an incoming viewer
  rather than silently accepting connections).

## Concurrency notes

- All UI-touching state is `@MainActor`: `AppState`, `MenuBarView`, and
  anywhere an `NSWindow` is constructed.
- Networking classes that handle their own thread safety are
  `@unchecked Sendable` (`TailscaleScreenShareServer`,
  `TailscaleScreenShareClient`).
- `CVPixelBuffer` is **not** `Sendable`; preview thumbnails are converted to
  `CGImage` before crossing back to `@MainActor`.
- `deinit` does synchronous cleanup only — no `Task { ... self ... }` that
  would capture `self` after deinit starts.

## What's not here

- No iOS / iPadOS support — macOS 15+ only.
- No central relay server. Tailscale's DERP infrastructure is the fallback
  when direct connections aren't possible.
- No recording or persistence — frames are encoded and transmitted in
  real time, never stored.
