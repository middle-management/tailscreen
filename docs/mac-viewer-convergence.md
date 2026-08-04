---
title: macOS viewer convergence on ViewerSession
nav_order: 12
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

### A.2 — Async frame delivery ✅ (landed)

The mac decoder is asynchronous (VideoToolbox decompression → an
`onDecodedFrame: (CVPixelBuffer) -> Void` callback on VT's thread); the
portable `decode(...) -> [frame]` was synchronous. The seam now has a decoder
**emit** frames via callbacks rather than return them: `VideoDecoding` gains
`onDecodedFrame` / `onDecodeFailure` and `decode(...)` returns `Void` (submit).
`ViewerSession` wires those in `init` — a decoded frame goes straight to the
sink, a failure to a PLI — so `decode` is now just a submit. FFmpeg fires the
callback synchronously inside `decode` (satisfying the threading contract for
free); VideoToolbox will fire it later, and the **adapter must hop back to the
host's serialization context** before invoking it, because `ViewerSession` is
not `Sendable` and owns no queue — that contract is documented on the protocol.
Covered by a synchronous-stub path plus an explicit async-delivery test (a
stub that defers frames past `decode` and delivers on a later poke).

### A.3 — Audio passthrough ✅ (landed)

`ViewerSession.init` gained an optional `onAudioDatagram` hook: when set,
inbound audio RTP (PT 98/99) is forwarded to the host **verbatim** and the
built-in `AudioRTPDepacketizer` + `OpusVoiceDecoder` path is skipped, so a
host with its own richer audio pipeline (macOS's `VoiceChannel` — per-SSRC
jitter buffer, concealment, voice/system demux, dual `AVAudioPlayerNode`s)
owns decode, exactly as the mac client's `onAudioReceived` → `VoiceChannel`
does today. nil (the default) keeps the built-in `AudioSink` path, so Linux
is unchanged. Covered by a passthrough test (a real PT-98 datagram is
forwarded byte-for-byte and the built-in path stays silent).

### A.4 — Observation hooks ✅ (landed)

Lightweight `onPLISent` / `onNACKSent` / `onFECRecovered` callbacks on
`ViewerSession` so the mac stats overlay stays fed once the session owns loss-
recovery emission: they fire alongside every emitted PLI/NACK and each
FEC-recovered packet. The mac client wires them to the renderer's
`notePLISent` / `noteNACKSent` / `noteFECRecovered` counters in
`buildViewerSession`; received-bytes/codec accounting rides a small
`noteReceivedVideoStats` helper in the receive loop (the session treats frames
as opaque, so byte/codec accounting stays host-side). Covered by hook tests in
`ViewerSessionTests`.

## Adapter design (Phase B — in progress)

Landed in `Apps/macOS/Sources/ViewerSessionAdapters.swift` (not yet wired into
the client — that's Phase C):

- **`CVPixelBufferBox: DecodedFrame`** — the mac frame currency. Holds the
  VideoToolbox `CVPixelBuffer` (IOSurface-backed, Metal-compatible) so the
  zero-copy path survives routing through `ViewerSession`; `width`/`height`
  come from `CVPixelBufferGetWidth/Height`.
- **`VTVideoDecoderAdapter: VideoDecoding`** wraps the existing `VideoDecoder`.
  It hides two mismatches _inside the adapter_: it extracts in-band SPS/PPS/VPS
  from each keyframe and calls `setParameterSets` before `decode` (so param-set
  install stops being a session concern), and it bridges VideoToolbox's
  asynchronous `CVPixelBuffer` callback to the session's `onDecodedFrame` — with
  the **thread hop** onto a host-supplied `callbackQueue` (the receive queue)
  the threading contract requires. Emits `CVPixelBufferBox`. It also exposes
  mac-only pass-through hooks (`onCodecUnsupported`, `onFrameDecodeFailed`,
  `onRecoveryAction`, `onRecovered`) that bypass `ViewerSession` and carry the
  full CODEC_NO H.264 fallback + decode-recovery ladder to the client, so a
  session-build failure drives the codec fallback (not a plain PLI) — parity
  with the legacy loop.
- **`MetalSinkAdapter: VideoSink`** forwards `present(box)` →
  `renderer.setPixelBuffer(box.buffer, receiveUptimeNs:)` (the timestamp the
  stats overlay wants rides on the box).
- **Audio**: no adapter — the A.3 passthrough hook wires to `VoiceChannel`.

Unit-tested by `ViewerSessionAdapterTests` (parameter-set extraction for
H.264/HEVC incl. the missing-set nil, and `CVPixelBufferBox` dimensions); the
live VT-decode + Metal path rides the existing on-CI
`ScreenShareSyntheticFramesTests`. These are macOS-only and verified by the
mac `build`/`test` CI job, not the Linux loop.

## Migration order

- **Phase A** — the seam refinements above, in the package; update `Packages/TailscreenLinuxBackends`
  wiring + tests; Linux CI stays green. No mac change. Self-contained.
- **Phase B** — write + unit-test the mac adapters (no client rewiring yet).
- **Phase C** — add a `ViewerSession`-backed receive path in
  `TailscaleScreenShareClient` **behind a feature flag**, legacy path intact;
  A/B them in dev (frame counts, loss recovery under `scripts/net-impair.sh`,
  stats parity). *First cut landed* (`TAILSCREEN_VIEWER_SESSION=1`): a
  `buildViewerSession` factory wires the adapters + `onAudioDatagram` →
  `VoiceChannel` + `onControlToSend` → UDP, and `receiveLoopViaViewerSession`
  routes datagrams to `ViewerSession.receiveRTP`/`tick` and translates the
  session's negotiated state (SSRC + caps, pending/denied/stopped) into the
  existing client callbacks. Default off; the legacy loop is untouched. This
  path is **compile-verified on CI only** — its runtime correctness needs a
  local A/B on a Mac (validated once under `net-impair.sh`). *Reach-parity
  landed:* the stats overlay is now fed (received bytes/codec + PLI/NACK/FEC
  counters via the A.4 hooks), and the `VTVideoDecoderAdapter` routes its
  codec-unsupported failure to the client's HEVC→H.264 `CODEC_NO` fallback and
  passes the decode-recovery ladder
  (`onFrameDecodeFailed`/`onRecoveryAction`/`onRecovered`) straight through.
  The last suspected gap — a legacy 5-byte HELLO_ACK (old sharer) leaving the
  session without an SSRC — turned out to be a non-issue: the session's
  tolerant `decodeHelloAckCaps` already learns the SSRC from the 5-byte form
  (caps `[]`, so the loss-recovery matrix degrades to PLI-only), now pinned by
  a regression test. The flagged path is therefore at **full feature parity**;
  what remains is runtime baking on a Mac before swapping the default (Phase E)
  and deleting the client's duplicated loss-recovery code (Phase D).
- **Phase D + E — full cutover ✅ (landed).** Because the duplicated
  FEC/NACK/RR/PLI machinery lived *entirely* inside the legacy `receiveLoop`
  (the `ViewerSession` path never touched it), deleting the duplication and
  removing the legacy path were the same change — so D and E collapsed into one
  cutover. `ViewerSession` is now the mac viewer's **sole** receive path: the
  `TAILSCREEN_VIEWER_SESSION` flag is gone, the legacy `receiveLoop` +
  `ingestVideoPacket` / `processRecoveredPacket` / `handleFECParityDatagram` /
  `deliverAU` + the whole feedback cluster (`handleVideoFeedback` /
  `maybePeriodicFeedback` / `dispatchNACKAction` / `sendReceiverReport`) and
  their fields (`negotiatedCaps`, `nackScheduler`, `fecBuffer`, `rrAccounting`,
  the depacketizer, PING/RR bookkeeping) are deleted (~550 lines). What stays
  mac-side, arranged *around* the session: the socket, the VT/Metal adapters,
  the annotation + remote-control TCP channels, `VoiceChannel` audio, the
  keepalive + idle-disconnect plumbing, the stats overlay (fed via the session's
  observation hooks + a `noteReceivedVideoStats` helper), the CODEC_NO fallback,
  and the decode-recovery ladder (`sendPLIUnthrottled`). The `onDecodedFrameForTesting`
  E2E seam is preserved via a new `VTVideoDecoderAdapter.onDecodedPixelBufferForTesting`
  pass-through. Compile-verified by the mac `build`/`test` CI job; the live
  render + loss-recovery path is the local A/B (validated under `net-impair.sh`
  through Phase C).

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
