# Converging the macOS viewer onto `ViewerSession`

> Status: **shipped**. `ViewerSession` (portable, `Packages/TailscreenKit/Sources/TailscreenViewer/`)
> is now the macOS viewer's sole receive-side data plane; the legacy
> duplicated loss-recovery code in `TailscaleScreenShareClient` is deleted.

## Why (goal)

`ViewerSession` and the old mac client carried a near line-for-line
duplicate of the loss-recovery core (HELLO/HELLO_ACK, NACK, receiver
reports, PLI, FEC) — every new loss-recovery behavior had to be written
twice and could drift, and `ViewerSession` is the copy Linux CI exercises on
every PR. Converging means one tested data-plane implementation; the mac
client shrinks to socket + `ViewerSession` + mac-only side channels. This was
explicitly an architectural payoff, not a user-visible feature.

## What converged vs. what stayed mac-side

Key enabler: `ViewerSession` never inspects a decoded frame's *contents* —
it only routes decoder output → sink and does bookkeeping. So it could
absorb HELLO/HELLO_ACK, PING/RR, NACK, PLI, FEC, video reassembly, and
control-byte demux, while these stayed mac-side, arranged *around* the
session rather than inside it: the annotation and remote-control TCP
channels, request-to-share, the approval-UI idle-suppression nuance, the
keepalive/idle-disconnect timers, stats-overlay counters, the H.264/HEVC
CODEC_NO fallback, and the decode-recovery escalation ladder
(`plans/surface-silent-failures.md`). Audio (`VoiceChannel`) also stayed
mac-side — voice/system demux into dual `AVAudioPlayerNode`s and
playback-queue-driven jitter pacing are integrated with host audio in ways
the session can't own — via a passthrough hook rather than a rewrite.

## Key design decisions and why

- **The decoded frame type is opaque to the session** (`DecodedFrame`
  marker protocol, `width`/`height` only) rather than genericizing
  `ViewerSession<D, S>`. `ViewerPipeline` and the CLI already wire this seam
  through existentials, so an existential marker added near-zero ripple, and
  per-frame boxing cost is negligible at video rates. This is what makes the
  mac zero-copy VideoToolbox→Metal path survive routing through the shared
  session: a `CVPixelBufferBox` (IOSurface-backed, Metal-compatible) flows
  through untouched, and only the concrete sink downcasts to reach pixels.
- **Decoders emit frames via callback, not return them** — the portable
  decode was synchronous but VideoToolbox decompression is async. The
  adapter must hop back onto the host's serialization queue before invoking
  the callback, since `ViewerSession` is not `Sendable` and owns no queue —
  documented as a hard contract on the protocol, not just a convention.
- **Audio passthrough is an escape hatch (`onAudioDatagram`), not a rewrite**
  — when set, inbound audio RTP bypasses the built-in depacketizer/decoder
  entirely and goes to the host verbatim; `nil` (Linux's default) keeps the
  built-in path unchanged.
- **Phases D (delete duplication) and E (remove the feature flag) collapsed
  into one cutover** — the duplicated FEC/NACK/RR/PLI machinery lived
  entirely inside the legacy `receiveLoop`, so once `ViewerSession` reached
  parity, deleting the duplication and removing the legacy path were
  necessarily the same change (~550 lines removed).
- **A suspected parity gap (legacy 5-byte HELLO_ACK from an old sharer
  leaving the session without an SSRC) turned out to be a non-issue** — the
  session's tolerant `decodeHelloAckCaps` already learns the SSRC from the
  5-byte form (empty caps → loss-recovery degrades to PLI-only), now pinned
  by a regression test rather than requiring new code.

## Where it lives now

- Session: `Packages/TailscreenKit/Sources/TailscreenViewer/ViewerSession.swift`.
- Mac adapters: `Apps/macOS/Sources/ViewerSessionAdapters.swift`
  (`CVPixelBufferBox`, `VTVideoDecoderAdapter`, `MetalSinkAdapter`), tested by
  `ViewerSessionAdapterTests`.
- Mac receive path: `TailscaleScreenShareClient`'s `buildViewerSession` +
  `receiveLoopViaViewerSession` (the old `receiveLoop`,
  `ingestVideoPacket`/`processRecoveredPacket`/`handleFECParityDatagram`/
  `deliverAU`, and the feedback cluster are gone).
- E2E test seam: `VTVideoDecoderAdapter.onDecodedPixelBufferForTesting`
  (successor to the old `onDecodedFrameForTesting`).

## Risk note (resolved, kept for context)

Runtime correctness of the `ViewerSession`-backed path (vs. compile-only CI
verification, since this is macOS-only and not on Linux CI) was validated by
local A/B comparison under `scripts/net-impair.sh` before the cutover, not by
an automated gate — there is no CI leg that exercises real loss recovery on
the mac viewer.
