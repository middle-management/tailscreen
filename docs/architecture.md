---
title: Architecture
nav_order: 4
permalink: /architecture/
---

# Architecture
{: .no_toc }

1. TOC
{:toc}

Tailscreen is small: a few dozen Swift files, one Go-built C archive,
and no external services. Most of the interesting work happens in the video
pipeline; everything else is plumbing.

## The whole picture

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

If you've used a low-latency video stack before, this will look familiar.
If you haven't, the rest of this page is the tour.

## SwiftUI menubar

The app entry point owns the menubar lifecycle and very little else. The
truth — are we sharing, are we connecting, who are the peers, which display
— lives in a single `@MainActor` coordinator.

Every SwiftUI view lives in one file, deliberately: the view code is short
enough that jumping between files would cost more than scrolling.

The native `NSMenu` (File → Disconnect, etc.) is built by hand because some
things SwiftUI's `MenuBarExtra` still doesn't do well in 2026.

The viewer window is a regular `NSWindow`, held for the entire process
lifetime. That's not laziness — releasing it on disconnect raced with
VideoToolbox/Metal teardown and crashed. Holding it is the fix.

## Capture

Capture is a thin wrapper over `ScreenCaptureKit`, running entirely
inside the helper subprocess. We capture at native Retina (2×) at a 60
fps target (cappable via Settings → Quality; the quality knobs travel to
the helper as environment variables at spawn time). The buffers come out
as `CVPixelBuffer`s and go straight into the encoder — no copies, no
Swift heap allocations per frame. The encoder also runs in the helper, so
encoded access units are written directly from the encoder thread to a
framed stdout pipe; the parent process never sees raw pixels. If you're
staring at the encoder wondering why it doesn't make defensive copies,
that's why.

The main process must never touch the ScreenCaptureKit family of APIs.
**Never call `SCShareableContent` from the parent** — that registers the
parent with `replayd`, and the helper child's subsequent `SCStream` then
fails with "application connection being interrupted". The same goes for
presenting the picker: `SCContentSharingPicker` runs in its own
short-lived `--picker-helper` subprocess, which also drives the Screen
Recording TCC prompt on first use, so the parent never preflight-checks
the permission at all.

The helper emits a ~1 Hz **heartbeat** off any delivered SCStream sample
— including the idle frames a completely static screen still produces —
so the parent can tell "healthy but nothing changing" from "SCStream
wedged". A live helper that goes silent for 15 s gets restarted by a
watchdog; an exiting helper gets up to 3 auto-restarts in a 30 s window.
The mid-share "Change Source…" flow rides the same restart path: swap the
cached picker selection, restart the helper, let viewers resync off the
fresh keyframe's in-band parameter sets.

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
- Profile is **HEVC Main** / **H.264 High** at AutoLevel — or **HEVC
  Main 10** when the opt-in 10-bit/HDR path is enabled. Color is chosen
  from the captured display's capability (BT.709 by default, Display P3
  on wide-gamut displays, BT.2020 PQ for HDR) and travels in-band in the
  SPS VUI; the fallback ladder runs Main 10 → 8-bit HEVC → H.264, driven
  by viewer feedback.
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

When decoding starts *failing* (rather than just missing packets), the
viewer runs an escalation ladder instead of dying quietly: request a
keyframe (PLI) → recreate the decompression session → surface a
"connection degraded" badge in the toolbar → raise an actual alert. Each
rung fires once per episode, and a decoded frame resets the ladder. The
UDP receive loops on both ends similarly retry with capped backoff
(250 ms → 5 s) instead of treating the first transient socket error as
fatal.

## Per-viewer send chains and fairness

The sharer encodes **once** and fans the same encoded frame out to every
viewer, rewriting only the RTP header (sequence number, SSRC) per viewer.
But delivery is per-viewer: each viewer gets its own send chain with its
own drop policy, so one viewer on hotel Wi-Fi can't head-of-line-block
the others.

Loss handling starts with attribution: is the loss **isolated** (one
viewer suffering while its peers are fine) or **widespread** (everyone
suffering, i.e. the sharer's uplink)? Widespread loss feeds the global
congestion controller. Isolated loss throttles just the affected viewer
to keyframes-only until it strings together a clean window — and its
numbers are excluded from the global controller's input, so one bad link
can't drag the bitrate down for everyone. The sharer's roster shows this
as a per-viewer health dot: healthy, degraded, or limited-to-keyframes.

## Loss recovery and congestion control

Three cooperating mechanisms, all capability-negotiated so any mix of old
and new peers degrades to plain PLI (the wire details are on the
[protocol page]({% link protocol.md %})):

- **NACK retransmission.** The viewer's `NACKScheduler` watches the
  sequence space, tolerates reordering, and requests exactly the missing
  packets; the sharer answers from a bounded `RetransmitBuffer` of
  recently-sent packets (templates shared across viewers — only header
  bytes differ) under a per-viewer token budget. Gaps that age out or
  blow the budget fall back to PLI.
- **Receiver feedback.** Each viewer reports loss fraction, jitter, and
  an RTT echo about once a second (`RRAccounting` does the bookkeeping on
  the viewer — first-arrivals only, so duplicates and retransmits don't
  distort the numbers). The sharer's congestion controller turns that
  into two levers: the bitrate arm (cut / hold / raise with asymmetric
  hysteresis) and, once bitrate bottoms out, an fps ladder (60 → 30 → 15,
  applied live via the capture helper).
- **XOR FEC.** For viewers whose paths are both lossy *and* long (where a
  retransmit round-trip is genuinely expensive), the sharer interleaves
  one XOR parity packet per group of N media packets (`FECCodec`), sizing
  N 10/7/5 against measured raw loss and compensating the encoder to
  N/(N+1) of the budget so video-plus-parity still fits. The viewer's
  `FECGroupBuffer` repairs any single loss per group with zero additional
  RTT and feeds recovered packets through the same ingest path as
  received ones, so the NACK scheduler and receiver reports stay
  coherent. Multi-loss groups hand off to NACK.

All the decision math — loss attribution, throttle renewal, congestion
bands, fps transitions, FEC gating — is extracted into pure functions
with CI-able unit tests, because the live loops need a real tsnet node,
a real display, and a genuinely bad network to exercise.

## Audio

`VoiceChannel` handles both directions of voice (Opus, mono, 48 kHz)
plus playback of the sharer's **system audio**. Voice is bidirectional
with viewer-to-viewer relay through the sharer. The receive side runs an
adaptive jitter buffer, conceals short sequence gaps instead of glitching,
and puts a failing decoder on a cooldown rather than hammering it.

The codec is Opus — libopus wrapped by the local `OpusKitPackage` — which
replaced the original AudioToolbox AAC-LC path. Royalty-free and
software-only, so the exact same codec ports to Linux and Windows
(see the [porting plan]({% link porting-plan.md %})).

System audio is captured *in the capture helper* (`SCStream` grabs it
with the video via `capturesAudio`, excluding Tailscreen's own output so
viewers' voices never loop back), encoded to Opus, and framed to the
parent over the same stdout pipe as video. On the wire it's a separate
RTP payload type and a reserved SSRC; on the viewer it plays through a
dedicated player node mixed with voice. The mute toggle is an emission
latch in the helper — instant, no capture reconfiguration — re-sent after
every helper respawn so restarts preserve it.

## Remote control

Input injection is the one capture-adjacent feature that deliberately
lives in the **main process**, not a helper: `CGEvent` posting needs
Accessibility permission, not Screen Recording, and has no `replayd`
coupling — so there's no stuck-state failure mode to isolate, and a
helper would just add IPC latency to every mouse move.

The pipeline: the viewer captures local mouse/keyboard in the viewer
window, normalizes coordinates to `[0,1]`, and sends them as framed TCP
input events. The sharer's gate (`RemoteControlPolicy`) admits events
only from the exact connection that holds the grant — one grantee at a
time, identified by server-assigned connection ID, behind an event-rate
ceiling. Admitted events go to `RemoteControlInjector`, which maps
normalized coordinates onto the captured region's live global rect per
share kind (display bounds, window bounds, or the union of a shared app's
window rects — so an app share can't be used to click your Dock),
translates the wire's platform-neutral key model (USB HID usages + a
five-bit modifier set) into mac keycodes and `CGEventFlags` — constructive
translation, so a hostile viewer can't smuggle arbitrary flag bits — and
posts `CGEvent`s from a serial queue. Revocation is TOCTOU-safe: a sealed injector drops anything that
raced the revoke and synthesizes a button-up for any button held
mid-drag, so revoke never leaves a stuck mouse button. Keyboard scope is
whole-Mac by design (see [Security]({% link security.md %}) for why, and
for the grant-time disclosure).

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
original drawer) sees the same annotations through the video stream, with
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
- Request-to-share prompts, including the accept/decline answer sent back
  on the same connection the request arrived on.

## Guardrails

Two pieces of test infrastructure act as protocol guardrails rather than
feature tests, and they're worth knowing about before you touch wire
code:

- **The wire-byte registry.** Every wire constant — TCP message types,
  UDP control bytes, capability bits, helper-IPC types, RTP payload
  types, reserved SSRCs — is pinned in one registry test per channel,
  asserting exact values, exhaustiveness, and uniqueness. Adding a byte
  without a registry row, or renumbering a shipped one, fails CI with a
  message that names the collision.
- **Parser fuzzing.** Every parser that touches peer-controlled bytes
  (the framed TCP parser, RTP depacketizers, UDP control decoders, the
  helper's parameter-set decoder) runs under a deterministic seeded fuzz
  harness — random bytes, truncations, bit flips, length-field mutations
  — on every CI run, with a ~50× longer nightly soak. A failure prints
  its reproducing seed.

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
- **No recording.** Frames go from capture → encoder → wire → decoder →
  screen and are never written to disk. The Tailscale state directory at
  `~/Library/Application Support/Tailscreen/tailscale` holds ephemeral
  node state, and the viewer allow/deny list plus your settings live in
  `UserDefaults`. That's it.
