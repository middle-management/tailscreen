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
Go-built C archive, no external services. Most of the interesting work is in
the video pipeline; everything else is plumbing.

## The whole picture

The portable core — `Packages/TailscreenKit`: the wire protocol, the viewer
session, the sharer engine, and every loss-recovery, congestion, and
admission decision — is shared by all three apps, and each platform
supplies only what has to touch the OS:

|  | macOS | Linux | Windows | Browser (viewing only) |
| :--- | :--- | :--- | :--- | :--- |
| Capture | ScreenCaptureKit | X11 / ScreenCast portal | Windows.Graphics.Capture | — |
| Encode / decode | VideoToolbox (hardware) | libavcodec (software) | libavcodec (software) | WebCodecs (decode; the browser's own decoders) |
| Render | Metal | OpenGL (GTK4) | WinUI | Canvas 2D |
| Audio I/O | AVAudioEngine | ALSA | WASAPI | Web Audio (output only) |
| Input injection | CGEvent | XTEST | SendInput | — |

The fourth column is a page, not an app: the same portable core, this time
the public Go SDK compiled to WebAssembly, behind the browser's decoders and
a canvas. It only views, only as a guest, and — because a browser has no
UDP — its whole datagram plane rides the TCP line below as `mediaDatagram`
frames (the [stream
profile]({{ site.baseurl }}{% link protocol.md %}#stream-carriage--the-reliable-transport-profile-0x0d)).

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

The encoder is configured for the lowest latency we can talk it into.
Codec choice, parameter-set placement, and color handling are wire-level
concerns covered on the [protocol page]({{ site.baseurl }}{% link protocol.md %}#video--udp-rtp);
the pipeline-level defaults:

- Hardware encode on macOS (VideoToolbox — everywhere on Apple Silicon);
  software libavcodec on Linux and Windows today.
- Frame reordering disabled, no B-frames — each frame depends only on
  earlier ones, so a packet loss can't strand future frames waiting on a
  frame from the past.
- Adaptive bitrate based on resolution and a bits-per-pixel target: **0.06
  bpp for HEVC**, **0.10 bpp for H.264** (HEVC earns back roughly 30% on
  screen content, so the same visual quality needs a smaller budget).
- Profile is **HEVC Main** / **H.264 High** at AutoLevel, or **HEVC Main
  10** on the opt-in 10-bit/HDR path; the fallback ladder runs Main 10 →
  8-bit HEVC → H.264, driven by viewer feedback.
- Keyframe roughly every 2 seconds, or earlier on a receiver PLI.

RTP packetization follows RFC 6184 (H.264) and RFC 7798 (HEVC), including
FU-A fragmentation and STAP-A aggregation. The decode path is symmetric: it
builds its format description from whichever parameter-set flavor came in
on the wire, so the decoder follows the encoder's choice.

When decoding starts *failing* (rather than just missing packets), the
viewer runs an escalation ladder instead of dying quietly: request a
keyframe (PLI) → recreate the decoder (the decompression session on macOS,
the libavcodec context on Linux/Windows) → surface a "connection degraded"
badge in the toolbar (macOS) → raise a user-visible stall error. The
ladder's policy lives in the shared core, so all three viewers escalate
identically; each rung fires once per episode, and a decoded frame resets
the ladder. UDP receive loops on both ends similarly retry with capped
backoff (250 ms → 5 s) instead of treating the first transient socket error
as fatal.

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
and new peers degrades to plain PLI (wire details on the
[protocol page]({{ site.baseurl }}{% link protocol.md %})):

- **NACK retransmission.** The viewer's `NACKScheduler` watches the
  sequence space, tolerates reordering, and requests exactly the missing
  packets; the sharer answers from a bounded `RetransmitBuffer` of
  recently-sent packets (templates shared across viewers — only header
  bytes differ) under a per-viewer token budget. Gaps that age out or blow
  the budget fall back to PLI.
- **Receiver feedback.** Each viewer reports loss fraction, jitter, and an
  RTT echo about once a second (`RRAccounting` on the viewer counts
  first-arrivals only, so retransmits don't distort the numbers). The
  sharer's congestion controller turns that into two levers: the bitrate
  arm (cut / hold / raise with asymmetric hysteresis) and, once bitrate
  bottoms out, an fps ladder (60 → 30 → 15) applied live to the capture
  pipeline.
- **XOR FEC.** For viewers whose paths are both lossy *and* long (where a
  retransmit round-trip is genuinely expensive), the sharer interleaves one
  XOR parity packet per group of N media packets (`FECCodec`), sizing N
  10/7/5 against measured raw loss and compensating the encoder to N/(N+1)
  of the budget so video-plus-parity still fits. The viewer's
  `FECGroupBuffer` repairs any single loss per group with zero extra RTT
  and feeds recovered packets through the same ingest path as received
  ones, so NACK and receiver reports stay coherent. Multi-loss groups hand
  off to NACK.

All the decision math (loss attribution, congestion response, FEC
gating) is extracted into pure functions with unit tests — the live
loops need a real tsnet node and a genuinely bad network to exercise.

## Audio

Voice runs in both directions (Opus, mono, 48 kHz), with viewer-to-viewer
relay through the sharer, alongside the sharer's **system audio**. The
receive side runs an adaptive jitter buffer, conceals short sequence gaps
instead of glitching, puts a failing decoder on a cooldown rather than
hammering it, and sums voices that fall in the same 20 ms slot into one
frame before they reach the single playback queue every host has — a queue
plays what it's given in turn, so separate voices would interleave rather
than mix. All of this lives in the portable core (`VoiceReceiveDecisions`),
composed by every platform's audio path, so a fix lands on all three at
once; each host supplies only its own microphone and speaker.

The codec is Opus (libopus, wrapped by the local `OpusKit`): royalty-free
and software-only, so the exact same codec runs on Linux and Windows.

System audio — macOS-only today — is captured alongside the video,
excluding Tailscreen's own output so viewers' voices never loop back. On
the wire it's a separate RTP payload type and a reserved SSRC; on the
viewer it plays through a dedicated player node mixed with voice, and
the sharer's mute toggle takes effect instantly.

## Remote control

The viewer captures local mouse/keyboard in the viewer window, normalizes
coordinates to `[0,1]`, and sends them as framed TCP input events. The
sharer's gate (`RemoteControlPolicy`) admits events only from the exact
connection holding the grant — one grantee at a time, identified by
server-assigned connection ID, behind an event-rate ceiling. Admitted
events go to the platform's injector — `CGEvent` on macOS, XTEST on Linux,
`SendInput` on Windows — which maps normalized coordinates onto the
captured region's live global rect per share kind (display bounds, window
bounds, or the union of a shared app's window rects, so an app share can't
be used to click your Dock or taskbar) and translates the wire's
platform-neutral key model (USB HID usages + a five-bit modifier set) into
native input — constructive translation, so a hostile viewer can't smuggle
arbitrary flag bits. Revocation is TOCTOU-safe: a sealed injector drops
anything that raced the revoke and synthesizes a button-up for any button
held mid-drag, so revoke never leaves a stuck mouse button. Keyboard scope
is whole-machine by design (see
[Security]({{ site.baseurl }}{% link security.md %}) for why, and for the
grant-time disclosure).

## Tailscale integration

[TailscaleKit](https://github.com/middle-management/libtailscale) is a
Swift wrapper around `libtailscale` (the same C library used by Tailscale's
own embeds), pulled in as a local SwiftPM package whose submodule points at
our fork — upstream history with our changes as ordinary commits on top.
The commits are small glue plus the guest-tunnel surface; the story is in
[Contributing]({{ site.baseurl }}{% link contributing.md %}#tailscalekit-and-the-fork).

Each Tailscreen session spins up an **ephemeral tsnet node**: a fresh
Tailscale identity that lives only as long as the session. The control
plane registers it, hands it a key, and removes it again the moment
Tailscreen closes — your admin console doesn't fill up with
"Tailscreen-2024-12-15-15-32-44" devices.

Peer discovery enumerates peers via the tsnet LocalAPI and opens TCP/7447
to each in parallel with a short timeout; anything that accepts and replies
with the Tailscreen handshake shows up in the **Screens** list. We also
subscribe to the IPN bus so the menu reflects peers coming online and
offline immediately, not after the next discovery sweep.

The sharp edge in the auth flow: interactive login only works after a tsnet
node is initialized, i.e. after a share or a connection has been started
at least once. There is no chicken-and-egg fix; that's just how
`libtailscale` works.

### Guests: the share-by-token tunnel

**Share via Link** carries the same protocol to people who aren't on the
tailnet at all. Flipping it on mints a fresh WireGuard key pair for the
share and encodes its public key plus DERP bootstrap details into an opaque
token (`tc…`, wrapped in a `tailscreen:` link). A guest holding the token
reaches the sharer through the named relay, completes an authenticated
handshake, and from there it's ordinary WireGuard — direct when NAT
traversal permits, relayed ciphertext when not. Both channels of port 7447
run over that tunnel unchanged: the sharer binds a second UDP listener and
a second framed-TCP listener on the guest node beside the tailnet ones, and
everything downstream — RTP fan-out, loss recovery, annotations, remote
control — treats a guest connection like any other.

What differs is admission, not transport. A guest's identity is its
WireGuard node key (there's no Tailscale identity to look up), approval is
mandatory on every join — the remembered-allow store, open-door mode, and
ask-to-share pre-approval don't apply — and denying a guest also evicts its
key at the tunnel for the life of the link. The key pair is never
persisted: stop sharing, press New Link, or flip the toggle off, and every
outstanding copy of the link is dead. A share can even run **link-only** —
started signed out on any of the three apps, no tsnet node at all, the
guest tunnel as its only transport (`SharerLinkSession.startLinkOnly` over
`TailscaleScreenShareServer`'s `startGuestOnly`, which is why the
swift-cross-ui hosts took one parameter each to gain it).

**A browser is a guest too.** The web form of a share link
(`https://tailscreen.dev/view/#tc…`) opens a static page carrying the
fork's `guest` client and the protocol SDK compiled to WebAssembly. It
reaches the relay over a WebSocket — the only socket a browser has — so its
WireGuard tunnel is always relayed and never upgrades to a direct path,
and everything inside it is carried reliably regardless of shape. That's
exactly the case the [stream
profile]({{ site.baseurl }}{% link protocol.md %}#stream-carriage--the-reliable-transport-profile-0x0d)
exists for, so the page uses nothing else; from admission onward it's an
ordinary guest — mandatory approval every join, identity by key, the same
drawing and remote-control gates. Decoding is WebCodecs (H.264 everywhere
the browser ships a decoder, falling back when HEVC is unsupported) and
audio is Web Audio behind the click browsers insist on.

## Annotations

The viewer floats a drawing overlay over the video window for local
low-latency feedback; the sharer floats the same overlay over the actual
display, so captured frames include the strokes — every viewer (including
the original drawer) sees the same annotations through the video stream,
with the local-side overlay just smoothing out latency for whoever's
holding the pen. Wire format and the TCP-over-RTP-feedback rationale are on
the [protocol page]({{ site.baseurl }}{% link protocol.md %}#annotations--control--tcp).

## Metadata

The metadata channel exchanges three things over TCP/7447: the share's
display name (so the **Screens** list says "Mike's laptop" rather than
`100.83.12.4`), the display resolution, and request-to-share prompts,
including the accept/decline answer sent back on the same connection the
request arrived on.

## Guardrails

Two test suites guard the protocol itself — know them before touching wire
code:

- **The wire-byte registry.** Every wire constant is pinned in a registry
  test: exact value, exhaustiveness, uniqueness. A new byte needs a
  registry row in the same commit; a shipped byte is never renumbered.
- **Parser fuzzing.** Every parser that reads peer-controlled bytes runs
  under a deterministic seeded fuzz harness each CI run, with a longer
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
