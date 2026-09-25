# XOR FEC: zero-RTT single-loss recovery (loss-recovery phase 2)

> Status: shipped. `FECCodec.swift` + `FECGroupBuffer.swift` (TailscreenProtocol),
> wired sharer→viewer end to end (0x0D parity datagram, `fecSweepDecision`, RR's
> `fecRecovered` field), pinned by `FECCodecTests` / `FECGroupBufferTests` /
> `FECOverheadDecisionTests` on `linux-protocol`. This is the "phase 3
> (deferred FEC)" continuation of `plans/loss-recovery-nack-fec.md`; that
> plan's NACK + RR + congestion layer is merged and this document already
> reflects deviations from that plan's original phase-1 sketch, called out
> below. Full wire format lives in `.claude/rules/protocol.md`; nothing here
> duplicates that.

## Problem

NACK recovers a loss in ~1 RTT — fine on a direct tailnet path, but on a
DERP-relayed path (150–400 ms RTT) a NACK round trip is 1–3 frame times *per
attempt*, and the viewer's deep reorder window stalls on every packet behind
the gap meanwhile. A single XOR parity packet per group of N media packets
recovers any *one* lost packet with **zero extra RTT**, at a constant `1/N`
bandwidth cost — so it must be adaptive (0% on clean links) and gated to the
high-RTT/high-loss paths where NACK is slow (RTT > 150 ms ∧ loss > 2%, kept
verbatim from the deferral plan).

## Key design decisions

- **One parity per group, not Reed–Solomon.** ≥2 losses in a group fall
  through to NACK, which exists precisely for that; RFC 5109's full
  generality (ULP levels, mask offsets, PT multiplexing) is unneeded since we
  control both ends.
- **Groups never span batches (access units).** A throttled (keyframe-only)
  viewer gets no seqs for skipped inter frames, so per-viewer seq ranges are
  only mutually contiguous *within* one `broadcast` batch — a cross-batch
  group would need per-viewer bodies, breaking the compute-once/fan-out
  economics shared with retransmit templates.
- **Chunked at N within a batch, not one parity per frame.** A keyframe
  fragments into hundreds of packets; a single parity for the whole frame
  would almost certainly face ≥2 losses. `groupRanges` balances group sizes
  (⌈count/N⌉ groups, sizes ±1, not greedy chunking) so no sub-`minGroupSize`
  remainder — notably the AU's marker packet — is ever left uncovered.
  Single-packet groups are skipped (`minGroupSize = 2`).
- **Parity covers `[len:2][byte1][timestamp][payload]` XORed, not payload
  only.** Fan-out only rewrites seq/SSRC per viewer; byte1 (marker|PT) and
  timestamp are viewer-invariant but vary *within* a group (the AU's last
  packet has marker=1) — a payload-only XOR (the phase-1 sketch's original
  design) couldn't reconstruct the marker packet. This is the sketch's main
  deviation.
- **New control byte (0x0D), not a dedicated RTP PT.** Parity must not
  consume media sequence numbers (a lost parity would open a false gap and
  pollute RR loss accounting). The control plane already bypasses RTP demux,
  the scheduler, and RR accounting, so a lost parity is silent and free —
  the group just has no FEC cover; NACK still applies. 0x0D was the
  sketch's originally-penciled 0x0C, taken by the merged NACK layer's PING;
  wire header uses `count` not `mask`+`xorLen` since groups are contiguous by
  construction (deviation from the sketch).
- **Capability-negotiated (`ScreenShareCaps.fec = 1<<2`)**, mirroring `.nack`
  exactly — old peers see an unknown bit/byte and ignore it; full compat
  matrix falls back to whatever the peer already speaks (PLI-only / NACK-only
  / full FEC).
- **Extended RR carries `fecRecovered:2 BE`**, tolerant-decode (both 20- and
  22-byte forms). This is not optional polish: without it, RR loss goes to
  ~0 the moment FEC hides all loss, which would turn FEC off and re-trigger —
  an oscillating thermostat with the sensor outside the room. `fecRecovered`
  lets the FEC decision see raw link loss while the *bitrate* arm still reacts
  only to residual (post-FEC) loss, so repaired loss isn't double-penalized.
  Known accepted side effect: because the bitrate arm sees only residual loss,
  a congestion-limited link can still slow-sawtooth (FEC masks loss → clean
  window → up-ramp → re-induced loss), bounded by the up-hysteresis.
- **Recovery is fed through the exact same path as a received packet**
  (`processVideoPacket`, shared by wire and recovery) — `recordRRPacket` is
  still called (recovered ≠ lost) and a new `NACKScheduler.noteRecovered`
  advances the scheduler's `highestSeq` (not just `cancelGap`, which was the
  original design): a recovered marker/tail packet is ahead of the next
  batch's first wire packet, and without advancing `highestSeq` the next
  batch reopens a phantom gap for an already-recovered seq. `cancelGap`
  itself avoids feeding a spurious RTT sample into the NACK RTT EMA.
- **Per-viewer gating, not global.** `fecSweepDecision` gates each viewer on
  its own loss/RTT; the ladder reads only the gated set's worst raw loss so
  one lossy viewer can't force overhead onto everyone; encoder bitrate
  compensation (N/(N+1)) applies only while the gated set is non-empty,
  forces a keyframe when FEC turns on, and is re-pushed after every encoder
  helper respawn.
- **Parity is interleaved per-group inside the batch's send-chain job**, not
  batched after the whole frame (a post-review correction) — trailing parity
  defeated FEC for its main target: a multi-hundred-packet keyframe would
  evict early groups from the viewer's bounded ring before their parity
  arrived.
- **Viewer arms FEC on evidence, not negotiation** — relaxed NACK scheduler
  tolerances and media buffering switch on upon the first 0x0D actually
  received, disarming after ~3s without parity, so a `.fec`-capable viewer on
  a clean link (where the server never sends parity) pays zero extra latency
  tolerance.
- **NACK scheduler tolerance widened only in FEC mode** (`reorderPacketTolerance:
  N+2`, `reorderToleranceNs: 25ms`) so a gap doesn't become NACK-eligible
  before its own parity had a chance to close it; global widening was
  rejected — it would delay NACK on non-FEC sessions for nothing.

## Compatibility matrix

Unknown capability bits are inert `OptionSet` bits on both sides; a stray
0x0D at any pre-FEC peer decodes to `nil` and is dropped. Every combination of
{old, NACK-era, FEC} server × viewer degrades to the weaker side's existing
behavior (PLI-only, NACK-only, or full FEC) — no combination breaks.

## Pointers

- Wire format, capability bit, RR field: `.claude/rules/protocol.md`.
- Codec/group logic: `FECCodec.swift`, `FECGroupBuffer.swift`
  (TailscreenProtocol) — pure, no I/O.
- Server: `fecSweepDecision`/`fecOverheadDecision` beside
  `nextCongestionDecision` in `TailscreenScreenShareServer.swift`; parity
  fan-out inside `broadcast`'s existing per-viewer send-chain job.
- Client: `.fec` arm/disarm, `processVideoPacket`, extended RR send in
  `TailscaleScreenShareClient.swift`.
- Scheduler: `NACKScheduler.cancelGap` / `.noteRecovered`.
- Stats: `ViewerStats.fecRecovered` / `noteFECRecovered()` next to
  `nacksSent` (the net-impair validation signal: FEC-recovered rising, NACKs
  and PLIs near zero).
- Tests: `FECCodecTests`, `FECGroupBufferTests`, `FECOverheadDecisionTests`,
  extended `RTPLossyChannelTests`/`NACKSchedulerTests`/`RTPPacketTests`. Live
  validation via `scripts/net-impair.sh` + `test-local.sh` (see
  `.claude/rules/testing.md`).

## Risks (still worth knowing)

- Marker/timestamp reconstruction is load-bearing — a parity body missing
  byte1 or timestamp would silently merge two AUs on recovery.
- Any second path around `processVideoPacket` that skips `recordRRPacket`
  reintroduces the over-reacting-congestion-controller bug this design avoids.
- Groups must never span batches — a correctness rule (throttled-viewer seq
  space), not a preference; `groupRanges` enforces it structurally by
  operating on one batch's template array.
- The bitrate-arm/FEC-arm sawtooth above is a known, accepted property, not a
  bug to "fix" by feeding raw loss to the bitrate arm.
