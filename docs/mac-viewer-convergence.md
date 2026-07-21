---
title: macOS viewer convergence on ViewerSession
nav_order: 11
permalink: /mac-viewer-convergence/
---

# Converging the macOS viewer onto `ViewerSession`

A working plan (not a commitment) for making the macOS app's screen-share
viewer reuse the portable `ViewerSession` (`Packages/TailscreenKit/Sources/
TailscreenViewer/`) as its receive-side **data plane**, instead of the
bespoke logic in `Apps/macOS/Sources/TailscaleScreenShareClient.swift`.

## Why

`ViewerSession` and `TailscaleScreenShareClient` already carry a **near
line-for-line duplicate** of the loss-recovery core: HELLO/HELLO_ACK, NACK,
receiver reports, PLI, and (since the FEC-ingest PR) FEC. Every new
loss-recovery behavior has to be written twice and can drift. `ViewerSession`
is the one that runs under `linux-protocol` / `linux-viewer` CI on every PR.
Converging means: **one tested data-plane implementation**, and the mac
client shrinks to *socket + a `ViewerSession` + the mac-only side channels*.

The payoff is architectural (one implementation, features land once), not a
user-visible feature — so it's a refactor to weigh against near-term work
like the Linux **sharer**.

## What converges vs. what stays mac-side

The key enabler, confirmed by reading the receive path: **`ViewerSession`
never inspects a decoded frame's contents** — it only routes decoder output →
sink and runs bookkeeping.

**Absorbed by `ViewerSession`** (today duplicated in the client): HELLO /
HELLO_ACK, PING / RR, NACK, PLI, FEC, video reassembly, control-byte demux.

**Stays mac-side, arranged _around_ the session** (not inside it): the
annotation TCP channel, the remote-control TCP channel, metadata /
request-to-share (already a wholly separate channel in `AppState`), the
approval UI + the "suppress idle-disconnect while awaiting approval" nuance,
the keepalive task, the idle-disconnect timer, stats-overlay counters, the
codec (`0x07`) / profile (`0x09`) fallbacks, and the decode-recovery
escalation ladder (`VideoDecoder.decodeRecoveryAction`).

The macOS **audio** path (`VoiceChannel`) is far richer than the session's
naive Opus path (per-SSRC jitter buffer, gap concealment, decoder cooldown,
voice/system demux, dual `AVAudioPlayerNode`s), so `ViewerSession` must **not**
own audio decode on mac — see seam 3.

## The three seam changes (Phase A)

### A.1 — Frame opacity ✅ (landed)

Make the decoded video frame **opaque to the session** so a mac
`CVPixelBuffer` can flow decoder → sink without the portable target importing
CoreVideo, and without a per-frame CPU copy that would defeat the zero-copy
VideoToolbox → Metal path.

A `DecodedFrame` marker protocol (requiring only `width` / `height` — what a
generic decorator or the stats overlay needs, cheap for any backing) is the
frame currency. `VideoDecoding.decode` returns `[any DecodedFrame]` and
`VideoSink.present` takes `any DecodedFrame`; the session carries them
untouched. `DecodedVideoFrame` (CPU I420) is the Linux/default instantiation;
a mac `CVPixelBufferBox` will be the zero-copy one. The concrete sink
downcasts to reach pixels; the session and metadata-only decorators never do.

Chosen over genericizing `ViewerSession<D, S>` because `ViewerPipeline` and the
CLI wire the seam through **existentials** already, so the existential marker
adds near-zero ripple; the per-frame boxing cost is negligible at video rates.
Compile-time frame/sink pairing via generics stays open as a later refinement
if wanted.

### A.2 — Async frame delivery (next)

The mac decoder is asynchronous (VideoToolbox decompression → an
`onDecodedFrame: (CVPixelBuffer) -> Void` callback on VT's thread); the
portable `decode(...) -> [frame]` is synchronous. Restructure the seam so a
decoder **emits** frames via a session-provided callback rather than a return
value: `decode(au)` submits, and each ready frame invokes the session's
present path (`sink.present` + post-present bookkeeping). FFmpeg calls it
synchronously inside `decode`; VT calls it from its callback thread — **which
must hop back to the session's single serialization queue** (`ViewerSession`
is not `Sendable`). That hop is the main threading design point. A simpler,
behavior-changing alternative is to drive VT in synchronous mode and keep the
sync return.

### A.3 — Audio passthrough (next)

Add a raw-datagram passthrough so a host can own audio decode: if the host
supplies an `onAudioDatagram` hook, the session forwards PT-98/99 datagrams
(mac → `VoiceChannel.receive`, exactly as `onAudioReceived` does today)
instead of running its internal `OpusVoiceDecoder`. Linux keeps the
`AudioSink` path. Small additive change that preserves the whole mac
`VoiceChannel` resilience layer.

Plus lightweight **observation hooks** (`onPLISent` / `onNACKSent` /
`onFECRecovered` / `onDecodeFailure`) so the mac stats overlay stays fed once
the session owns that emission.

## Adapter design (Phase B)

- **`VTVideoDecoderAdapter: VideoDecoding`** wraps the existing `VideoDecoder`.
  It hides the last mismatches _inside the adapter_: it extracts in-band
  SPS/PPS/VPS from the AU and calls `setParameterSets` before `decode` (so
  param-set install stops being a session concern), and it owns the
  decode-recovery ladder, surfacing a thrown error to the session only when it
  actually wants a PLI. Emits `CVPixelBufferBox` frames via the async callback.
- **`MetalSinkAdapter: VideoSink`** forwards `present(box)` →
  `renderer.setPixelBuffer(box.buffer, receiveUptimeNs:)` (the timestamp the
  stats overlay wants rides the box).
- **Audio**: no adapter — the passthrough hook wires to `VoiceChannel`.

## Migration order

- **Phase A** — the seam refinements above, in the package; update `Apps/linux`
  wiring + tests; Linux CI stays green. No mac change. Self-contained.
- **Phase B** — write + unit-test the mac adapters (no client rewiring yet).
- **Phase C** — add a `ViewerSession`-backed receive path in
  `TailscaleScreenShareClient` **behind a feature flag**, legacy path intact;
  A/B them in dev (frame counts, loss recovery under `scripts/net-impair.sh`,
  stats parity).
- **Phase D** — move keepalive / idle / annotation / stats-feeding to sit
  _around_ the session core; **delete** the duplicated FEC/NACK/RR/PLI from the
  client.
- **Phase E** — flip the flag default, bake, remove the legacy path.

## Risks

- **Zero-copy regression** if the frame seam is wrong → mitigated by the
  opaque `DecodedFrame` (portable code never touches pixels). *(A.1 addresses
  this.)*
- **Threading**: the VT-callback → single-queue session hop (A.2) → mitigated
  by hopping in the adapter to the client's receive queue.
- **Behavior drift**: subtle mac nuances (idle-suppression while awaiting
  approval, PLI throttle, the decode-recovery ladder) must be preserved
  _outside_ the session → mitigated by the flag + A/B comparison and keeping
  those concerns mac-side.
- **Multi-PR effort** with an architectural (not user-facing) payoff — weigh
  against the Linux sharer.
