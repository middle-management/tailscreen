---
title: Architecture
nav_order: 5
permalink: /architecture/
---

# Architecture
{: .no_toc }

1. TOC
{:toc}

Tailscreen is small: one portable Swift core, three thin native apps, one
Go-built C archive, and no external services. Most of the interesting work
happens in the video pipeline; everything else is plumbing.

## The whole picture

The portable core — `Packages/TailscreenKit`: the wire protocol, the viewer
session, the sharer engine, and every loss-recovery, congestion, and
admission decision — is shared by all three apps, and each platform
supplies only what has to touch the OS:

|  | macOS | Linux | Windows |
| :--- | :--- | :--- | :--- |
| Capture | ScreenCaptureKit | X11 / ScreenCast portal | Windows.Graphics.Capture |
| Encode / decode | VideoToolbox (hardware) | libavcodec (software) | libavcodec (software) |
| Render | Metal | OpenGL (GTK4) | WinUI |
| Audio I/O | AVAudioEngine | ALSA | WASAPI |
| Input injection | CGEvent | XTEST | SendInput |

```
sharer                                       viewer
┌──────────────────────────────┐             ┌──────────────────────────────┐
│ capture → encode  (platform) │             │ decode → render   (platform) │
│    ↓                         │             │    ↑                         │
│ RTP packetize                │  UDP/7447   │ reorder · FEC repair         │
│ per-viewer send chains       │ ──────────▶ │ depacketize                  │
│ retransmit ring · FEC parity │ ◀────────── │ NACK · receiver reports ·    │
│ · congestion      (portable) │             │ PLI               (portable) │
└──────────────┬───────────────┘             └───────────────┬──────────────┘
               └───────────────── TCP/7447 ───────────────────┘
           annotations · remote control · metadata (framed JSON)
```

How each app is put together — process layout, UI shell, capture
specifics — lives with the app:
[`Apps/macOS/README.md`](https://github.com/middle-management/tailscreen/blob/main/Apps/macOS/README.md),
[`Apps/linux/README.md`](https://github.com/middle-management/tailscreen/blob/main/Apps/linux/README.md),
[`Apps/windows/README.md`](https://github.com/middle-management/tailscreen/blob/main/Apps/windows/README.md).
One example worth a sentence here: the macOS app isolates capture and
encoding in a per-share helper subprocess, so a wedged system capture
service can never stick a share — process death is the reliable reset.

If you've used a low-latency video stack before, this will look familiar.
If you haven't, the rest of this page is the tour.

## Capture

Each platform captures with its native engine, and choosing what to share
happens in the platform's native picker (on Wayland, the compositor's own
consent dialog). Frames go from capture to encoder with as little copying
as the platform allows, and the quality knobs — fps cap, preset — apply at
that seam.

## Video encode/decode

The encoder is configured for the lowest latency we can talk it into:

- **HEVC by default, H.264 as a fallback.** The sharer tries to set up an
  HEVC encoder at startup; if the platform refuses (mostly older Intel
  Macs without hardware HEVC), it transparently retries with H.264. The
  viewer doesn't need to know in advance — it picks up the codec from the
  RTP payload type and configures the decoder on the fly.
- Hardware encode on macOS (VideoToolbox — everywhere on Apple Silicon);
  software libavcodec on Linux and Windows today.
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

The decode path is symmetric. It builds its format description from
whichever parameter-set flavor came in on the wire, so the decoder follows
the encoder's choice, and decoded frames feed the platform's renderer.

When decoding starts *failing* (rather than just missing packets), the
viewer runs an escalation ladder instead of dying quietly: request a
keyframe (PLI) → recreate the decoder (the decompression session on
macOS, the libavcodec context on Linux/Windows) → surface a "connection
degraded" badge in the toolbar (macOS) → raise a user-visible stall
error. The ladder's policy lives in the shared core, so all three
viewers escalate identically; each rung fires once per episode, and a
decoded frame resets the ladder. The
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
[protocol page]({{ site.baseurl }}{% link protocol.md %})):

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
  applied live to the capture pipeline).
- **XOR FEC.** For viewers whose paths are both lossy *and* long (where a
  retransmit round-trip is genuinely expensive), the sharer interleaves
  one XOR parity packet per group of N media packets (`FECCodec`), sizing
  N 10/7/5 against measured raw loss and compensating the encoder to
  N/(N+1) of the budget so video-plus-parity still fits. The viewer's
  `FECGroupBuffer` repairs any single loss per group with zero additional
  RTT and feeds recovered packets through the same ingest path as
  received ones, so the NACK scheduler and receiver reports stay
  coherent. Multi-loss groups hand off to NACK.

All the decision math (loss attribution, congestion response, FEC
gating) is extracted into pure functions with unit tests — the live
loops need a real tsnet node and a genuinely bad network to exercise.

## Audio

Voice runs in both directions (Opus, mono, 48 kHz), with viewer-to-viewer
relay through the sharer, alongside the sharer's **system audio**. The
receive side runs an adaptive jitter buffer, conceals short sequence gaps
instead of glitching, and puts a failing decoder on a cooldown rather
than hammering it. All of those decisions live in the portable core
(`VoiceReceiveDecisions`), composed by every platform's audio path, so a
fix lands on all three platforms at once; each host supplies only its own
microphone and speaker.

The codec is Opus (libopus, wrapped by the local `OpusKit`):
royalty-free and software-only, so the exact same codec runs on Linux
and Windows.

System audio — macOS-only today — is captured alongside the video,
excluding Tailscreen's own output so viewers' voices never loop back. On
the wire it's a separate RTP payload type and a reserved SSRC; on the
viewer it plays through a dedicated player node mixed with voice, and
the sharer's mute toggle takes effect instantly.

## Remote control

The viewer captures local mouse/keyboard in the viewer
window, normalizes coordinates to `[0,1]`, and sends them as framed TCP
input events. The sharer's gate (`RemoteControlPolicy`) admits events
only from the exact connection that holds the grant — one grantee at a
time, identified by server-assigned connection ID, behind an event-rate
ceiling. Admitted events go to the platform's injector — `CGEvent` on
macOS, XTEST on Linux, `SendInput` on Windows — which maps normalized
coordinates onto the captured region's live global rect per share kind
(display bounds, window bounds, or the union of a shared app's window
rects — so an app share can't be used to click your Dock or taskbar) and
translates the wire's platform-neutral key model (USB HID usages + a
five-bit modifier set) into native input — constructive
translation, so a hostile viewer can't smuggle arbitrary flag bits.
Revocation is TOCTOU-safe: a sealed injector drops anything that
raced the revoke and synthesizes a button-up for any button held
mid-drag, so revoke never leaves a stuck mouse button. Keyboard scope is
whole-machine by design (see [Security]({{ site.baseurl }}{% link security.md %}) for why, and
for the grant-time disclosure).

## Tailscale integration

This is the part that, if Tailscale didn't exist, we would have written and
hated.

[TailscaleKit](https://github.com/tailscale/libtailscale) is a Swift
wrapper around `libtailscale` (the same C library used by Tailscale's own
embeds), pulled in as a local SwiftPM package so our patches apply on top
of the upstream Swift sources. The patches are small glue; the list is in
[Contributing]({{ site.baseurl }}{% link contributing.md %}#tailscalekit-and-the-patches).

Each Tailscreen session spins up an **ephemeral tsnet node**: a fresh
Tailscale identity that lives only as long as the session. The Tailscale
control plane registers it, hands it a key, and removes it again the
moment Tailscreen closes. Your admin console doesn't fill up with
"Tailscreen-2024-12-15-15-32-44" devices.

Peer discovery enumerates peers via the tsnet LocalAPI and opens TCP/7447
to each in parallel with a short timeout. Anything that accepts and
replies with the Tailscreen handshake gets shown in the **Screens** list.

We also subscribe to the IPN bus so the menu reflects peers coming online
and offline immediately, not after the next discovery sweep.

The sharp edge in the auth flow is that interactive login only works after
a tsnet node is initialized, which means after a share or a connection
has been started at least once. There is no chicken-and-egg fix;
that's just how `libtailscale` works.

## Annotations

The viewer floats a drawing overlay over the video window for local
low-latency feedback; the sharer floats the same overlay over the actual
display, so the captured frames include the strokes — every viewer
(including the original drawer) sees the same annotations through the
video stream, with the local-side overlay just smoothing out latency for
whoever's holding the pen.

The wire format is TCP, framed, JSON-encoded. We use TCP rather than
RTCP-style RTP feedback because losing a stroke segment is worse than the
latency cost of TCP retransmits — the viewer would be drawing on
something the sharer never sees.

## Metadata

The metadata channel exchanges three things over TCP/7447:

- The share's display name (so the **Screens** list says "Mike's
  laptop" rather than `100.83.12.4`).
- The display resolution.
- Request-to-share prompts, including the accept/decline answer sent back
  on the same connection the request arrived on.

## Guardrails

Two test suites guard the protocol itself — know them before touching
wire code:

- **The wire-byte registry.** Every wire constant is pinned in a registry
  test: exact value, exhaustiveness, uniqueness. A new byte needs a
  registry row in the same commit; a shipped byte is never renumbered.
- **Parser fuzzing.** Every parser that reads peer-controlled bytes runs
  under a deterministic seeded fuzz harness on each CI run, with a longer
  nightly soak. A failure prints its reproducing seed.

## What's not here

- **No iOS, no iPadOS.** Desktop only — macOS 15+, Linux, and Windows.
  ScreenCaptureKit on iOS is a different beast, and we're not going there.
- **No central relay.** Tailscale's DERP is the only fallback when direct
  P2P fails. Even DERP traffic is end-to-end encrypted; the relay only
  sees ciphertext.
- **No recording.** Frames go from capture → encoder → wire → decoder →
  screen and are never written to disk. The Tailscale state directory
  (`~/Library/Application Support/Tailscreen/tailscale` on macOS,
  `~/.config/tailscreen` on Linux) holds ephemeral node state, and the
  viewer allow/deny list plus your settings live in `UserDefaults` (or the
  platform equivalent). That's it.
