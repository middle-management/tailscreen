# NACK-based selective retransmission (+ deferred FEC) and receiver-feedback congestion control

> **Status: shipped** (phases 1–2, with the deviations below). Phase 3 (FEC)
> was deferred here and later implemented separately in
> `plans/fec-xor-recovery.md`. Current code: `NACKScheduler.swift`,
> `RetransmitBuffer.swift`, `TransportTuning.swift`
> (`Packages/TailscreenKit/Sources/TailscreenProtocol`), wired into
> `TailscaleScreenShareServer.swift` / `ViewerSession.swift`; see
> `.claude/rules/protocol.md` for the current wire layout.

## Problem & motivation

Before this, the only loss-recovery tool was PLI: any sequence gap dropped
the whole access unit and forced a fresh keyframe — loss amplification, since
one lost ~1100-byte packet could cost a multi-hundred-packet keyframe.
Congestion control had only PLI counts as a signal and bitrate as its only
lever (fps was pinned at 60). NACK recovers a single lost packet at ~1 RTT
for a fraction of a keyframe's cost, and an RTCP-RR-style report gives the
bitrate controller real inputs (loss fraction, RTT, jitter).

## Key decisions & why

- **NACK over UDP control channel, capability-negotiated via extended
  HELLO/HELLO_ACK.** Old viewers/servers silently keep PLI-only behavior
  (`decode` reads only byte 0; legacy `decodeHelloAck` rejects a longer ack) —
  full backward compat with no version field needed.
- **Retransmits are byte-identical RTP resends**, not RFC 4588 RTX
  SSRC/PT multiplexing — the receiver's reorder buffer already dedups/gap-fills,
  so a second packet format would add complexity for no gain.
- **Shared retransmit ring keyed by broadcast batch, not per-viewer copies** —
  payloads are viewer-identical (only header bytes differ), so one ring entry
  serves every viewer; sized by time window + byte cap + batch count, whichever
  trips first.
- **Retransmit budget as a token bucket (25% of current bitrate)**, converting
  to PLI when exceeded or when the ring has evicted the requested packet —
  recovery is never worse than the old PLI-only path, and a slow viewer can't
  turn NACKing into a retransmit storm.
- **`nextCongestionDecision` evolves (doesn't replace) `nextAdaptiveBitrate`** —
  a PLI-only session reproduces the old ±25%/+10% math exactly, so the
  original `AdaptiveBitrateTests` keep passing unchanged.
- **FEC deferred to a later phase**, because NACK at typical tailnet RTTs
  (<100ms direct) recovers before a viewer would even render the gap, FEC
  costs a constant ~10% bandwidth exactly when bandwidth is scarce, and it
  touches the packetizer hot path. Rationale carried forward verbatim into
  `plans/fec-xor-recovery.md`, which shipped it gated to RR-measured RTT >
  150ms and loss > 2%.

## Deviations from the original plan

- **Control-byte values shifted**: NACK/RR/PING landed at **0x0A/0x0B/0x0C**
  (not the planned 0x08/0x09/0x0A) because consent (0x08) and color/HDR (0x09)
  merged first. Helper-wire `setFrameInterval` landed at `InType 0x05`, not
  0x04 (taken by `setAudioEnabled`).
- **Viewer caps live in a side map** (`viewerCaps: [addr: ScreenShareCaps]`),
  not on `Viewer`, to survive the pending→approve promotion without touching
  that path's initializers.
- **Reorder window deepened to 64 packets (not 128)** in NACK mode; the
  planned time-based gap-age bound (`skipGap` trigger) was **not** added —
  `RTPReorderBuffer` has no clock, and 64 packets already bounds the worst
  case, with the NACK scheduler's PLI fallback resyncing via keyframe.
- **Retransmits send on a detached `Task`**, not a dedicated per-viewer send
  tail — the token budget already bounds the rate.
- **Client re-NACK cadence uses a fixed default RTT estimate**, not a live
  server-measured one (that value isn't fed back to the viewer).
- **fps ladder applies `minimumFrameInterval` only** — `VideoEncoder` is not
  re-initialized for the new fps (keyframe interval / data-rate window stay
  tuned to the original tier). Follow-up, not done.
- **Stats overlay ships NACKs-sent only** — no packets-recovered or RTT rows
  (the viewer doesn't receive the server-measured RTT).
- **Local-only E2E seam (`sendNACKForTesting`) not added** — would not
  compile-check under CI anyway; NACK recovery is CI-covered by the
  `RTPLossyChannelTests` closed loop instead. Live validation stays
  `scripts/net-impair.sh --loss 3 --delay 80` + `./test-local.sh 2`.
- **Phase 3 FEC: deferred as planned**, later implemented in
  `plans/fec-xor-recovery.md`.

## Where it lives

- Wire bytes/format: `.claude/rules/protocol.md`, `docs/spec.md`.
- Decision logic: `NACKScheduler.swift`, `RetransmitBuffer.swift`,
  `nextCongestionDecision` (server), `TransportTuning.swift`.
- Tests: `NACKSchedulerTests`, `RetransmitBufferTests`, `RTPLossyChannelTests`,
  `LossRecoveryDifferentialTests` (Swift↔Go differential).
