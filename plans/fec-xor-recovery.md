# XOR FEC: zero-RTT single-loss recovery (loss-recovery phase 2)

> Status: implemented. Shipped as `FECCodec.swift` + `FECGroupBuffer.swift`
> (TailscreenProtocol), wired sharer→viewer end to end (the `0x0D` parity
> datagram, `fecSweepDecision`, the RR's `fecRecovered` field — see
> `.claude/rules/protocol.md`) and pinned by `FECCodecTests` /
> `FECGroupBufferTests` on Linux CI (`linux-protocol`).
> This was the "phase 3 (deferred FEC)" continuation of
> `plans/loss-recovery-nack-fec.md` — that plan's NACK + receiver-report +
> congestion-control layer is merged; this plan builds on the merged code
> (not the original sketch) and records where it deviates from the sketch.

## Problem & motivation

NACK recovers a lost packet in ~1 RTT. On a direct tailnet path (RTT
< 100 ms) that beats rendering the gap, which is why FEC was deferred. But on
a DERP-relayed path (RTT 150–400 ms) a NACK round trip is 1–3 frame times at
60 fps *per attempt*, and the viewer's deep reorder window (64 packets,
Sources/TailscaleScreenShareClient.swift:606) holds every packet behind the
gap while it waits — so each single-packet loss becomes a visible stall even
though the retransmit eventually lands. Worse, at loss rates of a few percent,
a multi-hundred-packet keyframe almost always loses *something*, and each
retransmit is itself subject to the same loss (re-NACK cadence
`max(1.5 × RTT, 40 ms)` up to 3 attempts, Sources/NACKScheduler.swift:168).

A single XOR parity packet per group of N media packets lets the viewer
reconstruct any *one* lost packet in the group with **zero additional RTT** —
the recovery data is already in flight. Cost: a constant `1/N` bandwidth
overhead, which is why it must be adaptive (0 % on clean links) and gated to
the high-RTT paths where NACK is slow. The merged plan's deferral rationale
(`plans/loss-recovery-nack-fec.md`, Deviations, "Phase 3 FEC") stands and is
the design brief here: *"Enable adaptively only when RR-measured RTT > 150 ms
and loss > 2 %."*

## Goals

- Server emits one XOR parity datagram per group of ≤ N media packets, computed
  **once** on the pre-rewrite template stream and fanned out per viewer (same
  economics as `rewriteRTPHeader` retransmits).
- Viewer recovers any single loss per group with zero RTT; the recovered packet
  enters the depacketizer exactly as if received, cancels its pending NACK, and
  counts as *received* (not lost) in the receiver report.
- Overhead tracks measured loss via a pure `fecOverheadDecision` folded into the
  existing 5 s congestion sweep: 0 % on clean links, ramping to ~10–20 %
  (1 parity per 5–10 packets) on lossy high-RTT ones.
- Capability-negotiated (new `ScreenShareCaps.fec` bit riding the merged
  extended-HELLO handshake); old peers provably ignore every new byte. Full
  compat matrix degrades to today's NACK-or-PLI behavior.
- All new decision logic pure and CI-testable per CLAUDE.md's
  extract-the-decision rule, including a `LossyChannel` end-to-end closed loop.

## Non-goals

- No Reed–Solomon / multi-loss-per-group codes. One parity per group recovers
  exactly one loss; ≥ 2 losses in a group fall through to the merged NACK path
  (which exists precisely for that). We control both ends, so RFC 5109's full
  generality (ULP levels, mask offsets, media/FEC PT multiplexing) is skipped.
- No FEC for audio (PT 98/99). Voice already has concealment
  (`VoiceResilienceDecisionTests`); system audio is one AU per packet and
  tolerable to drop.
- No FEC protection of retransmits or of the TCP channel.
- No change to the NACK wire format, the RR *loss math*, `RetransmitBuffer`,
  or the congestion controller's bitrate/fps arms.

## Current state (file:line, all on `main`)

- **Control-byte space.** `ScreenShareControlMessage` occupies 0x00–0x0C
  (Sources/RTPPacket.swift:40-98): HELLO…PROFILE_NO took 0x00–0x09, and the
  merged loss-recovery layer took **NACK = 0x0A, RECEIVER_REPORT = 0x0B,
  PING = 0x0C**. The original phase-1 sketch penciled FEC at 0x0C; that byte
  is now PING, so **FEC lands at 0x0D** (first free value, still ≤ 0x7F so
  `looksLikeControl` at RTPPacket.swift:111-114 is untouched). `decode`
  (RTPPacket.swift:104-107) returns nil for unknown bytes; the server drops nil
  (`guard let kind` at Sources/TailscaleScreenShareServer.swift:1483) and the
  viewer's control switch falls to `default: break`
  (Sources/TailscaleScreenShareClient.swift:633-634) — this is the proof that
  old peers ignore the new message.
- **Capability handshake.** Viewer sends `encodeHello(caps:)` with
  `[.nack, .receiverReport]` (Client.swift:448); server records per-addr caps
  in the `viewerCaps` side map (Server.swift:470, 1498-1499) and replies with
  the 6-byte extended ack carrying `serverCaps` (Server.swift:473, 1561-1567).
  `ScreenShareCaps` is a `UInt8` OptionSet with bit0/bit1 used
  (RTPPacket.swift:250-258) — bit2 is free. Unknown bits in either direction
  are inert (`contains` checks only known bits).
- **Fan-out & templates.** `broadcast` packetizes once into seq=0/ssrc=0
  `templates` (Server.swift:3178-3188), atomically reserves a contiguous
  per-viewer seq range (`Plan`, Server.swift:3171-3216), registers the batch in
  `RetransmitBuffer` for NACK-capable viewers (Server.swift:3218-3233), then
  per-viewer send chains rewrite only header bytes 2-3/8-11
  (`rewriteRTPHeader`, Server.swift:3289-3296). Keyframe-only-throttled viewers
  skip inter frames **without reserving seqs** (Server.swift:3200-3214), so
  their seq space is contiguous only *within* a batch — any FEC group must not
  span batches.
- **Receiver report.** Client accounting in `recordRRPacket` /
  `sendReceiverReport` (Client.swift:913-957): `fracLostQ8 = (expected −
  received)/expected`, i.e. whatever gets counted as received reduces reported
  loss. `decodeReceiverReport` is length-tolerant (`data.count >= 20`,
  RTPPacket.swift:220) — the same forward-compat seam the extended HELLO_ACK
  uses, available for appending fields.
- **NACK scheduler.** Gap becomes NACK-eligible after 15 ms *or* 3 newer
  packets (`reorderToleranceNs` / `reorderPacketTolerance`,
  Sources/NACKScheduler.swift:44-46, 178-180) — both are init parameters. A
  straggler/duplicate that fills a tracked gap removes it and, if the gap was
  already NACKed, feeds an RTT sample (NACKScheduler.swift:109-111). There is
  no way to clear a gap *without* the RTT-sample side effect today.
- **Congestion sweep.** `adaptiveBitrateSweep` (Server.swift:2713-2829) snapshots
  per-viewer PLI counts, freshness-decayed `lossFractionQ8`, and `rttNs`
  (populated by `handleReceiverReport`, Server.swift:1659-1679; `Viewer` fields
  at Server.swift:118-119), isolates outliers via `congestionInputs`
  (Server.swift:2995-3016), and feeds pure `nextCongestionDecision`
  (Server.swift:3030-3082). The FEC decision slots in beside it, same cadence,
  same inputs plumbing.
- **Stats overlay.** `ViewerStats.nacksSent` + `noteNACKSent` already exist
  (Sources/MetalViewerRenderer.swift:50, 202-203); FEC adds a recovered
  counter next to them — the net-impair validation signal.
- **Test harness.** `RTPLossyChannelTests.runNACKLoop`
  (Tests/TailscreenTests/RTPLossyChannelTests.swift:267-334) is the seeded
  step-clocked closed loop (packetize → loss → scheduler + depacketizer →
  retransmit re-injection); it's the natural place to add a FEC leg.
  `LossyChannel` (Tests/TailscreenTests/LossyChannel.swift) provides seeded
  loss/reorder/dup.

## Design

### Scheme: single-parity XOR, per-frame groups chunked at N

**Groups never span access units.** Each `broadcast` batch (one AU) is
partitioned into consecutive runs of up to `N` templates
(`⌈templateCount/N⌉` groups); each group gets one parity datagram. Rationale:

- **Per-viewer seq contiguity only holds within a batch.** A throttled
  (keyframe-only) viewer receives no seqs for skipped inter frames
  (Server.swift:3200-3214), so a cross-frame group would cover seq ranges that
  *differ per viewer*, breaking the compute-once/fan-out model. Within a batch,
  every recipient's range is contiguous and congruent (`startSeq + i`), so one
  shared parity body + a per-viewer `baseSeq` works — exactly the retransmit
  template economics.
- **Keyframes are where FEC pays.** A keyframe fragments into hundreds of
  packets (H264Packetizer.maxPayloadBytes = 1100, RTPPacket.swift:410; a 1–2 MB
  IDR ≈ 900–1800 packets), so at 2–3 % loss it nearly always loses ≥ 1 packet,
  and an unrecovered keyframe loss costs a *fresh keyframe*. Chunking at N
  bounds each group's double-loss probability (at 3 % loss, N = 10 →
  P(≥2 lost in group) ≈ 3.3 %, vs certain multi-loss over a 900-packet frame
  with a single parity).
- **Delta frames get cheap protection too.** A 1–3 packet delta AU forms one
  short group whose parity degenerates toward duplication (up to 100 % packet
  overhead *for that frame*), but delta frames are small in bytes, so the
  byte-overhead stays ≈ 1/N stream-wide (keyframes dominate). Groups of a
  single packet are skipped (`minGroupSize = 2`): a duplicate is what
  `LossyChannel`'s dup path already proves harmless, but it buys less than the
  NACK path costs and single-packet AUs are the cheapest possible PLI anyway.

Fixed-N groups *across* frames were rejected for the contiguity reason above,
and per-frame single-parity (no chunking) was rejected because it under-protects
exactly the frames that matter (keyframes).

### What the parity covers (recovery must rebuild a full RTP packet)

Fan-out rewrites only bytes 2-3 (seq) and 8-11 (SSRC); byte 0 is constant 0x80;
byte 1 (marker|PT) and bytes 4-7 (timestamp) are viewer-invariant but **not**
group-invariant (the AU's last packet has marker = 1, RTPPacket.swift:454-456).
So the parity body is the XOR over each covered template of:

```
[len:2 BE][byte1][bytes4..7][payload bytes...]
```

zero-padded to the longest member (`len` = that packet's total length, so the
recovered packet is truncated correctly). Recovery XORs the received k−1
members' same fields against the body, then reconstructs the missing packet:
byte0 = 0x80, seq = the missing sequence number (known from the gap), ssrc =
the stream SSRC (known from any member), byte1 + timestamp + payload from the
XOR. This is RFC 5109's "protected fields" idea reduced to the two fields our
own packetizer actually varies. Computing it on templates makes the body
identical for every viewer.

### Wire format

New UDP control datagram, server→viewer only:

```
0x0D (FEC)  [baseSeq:2 BE][count:1][xor body:variable]
```

- `baseSeq` — first sequence number of the group, **in that viewer's sequence
  space** (per-viewer rewrite of 2 bytes, same trick as retransmits).
- `count` — group size k (2…N ≤ 16). Contiguous by construction, so a count
  beats the sketch's `mask:2` (we never emit non-contiguous groups; a mask
  would only add decode surface). This is a recorded deviation from the
  phase-1 sketch's `[baseSeq:2][mask:2][xorLen:2]` — `xorLen` is also dropped
  because the body carries per-packet lengths in its first XORed word and the
  datagram boundary delimits the body.
- Max size: 5 header bytes + (2 + 1 + 4 + 1100) ≈ 1112 bytes — same envelope
  as a media packet, fits the tunnel MTU reasoning at RTPPacket.swift:407-410.

**Why a control byte and not a dedicated RTP PT:** a parity packet must not
consume media sequence numbers — otherwise losing *parity* would open a gap,
trigger NACKs/RR-loss for a packet that carries no media, and pollute
`recordRRPacket`'s expected-count. Giving parity its own PT with its own seq
space would work but adds a second sequence tracker on both ends for zero
benefit; the control plane (0x00–0x7F) already bypasses RTP demux, the
scheduler, and RR accounting entirely, so **parity loss is silent and free**
(the group simply has no FEC cover; NACK still applies). Old viewers drop
0x0D at Client.swift:633-634; old servers drop it at Server.swift:1483.

**Capability bit:** `ScreenShareCaps.fec = 1 << 2` (RTPPacket.swift:250-258).
Viewer advertises `[.nack, .receiverReport, .fec]` (Client.swift:448); server
adds `.fec` to `serverCaps` (Server.swift:473). FEC activates per side only
when both advertised it, mirroring `.nack` exactly. Old server sees the
unknown bit and ignores it (its `contains(.nack)` checks are unaffected); old
viewer gets a 5-byte ack path only if it advertised nothing — a `.fec`-aware
server keys parity emission off the viewer's `.fec` bit, so legacy and
NACK-only viewers never receive 0x0D.

**Extended receiver report (FEC feedback):** append `[fecRecovered:2 BE]`
(packets recovered since the last report) to the RR when `.fec` is negotiated.
`decodeReceiverReport`'s `>= 20` guard (RTPPacket.swift:220) already tolerates
the longer form; a new tolerant read returns 0 for the 20-byte legacy layout —
the same both-forms pattern as `decodeHelloAckCaps` (RTPPacket.swift:165-170).
This field is what stops the adaptive loop from oscillating (below).

### Adaptivity: pure `fecOverheadDecision`, fed by the existing sweep

New pure `static func fecOverheadDecision(_ inputs: FECInputs) -> Int` on the
server (0 = FEC off, else group size N), computed once per 5 s sweep window
alongside `nextCongestionDecision` (Server.swift:2805-2827) — same
extract-the-decision pattern, same hysteresis discipline:

- **Inputs** (all already collected by the sweep): worst freshness-decayed
  `lossFractionQ8` and worst `rttNs` over **`.fec`-capable, non-throttled**
  viewers (reusing the `congestionInputs` isolation so one outlier can't force
  overhead onto everyone — Server.swift:2995-3016), the per-window
  `fecRecovered` sum (new, drained like `nackServedThisWindow`,
  Server.swift:2791-2800), and the current group size.
- **On-gate (per the merged plan's deferral criteria, kept verbatim):** RTT
  > 150 ms **and** raw loss > 2 %, where raw loss ≈ residual RR loss +
  recovered-per-window (converted to Q8 against the window's expected packet
  count). Sub-150 ms paths keep FEC off — NACK already recovers faster than
  render there, and the overhead would buy nothing.
- **Ladder:** raw loss 2–4 % → N = 10 (10 % overhead); 4–8 % → N = 7 (~14 %);
  > 8 % → N = 5 (20 %). Never below 5 — past ~20 % overhead the link needs the
  bitrate/fps arms, not more parity.
- **Off-gate with hysteresis:** step down/off only after two consecutive clean
  windows (raw loss < 1 % — i.e. residual *and* recovered both near zero).
  `fecRecovered` is the anti-oscillation term: without it, FEC hiding all loss
  would zero the RR fraction, switch FEC off, and re-trigger — with it, a link
  where parity is doing work keeps its parity.
- **Bitrate compensation:** when N > 0, the sweep passes the encoder
  `setBitrate(current × N/(N+1))` via the existing `applyAdaptiveBitrate`
  plumbing (Server.swift:3088-3102) so media + parity together stay at the
  congestion-controlled rate — FEC must not silently run the link 10–20 % over
  what `nextCongestionDecision` chose. The pure decision returns the group
  size; the applier owns the scaling so `CongestionDecisionTests` semantics
  are untouched.

**Fan-out interplay (one encode, per-viewer loss):** parity bodies are computed
**once per batch** (on the templates, right after the `RetransmitBuffer.record`
site, Server.swift:3218-3233) whenever *at least one* plan-recipient has `.fec`
negotiated **and** the sweep's decision says N > 0 for that viewer's loss
class. Sending is **per-viewer**: only viewers whose own decayed loss/RTT pass
the on-gate get the parity datagrams (clean-link viewers pay zero overhead even
mid-share with a lossy peer — mirroring how `congestionInputs` isolates rather
than globalizes one viewer's loss). Parity datagrams for a viewer are appended
to that viewer's **existing video send chain job** (Server.swift:3259-3268),
after the group's media packets, so ordering, the per-viewer backlog cap, and
the drop policy all apply unchanged; a frame the cap sheds for a viewer sheds
its parity with it (the viewer never got the members, and the NACK/PLI path
already owns that gap). **Throttled (keyframe-only) viewers stay eligible:**
they're throttled *because* they're lossy, their stream is now keyframes-only
— the exact frames where an unrecovered loss costs another keyframe — and
their skipped inter frames never form groups, so the mechanism needs no
special case beyond the within-batch rule already stated.

### Receiver: recovery in front of the depacketizer

New pure struct `FECGroupBuffer` (deterministic, injected `nowNs`, no I/O —
plain `Sendable`, owned by the client's receive task like `nackScheduler`,
Client.swift:52-61):

- `noteMedia(packet, seq, nowNs)` — retains a copy of recent video packets in
  a bounded ring (cap: last 4 groups' worth or 256 KB, whichever first; ~11 KB
  per N = 10 group, so keyframe bursts fit) and, if a buffered parity's group
  just became solvable (parity can arrive *before* a reordered member), returns
  the recovered packet.
- `noteParity(baseSeq, count, body, nowNs)` — if exactly one member of
  `[baseSeq, baseSeq+count)` is missing and the rest are held, returns the
  recovered packet; if none missing, drops the parity; if ≥ 2 missing, buffers
  the parity briefly (one reorder tolerance) then discards — NACK owns
  multi-loss.
- Each seq recovers **at most once** (a recovered-set guard), so a late
  original arriving after recovery can't double-feed: the original still flows
  to the depacketizer, whose `RTPReorderBuffer` drops it as a
  behind-us duplicate (RTPPacket.swift:614-618) — the same path a network dup
  takes today, already pinned by `testStreamSurvivesDuplication`.

**Placement in `receiveLoop`:** a new `case .fec` in the control switch
(Client.swift:590-637, beside `.ping`) routes to `noteParity`; the video-RTP
branch (Client.swift:654-673) additionally calls `noteMedia`. Every recovered
packet is fed through **the same path as a received datagram**, factored into a
small `processVideoPacket(_:)` helper the loop and the recovery path share:

1. `renderer.noteReceivedBytes` is *skipped* (it wasn't on the wire) but a new
   `renderer.noteFECRecovered()` increments the overlay counter;
2. `recordRRPacket(seq:)` **is** called — recovered ≠ lost, so the RR residual
   loss excludes it and the congestion controller doesn't over-react
   (Client.swift:913-926 already counts any fed seq as received);
   `fecRecoveredSinceReport` increments for the extended-RR field;
3. `nackScheduler.cancelGap(seq:)` — a **new** method that removes the gap
   *without* the straggler path's RTT-sample side effect
   (NACKScheduler.swift:109-111): an FEC recovery after a NACK went out would
   otherwise inject "time since NACK" (actually FEC latency) into the RTT EMA
   and corrupt the re-NACK cadence;
4. `depacketizer.ingest(recovered)` with the standard AU handling (the
   recovered packet may complete an AU — often the marker packet).

### NACK interplay: FEC first, NACK for what FEC can't close

- **Ordering:** parity for a group is sent in the same send-chain job as its
  members, so it trails the group by ≤ one datagram — within a 60 fps frame
  burst that's ~1 ms of wire time, not an RTT. FEC therefore gets first shot
  at every gap by construction; NACK eligibility just has to not fire *before*
  the group (plus its parity) has fully arrived.
- **Quantified NACK delay:** with N = 10, a packet lost first-in-group sees up
  to 9 newer media packets + 1 parity before recovery — but the scheduler's
  default `reorderPacketTolerance = 3` (NACKScheduler.swift:46) would make the
  gap NACK-eligible after 3 newer packets, racing a recovery that's already in
  flight. So when FEC is active the client constructs the scheduler with
  `reorderPacketTolerance: N + 2` and `reorderToleranceNs: 25 ms` (one 60 fps
  frame interval + parity slack; both are existing init params,
  NACKScheduler.swift:69-87). Cost when FEC *fails* (≥ 2 losses in a group):
  the first NACK goes out ≤ ~10 ms / ≤ N+2 packets later than today —
  negligible against the ≥ 150 ms RTT that gated FEC on in the first place.
  One wasted NACK when both raced is harmless: the server's ring serves it or
  the dedup drops the second copy.
- **PLI stays the floor:** scheduler abandonment rules (attempts/ring-age,
  NACKScheduler.swift:165-206) are unchanged; a group FEC couldn't solve and
  NACK couldn't refill still converges to a keyframe.
- **Loss accounting:** RR `fracLostQ8` reports **residual** (post-FEC) loss —
  recovered packets were "received" for congestion purposes, so the bitrate
  arm reacts only to loss that actually cost something. The appended
  `fecRecovered` field carries the repaired volume so the *FEC* decision still
  sees raw link loss (see anti-oscillation above). Server-side, recovered
  packets generate no PLIs and no NACKs, so `nackServed` softening
  (Server.swift:3046) is unaffected.

### Compatibility matrix

| | old server | NACK-era server | FEC server |
|---|---|---|---|
| **old viewer** | today | PLI-only (merged behavior) | 1-byte HELLO → no caps → 5-byte ack, no 0x0D ever sent |
| **NACK-era viewer** | PLI-only | NACK (merged) | caps lack `.fec` → NACK only, no 0x0D sent |
| **FEC viewer** | 0x00-only read → 5-byte ack → caps `[]` → PLI-only | ack caps lack `.fec` → NACK only, no FEC state armed | full |

Unknown cap bits are inert OptionSet bits on both sides; stray 0x0D at any old
peer dies in `decode` → nil (RTPPacket.swift:104-107).

## Implementation steps

1. **`Sources/RTPPacket.swift`** — add `case fec = 0x0D` with doc comment;
   `ScreenShareCaps.fec = 1 << 2`; `encodeFEC(baseSeq:count:body:)` /
   `decodeFEC(_:) -> (baseSeq: UInt16, count: Int, body: Data)?`; extend the RR
   codec with the optional trailing `fecRecovered:2 BE` (tolerant decode, both
   lengths accepted; encode emits it only when the caller passes it).
2. **New `Sources/FECCodec.swift`** — pure static
   `parityBody(for templates: ArraySlice<Data>) -> Data` (the len/byte1/ts/
   payload XOR) and `recover(missingSeq:ssrc:members:body:) -> Data?`
   (nil on inconsistent lengths — malformed parity must never emit a torn
   packet); plus `groupRanges(templateCount:groupSize:minGroupSize:) ->
   [Range<Int>]` (the group-packing rule, incl. the skip-singletons floor).
3. **New `Sources/FECGroupBuffer.swift`** — the receiver struct per Design
   (bounded ring, parity buffering, at-most-once recovery guard). Pure,
   injected `nowNs`.
4. **`Sources/NACKScheduler.swift`** — add `mutating func cancelGap(seq:)`
   (remove without RTT sample). No other behavior change.
5. **`Sources/TailscaleScreenShareServer.swift`** — add `.fec` to `serverCaps`
   (:473); new `case .fec` in `handleIncoming` (server→viewer only; ignore,
   like `.ping` at :1552-1554); `Viewer.fecRecoveredThisWindow` drained like
   `nackServedThisWindow` (:2791-2800) and fed from the extended RR in
   `handleReceiverReport` (:1659-1679); pure `fecOverheadDecision` + `FECInputs`
   beside `nextCongestionDecision` (:3030); sweep computes the decision and a
   per-viewer send-gate set (:2805-2827), applies the N/(N+1) bitrate
   compensation through `applyAdaptiveBitrate`; `broadcast` computes parity
   bodies per group after the retransmit-record block (:3218-3233) when any
   plan recipient qualifies, and appends per-viewer parity datagrams (rewritten
   `baseSeq`) inside the existing send-chain job (:3259-3268). Test seam:
   `onFECParitySentForTesting` beside `onNACKServedForTesting`.
6. **`Sources/TailscaleScreenShareClient.swift`** — advertise `.fec` in the
   HELLO (:448); arm `FECGroupBuffer` + FEC-mode scheduler tolerances when the
   ack carries `.fec` (:599-614); `case .fec` in the control switch → recovery
   flow; factor `processVideoPacket(_:)` shared by wire + recovered packets;
   extended RR send with `fecRecoveredSinceReport` (:930-957); reset new state
   in `resetLossRecoveryState` (:856-868).
7. **`Sources/MetalViewerRenderer.swift` / `ViewerStatsOverlay.swift`** —
   `ViewerStats.fecRecovered` + `noteFECRecovered()` beside `nacksSent`
   (:50, 202-203) and an overlay row (the net-impair validation signal:
   FEC-recovered rising, NACKs *and* PLIs near zero).
8. **Tests** (below), then **update CLAUDE.md in the same commit** (its own
   rule): protocol section (0x0D, `.fec` cap bit, extended RR), the pure-suite
   test list (each new suite/decision added — the "add it to this list" rule),
   and the test-seams paragraph.

## Files to touch

| File | Change |
|---|---|
| `Sources/RTPPacket.swift` | `fec = 0x0D`, `ScreenShareCaps.fec`, FEC codec, extended-RR codec |
| `Sources/FECCodec.swift` (new) | parity compute, recovery solve, group packing — all pure |
| `Sources/FECGroupBuffer.swift` (new) | receiver-side group tracking + recovery buffer |
| `Sources/NACKScheduler.swift` | `cancelGap(seq:)` |
| `Sources/TailscaleScreenShareServer.swift` | `fecOverheadDecision`, sweep integration, per-viewer parity fan-out, RR-field intake, bitrate compensation |
| `Sources/TailscaleScreenShareClient.swift` | `.fec` negotiation, recovery flow, NACK suppression tolerances, extended RR |
| `Sources/MetalViewerRenderer.swift`, `ViewerStatsOverlay.swift` | recovered counter + overlay row |
| `Tests/TailscreenTests/` | `FECCodecTests.swift`, `FECGroupBufferTests.swift`, `FECOverheadDecisionTests.swift` (new); extend `RTPPacketTests.swift`, `RTPLossyChannelTests.swift`, `NACKSchedulerTests.swift` |
| `CLAUDE.md` | protocol + test-list + seams sections (same commit) |

## Testing strategy

All CI-able (pure logic — no tsnet, per CLAUDE.md's CI constraint).

- **`FECCodecTests`:** parity/recover round trip for every position in the
  group (first/middle/last — the last carries the marker bit, which must
  survive recovery); mixed packet lengths (len-word truncation); HEVC PT
  templates; wrap-around `baseSeq` (seq 0xFFFE..0x0002); `groupRanges` packing
  incl. the `minGroupSize` skip and remainder groups; malformed body → nil.
- **`FECGroupBufferTests`:** single loss recovered; parity-before-member
  reordering recovered; two losses → no recovery (and parity aged out);
  parity for a fully-received group dropped; late original after recovery not
  re-emitted (at-most-once guard); ring memory bound (oldest groups evicted).
- **`FECOverheadDecisionTests`:** RTT gate (lossy but < 150 ms stays off);
  loss ladder band edges (2/4/8 % → 10/7/5); raw-loss reconstruction from
  residual + recovered (the anti-oscillation case: residual ≈ 0, recovered
  high → FEC stays on); two-clean-windows off-hysteresis; throttled/legacy
  viewers excluded from the inputs.
- **`NACKSchedulerTests` additions:** `cancelGap` clears without an RTT sample
  (estimate unchanged) and without a PLI; FEC-mode tolerances (N+2 newer
  packets produce no NACK, N+3 do).
- **Wire codecs in `RTPPacketTests`:** FEC encode/decode round trip incl.
  max-size body; extended-RR both-lengths compat (20-byte legacy decodes with
  `fecRecovered == 0`; 22-byte form round-trips); `decode` of 0x0D on a
  caps-less path returns `.fec` (and the *legacy-peer proof*: old-enum
  simulation — unknown byte → nil — is already pinned by the existing
  unknown-byte tests; extend with 0x0D).
- **`RTPLossyChannelTests` closed loop (extend `runNACKLoop` into
  `runRecoveryLoop` with an FEC leg):** server side of the loop groups the
  built stream's packets per AU with `groupRanges` + `parityBody`; the step
  clock delivers parity after each group.
  - `testSingleLossPerGroupRecoveredByFECWithZeroNACKs` — seeded loss placed
    ≤ 1 per group: all frames intact, `nacks == 0`, `plis == 0`, zero
    `lostBeforeThisAU`.
  - `testHeavyLossFallsBackToNACKBeyondFEC` — ~10 % seeded loss: FEC closes the
    single-loss groups, NACK refills the multi-loss ones, no torn frames, and
    `nacks > 0` proves the layered handoff.
  - `testParityLossIsHarmless` — drop only parity datagrams: outcome identical
    to today's NACK loop.
  - `testLateOriginalAfterFECRecoveryIsHarmless` — recovery then the reordered
    original: no duplicate AU, no scheduler regression.
  - HEVC sibling of the first case via the existing `buildHEVCStream` builder.
- **Live validation (local-only, per CLAUDE.md):**
  `sudo ./scripts/net-impair.sh up --loss 3 --delay 200` (delay chosen to trip
  the 150 ms gate) + `./test-local.sh 2`; watch the overlay: FEC-recovered
  rising, NACKs-sent near zero (vs. the merged behavior where NACKs rise),
  PLIs ≈ 0, bitrate holding. Then `--delay 40` to confirm the gate keeps FEC
  *off* on fast paths. Always `net-impair.sh down`.

## Risks & pitfalls

- **Marker/timestamp reconstruction is load-bearing.** If the parity body ever
  omitted byte 1 or the timestamp, a recovered marker packet would silently
  merge two AUs (timestamp-change corruption path, RTPPacket.swift:745-752).
  The per-position round-trip tests exist to pin exactly this.
- **Recovery must be indistinguishable from reception downstream.** Any second
  path around `processVideoPacket` (e.g. feeding the depacketizer but not
  `recordRRPacket`) re-creates the over-reacting-controller bug this plan's
  accounting rules exist to prevent.
- **Oscillation without the extended RR field.** Residual-only feedback turns
  FEC into a thermostat with the sensor outside the room. The `fecRecovered`
  field is not optional polish; the anti-oscillation test pins it.
- **Overhead must ride inside the congestion-controlled rate.** Skipping the
  N/(N+1) bitrate compensation makes FEC *add* 10–20 % load precisely on lossy
  links — worse than no FEC. Compensation goes through `applyAdaptiveBitrate`
  so the hysteresis clock and keyframe-on-downstep behavior stay consistent.
- **Groups must never span batches.** The throttled-viewer seq-space argument
  (Server.swift:3200-3214) makes this a correctness rule, not a preference;
  `groupRanges` operating on a single batch's template array enforces it
  structurally.
- **Scheduler tolerance loosening is FEC-mode-only.** Raising
  `reorderPacketTolerance` globally would delay NACK on non-FEC sessions for
  nothing; it's keyed off the negotiated `.fec` + active parity, and
  `NACKSchedulerTests` pins both modes.
- **Buffer-pool interaction.** Parity is computed synchronously in `broadcast`
  from the live `templates` array before the send chains run — no retention,
  so no COW pressure on `RTPPacketBufferPool` (unlike `RetransmitBuffer`,
  which copies for exactly that reason, RetransmitBuffer.swift:16-20).
- **CLAUDE.md constraints:** new control byte stays ≤ 0x7F; port 7447 stays
  hardcoded; no TailscaleKit edits (PacketListener suffices); tsnet
  suites stay local-only (everything new here is pure); new networking state
  follows the existing lock conventions, pure types are plain `Sendable`;
  CLAUDE.md protocol/test-list updates land in the same commit.
- **Deviations from the phase-1 sketch, recorded:** FEC byte is **0x0D** (the
  sketch's 0x0C was taken by PING at merge); the wire header uses
  `count` instead of `mask` + `xorLen` (groups are contiguous by construction);
  the parity body covers byte 1 + timestamp + length, not payload-only (the
  sketch's payload-only XOR could not reconstruct the marker packet); and the
  on-gate keeps the sketch's RTT > 150 ms ∧ loss > 2 % criteria unchanged.

## Estimated scope

**M.** ~550 LOC source (wire ~60, FECCodec ~120, FECGroupBuffer ~130, server
~140, client ~80, stats ~20) + ~600 LOC tests. No helper-wire, encoder, or
TailscaleKit changes; no new subprocess surface.

## Post-review amendments (implemented; deviations from the design above)

- **Parity is interleaved per group**, not sent after the whole batch: each
  group's parity goes out immediately behind that group's last media packet
  inside the same send-chain job. Batch-trailing parity defeated FEC for its
  target case — a multi-hundred-packet keyframe evicts early groups from the
  viewer's bounded `FECGroupBuffer` before their parity arrives, and leaves
  early gaps NACK-eligible long before recovery data is on the wire.
- **`groupRanges` balances group sizes** (⌈count/N⌉ groups, sizes ±1) instead
  of greedy chunking, so no sub-`minGroupSize` remainder is ever left
  uncovered — in particular the AU's marker packet is always parity-covered.
- **Recovery advances the NACK scheduler** (`noteRecovered`, superseding the
  bare `cancelGap` for the recovery path): a recovered tail-of-batch (marker)
  seq is ahead of every wire packet, and without advancing `highestSeq` the
  next batch's first packet re-opened a phantom gap for the already-recovered
  seq (spurious NACK, possible PLI escalation).
- **The FEC decision is per-viewer first** (`fecSweepDecision`): a viewer
  gates only when its own path passes both on-gates; FEC turns on iff the
  gated set is non-empty; the ladder reads the gated viewers' worst raw loss;
  and each viewer's recovered count converts against its own expected packet
  count (multi-viewer sums don't inflate, throttled viewers' gates stay
  stable). Encoder compensation applies only while the gated set is non-empty
  (never for a gray-zone-held N), forces a keyframe when it turns on, is
  clamped to the scaled adaptive floor, and is re-pushed after every helper
  (re)spawn.
- **The viewer arms FEC on evidence, not negotiation**: relaxed scheduler
  tolerances (switched in place, preserving gaps + the RTT estimate) and
  media buffering start on the first 0x0D received and disarm after ~3 s
  without parity — zero cost client-side on clean links even though the
  server always advertises `.fec`.
- **Known property (recorded, not a bug):** the bitrate arm sees residual
  loss only, so on a congestion-limited link FEC can mask loss → clean-window
  up-ramp → re-induced loss: a slow sawtooth bounded by the up-hysteresis.
  The `fecRecovered` RR term de-oscillates only the FEC arm by design;
  feeding raw loss to the bitrate arm would double-penalize repaired loss.
