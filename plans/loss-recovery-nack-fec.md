# NACK-based selective retransmission (+ deferred FEC) and receiver-feedback congestion control

> Status: proposed — this PR contains only the plan; implementation is a follow-up iteration.

## Problem & motivation

Today the only loss-recovery tool is the PLI: any unrecoverable sequence gap drops the whole access unit and asks the encoder for a fresh IDR. On a lossy WAN/DERP path this is loss amplification — a single ~1100-byte packet lost out of a multi-packet frame (`H264Packetizer.maxPayloadBytes`, Sources/RTPPacket.swift:199) costs a full keyframe (often 1–2 MB, fragmenting into hundreds of packets, each of which can be lost again). The client's own comment admits this ("a PLI per dropped frame is a loss-amplification loop", Sources/TailscaleScreenShareClient.swift:473-477). Congestion control is equally blunt: the server's only signal is PLI counts, and its only lever is bitrate (fps is pinned at 60: Sources/ScreenCapture.swift:235, Sources/CaptureHelperMain.swift:387). There is no RTT, no loss fraction, no receive-rate estimate. Retransmitting the one missing packet (NACK) recovers loss at ~1 RTT for ~0.1 % of the bandwidth cost of a keyframe, and an RTCP-RR-style report gives the bitrate controller real inputs.

## Goals / Non-goals

**Goals**
- Viewer detects sequence gaps and requests selective retransmission (NACK) over the existing UDP control channel; server retransmits from a bounded ring of recently sent packets.
- PLI remains the fallback (gap too old for the ring, NACK budget exhausted, legacy peer).
- Periodic receiver report (loss fraction, extended highest seq, jitter, RTT echo) feeds an evolved `nextAdaptiveBitrate`, plus an fps downshift ladder (60→30→15) as a second congestion lever.
- Full backward compatibility: old viewers ↔ new server and new viewer ↔ old server keep today's PLI-only behavior.
- All new decision logic CI-testable per CLAUDE.md's extract-pure-decisions rule.

**Non-goals**
- FEC ships as a later phase (design sketched, not implemented in phase 1).
- No RFC 4588 RTX SSRC/PT multiplexing — retransmits are byte-identical resends (the receiver's `RTPReorderBuffer` already dedups and gap-fills, Sources/RTPPacket.swift:392-414).
- No changes to audio (PT 98) or the TCP annotation/metadata channel. No TailscaleKitPackage patches needed (PacketListener send/recv suffices).

## Current state (with file:line references)

- **Control-byte space.** All non-RTP datagrams on UDP/7447 start with a byte in 0x00–0x7F (`ScreenShareControlMessage`, Sources/RTPPacket.swift:28-62); 0x00–0x07 are used (HELLO…CODEC_NO). PLI is byte 0x03 (RTPPacket.swift:32). `decode` looks at only the first byte (RTPPacket.swift:52-55), so payload-extended control messages are forward-compatible. `decodeHelloAck` requires exactly 5 bytes (RTPPacket.swift:73-76) — old viewers reject a longer HELLO_ACK.
- **Client loss path.** `receiveLoop` parses the RTP header per datagram (TailscaleScreenShareClient.swift:444-467), feeds the depacketizer, and when an AU arrives with `lostBeforeThisAU` sends a PLI, throttled to one per 100 ms (~10/s) (TailscaleScreenShareClient.swift:469-483, 573-577). Loss is detected only *after* the reorder window gives up: `RTPReorderBuffer` (default `maxDepth: 16` packets, RTPPacket.swift:368-375; hardcoded via depacketizer inits at RTPPacket.swift:473/808 and `MultiCodecDepacketizer` at RTPPacket.swift:997-999) skips the gap in `skipGap()` (RTPPacket.swift:424-433) and the depacketizer latches `pendingLossSignal` (RTPPacket.swift:525-541).
- **Server loss path.** `.pli` → `registerOrRefresh` + `recordPLI` + `helperCapture?.requestKeyframe()` (TailscaleScreenShareServer.swift:826-829). PLIs land in a per-viewer 32-entry ring via pure `appendingPLI` (Server.swift:914-921, ring field Server.swift:89).
- **Adaptive bitrate.** `adaptiveBitrateSweep` polls every 5 s, takes the worst per-viewer PLI count (Server.swift:1369-1413); pure `nextAdaptiveBitrate` cuts −25 % when PLIs > 2/5 s (5 s down-hysteresis), recovers +10 % after a clean window (10 s up-hysteresis), floor = max(30 % baseline, 500 kbps) (Server.swift:1425-1442). Applied via `helperCapture?.setBitrate` + keyframe on down-step (Server.swift:1448-1462). Baseline is anchored as `width × height × bpp × 60.0` — fps hardcoded (Server.swift:500-505).
- **Fan-out.** `broadcast` packetizes once into `templates` with seq=0/ssrc=0 (Server.swift:1500-1511), reserves a contiguous per-viewer seq range atomically (`Plan`, Server.swift:1513-1526), then per-viewer send chains rewrite only bytes 2-3 (seq) and 8-11 (SSRC) via `rewriteRTPHeader` (Server.swift:1581-1588). Payload bytes are identical for every viewer. A viewer >4 frames behind has the frame dropped but its seq range still reserved ("the gap reads as loss and the viewer's PLI fetches a fresh keyframe", Server.swift:1539-1544, cap at Server.swift:175). Templates are pooled/recycled across broadcasts (`RTPPacketBufferPool` COW argument, RTPPacket.swift:207-216).
- **Encoder control.** Main→helper wire has `requestKeyframe = 0x01`, `setBitrate = 0x02`, `contentFilter = 0x03`, `shutdown = 0xFF` (Sources/CaptureHelperWire.swift:60-76), dispatched in CaptureHelperMain.swift:98-102 → `VideoEncoder.setBitrate`/`requestKeyframe` (VideoEncoder.swift:233-245). Keyframe interval is a safety net at fps×10 (VideoEncoder.swift:193-195). SCStream is fixed at 1/60 s `minimumFrameInterval` (ScreenCapture.swift:235).
- **Test harness.** `LossyChannel` (Tests/TailscreenTests/LossyChannel.swift:34-86) is the seeded, CI-able impairment transform; `RTPLossyChannelTests` runs packetize → impair → depacketize and asserts no torn frames + loss signaled (Tests/.../RTPLossyChannelTests.swift:141-220+); `AdaptiveBitrateTests` pins `nextAdaptiveBitrate` (Tests/.../AdaptiveBitrateTests.swift:20-69). Live validation is `scripts/net-impair.sh` (local-only); tsnet suites can't run on CI (CLAUDE.md).

## Design

### Wire changes (all on the existing UDP/7447 control byte space; new bytes stay ≤ 0x7F so `looksLikeControl` RTPPacket.swift:59-62 is untouched)

- **Capability negotiation via extended HELLO/HELLO_ACK.** New viewer sends `[0x00][caps:1]` (bit0 = NACK, bit1 = RR). Old servers ignore the payload (`decode` reads byte 0 only). Server records caps per viewer; to cap-advertising viewers only, it replies `[0x04][ssrc:4][serverCaps:1]` (6 bytes). Old viewers never see the extended ack (their `decodeHelloAck` would reject ≠5 bytes, RTPPacket.swift:73-76). Viewer enables NACK mode only after seeing server caps — new-viewer↔old-server degrades to PLI automatically (old server's `decode` returns nil for 0x08+ and `handleIncoming` drops it, Server.swift:790).
- **`0x08 NACK` (viewer→server):** `[0x08][count:1][(pid:2 BE, blp:2 BE) × count]`, RTCP-generic-NACK FCI semantics (pid = first missing seq in *that viewer's* seq space, blp = bitmask of the following 16). Cap count ≤ 16 (69 bytes max).
- **`0x09 RR` (viewer→server, ~1 Hz):** `[0x09][fracLostQ8:1][extHighestSeq:4][jitterTicks:4][lastPingTs:8][delaySincePingMs:2]`.
- **`0x0A PING` (server→viewer, ~1 Hz, piggybacked on the idle sweep):** `[0x0A][serverUptimeNs:8]`. Viewer echoes it in RR; server computes RTT = now − lastPingTs − delay.
- **Retransmissions** are byte-identical RTP resends (same seq/ssrc/PT/timestamp) — the reorder buffer gap-fills or drops them as duplicates/stragglers (RTPPacket.swift:392-414); no new packet type.
- **Phase-3 FEC (deferred): `0x0C FEC`** `[0x0C][baseSeq:2][mask:2][xorLen:2][xor-payload]` — XOR of the RTP *payloads* (+ a length word) of the covered packets. Payloads are viewer-identical (only header bytes differ per viewer), so one XOR body is computed once and sent per viewer with per-viewer `baseSeq`.

### Sender (server) changes

- **New `RetransmitBuffer` (new file `Sources/RetransmitBuffer.swift`, `@unchecked Sendable` with an internal lock per repo convention).** Shared across viewers because payloads are identical: stores per broadcast a `batchID → (templates: [Data], rtpTs)`. Each viewer's `Viewer` struct (Server.swift:80-90) gains a small ring of `(startSeq: UInt16, count: UInt16, batchID)` recorded from the existing `Plan` snapshot (Server.swift:1513-1526). Lookup: viewer seq → wrap-safe offset into the batch. Sizing: evict by **time window (1 s), byte cap (4 MB ≈ 1 s of a 32 Mbps 4K stream), and batch count (128)** — whichever trips first; all three are constructor parameters so tests pin them. Pool interaction: retaining templates keeps their refcount >1, so `RTPPacketBufferPool` COWs instead of recycling (RTPPacket.swift:207-216) — correct but defeats pooling; the ring therefore stores its own `Data` copies made after `broadcast` returns (cheap relative to the UDP sends). Frames shed by the `maxQueuedVideoFramesPerViewer` cap (Server.swift:1539-1544) are still registered per viewer, so a NACK can recover an intentionally dropped frame — subject to budget.
- **NACK service in `handleIncoming`** (new case in the switch at Server.swift:792-843): decode pid+blp → for each requested seq, look up the viewer's ring index → copy template, `rewriteRTPHeader` with that seq + viewer SSRC (Server.swift:1581-1588) → send on a dedicated per-viewer retransmit tail (same chained-Task pattern as `videoSendTails`, Server.swift:166-175, so retransmits never block fresh frames).
- **Retransmission budget:** pure `static func retransmitDecision(requested:[UInt16], ringHas:(UInt16)->Bool, tokens:inout Double, nowNs:UInt64, ...) -> (serve:[UInt16], fallbackPLI:Bool)` — token bucket capped at 25 % of `currentBitrate`; any seq not in the ring, or a request over budget, converts to the existing PLI path (`recordPLI` + `requestKeyframe`, Server.swift:826-829) so recovery is never worse than today.

### Receiver (client) changes

- **New `NACKScheduler` (new file `Sources/NACKScheduler.swift`), a pure Sendable struct** — the CI-testable core. Fed `(seq, nowNs)` per received video packet (the client already parses the header at TailscaleScreenShareClient.swift:456); maintains the missing-set and emits actions: `sendNACK([seq])`, `sendPLI`, `none`. Rules: a gap becomes NACK-eligible only after **reorder tolerance** (gap older than 15 ms *or* ≥3 newer packets seen — pure reordering must produce zero NACKs, mirroring `RTPReorderBuffer`'s tolerance); re-NACK at `max(1.5 × RTT, 40 ms)` up to 3 attempts; then, or when the gap age exceeds the server ring window (1 s), emit `sendPLI` and abandon the seq. Global cap ~50 NACK datagrams/s.
- **Integration in `receiveLoop`:** feed the scheduler before `depacketizer.ingest`; send NACKs via the existing `packetListener`. The existing `lostBeforeThisAU` → PLI path (Client.swift:469-483) stays but is gated: in NACK mode it fires only for gaps the scheduler already abandoned (the 100 ms throttle at Client.swift:573-577 is kept as the last-resort cap).
- **Deeper reorder window in NACK mode:** retransmits must land before the window overflows; at 60 fps the current 16-packet depth is only ~3–8 frames (~50–130 ms) — shallower than one WAN RTT. Plumb `reorderDepth` through `MultiCodecDepacketizer` (RTPPacket.swift:997-1011) and use 128 when the server advertised NACK support, plus a gap-age bound (skip a gap older than 250 ms even if the window isn't full) so an abandoned loss can't stall rendering indefinitely. Happy path stays latency-free (RTPPacket.swift:350-353).
- **Stats overlay:** add NACKs sent / packets recovered / RTT rows next to the existing byte/codec counters (`MetalViewerRenderer.noteReceivedBytes`/`noteCodec`, Sources/MetalViewerRenderer.swift:261-270) — this is also how net-impair validation is observed per CLAUDE.md.

### Congestion control

- **New pure `static func nextCongestionDecision(_ inputs: CongestionInputs) -> CongestionDecision`** in the server (same extract-the-decision pattern as `nextAdaptiveBitrate`, Server.swift:1425-1442). Inputs: worst per-viewer RR loss fraction, worst RTT + trend, NACK-served count, PLI count (legacy viewers still only produce PLIs), current/baseline bitrate, current fps tier, elapsed since change. Output: `bitrate: Int?` and `fpsTier: Int?` (60/30/15). Policy: loss fraction > 10 % → −25 % cut (existing hysteresis constants); 2–10 % → hold; < 2 % clean → +10 % recovery. NACK-recovered loss weighs half a PLI (it cost one packet, not a keyframe). Legacy-viewer PLI counts map onto the same scale so `AdaptiveBitrateTests` semantics survive; `nextAdaptiveBitrate` remains as the legacy-input shim.
- **fps ladder (second lever):** when bitrate is at the floor and the window is still lossy → 60→30, then 30→15; recovery restores fps *before* letting bitrate climb past ~60 % of baseline (frame rate hurts less than blocking artifacts). New wire command `case setFrameInterval = 0x04` in `CaptureHelperWire.InType` (CaptureHelperWire.swift:60-76) `[fps:4 BE]`; `HelperControlWriter.sendFrameInterval` (CaptureHelperWire.swift:216-243); dispatch in CaptureHelperMain.swift:98-102 → `SCStream.updateConfiguration` with the new `minimumFrameInterval` (config built at ScreenCapture.swift:235; runs in the helper — never the main process, per CLAUDE.md) and `VideoEncoder` fps-dependent properties (data-rate window from `computeBitrate`, VideoEncoder.swift:209-210; `MaxKeyFrameInterval` fps×10, VideoEncoder.swift:193-195). Also fix the baseline anchor's hardcoded `× 60.0` (Server.swift:503) to track the fps tier so the ceiling scales down with fps.

### Phasing — NACK first, FEC later

1. **Phase 1 (this plan's implementation steps):** capability handshake, NACK/RR/PING wire, RetransmitBuffer, NACKScheduler, RR-driven congestion decision.
2. **Phase 2:** fps ladder (isolated: touches only the helper wire + decision func; can land with phase 1 if review load allows).
3. **Phase 3 (deferred FEC):** XOR parity per N=10 video packets (0x0C above), recovering any single loss per group with zero RTT. Deferred because (a) NACK at tailnet RTTs (usually < 100 ms direct) recovers faster than a viewer can render the gap, (b) FEC costs a constant ~10 % bandwidth exactly when bandwidth is scarce, (c) it touches the packetizer hot path. Enable adaptively only when RR-measured RTT > 150 ms (DERP-relayed) *and* loss > 2 %.

## Implementation steps

1. `Sources/RTPPacket.swift` — add `nack = 0x08`, `receiverReport = 0x09`, `ping = 0x0A` to `ScreenShareControlMessage` (:28-46) with pure `encode*/decode*` helpers (mirroring `encodeHelloAck`, :65-76); add `encodeHello(caps:)` + `decodeHelloCaps`, `encodeHelloAck(ssrc:caps:)` + tolerant decode.
2. `Sources/RTPPacket.swift` — thread `reorderDepth`/`maxGapAgeNs` through `MultiCodecDepacketizer` (:997-1011) and both depacketizer inits (:473, :808); add time-based `skipGap` trigger next to the depth trigger (:409-414).
3. New `Sources/NACKScheduler.swift` — pure struct per Design; no I/O, fully deterministic on injected `nowNs`.
4. New `Sources/RetransmitBuffer.swift` — shared batch ring + per-viewer seq index + pure `retransmitDecision` budget func.
5. `Sources/TailscaleScreenShareServer.swift` — record caps in `Viewer` (:80-90) from extended HELLO (:793-820); register batches in `broadcast` after the `Plan` snapshot (:1513-1526); add `.nack`/`.receiverReport` cases to `handleIncoming` (:792-843); send PING from `sweepIdleViewers` (:1289); store per-viewer RR stats; add `nextCongestionDecision` + rewire `adaptiveBitrateSweep` (:1369-1413) to build its inputs; fix baseline fps anchor (:503); add `onNACKServedForTesting` seam alongside `onPLIRecordedForTesting` (:294-299).
6. `Sources/TailscaleScreenShareClient.swift` — send extended HELLO (:324); parse extended HELLO_ACK (:429-435); instantiate `NACKScheduler` when server caps allow; feed it in `receiveLoop` before `ingest` (:456-469); answer PING; send RR at 1 Hz from `keepaliveLoop` (:560-569); gate the PLI path (:469-483); deepen depacketizer window.
7. `Sources/CaptureHelperWire.swift` + `Sources/CaptureHelperMain.swift` + `Sources/HelperScreenCapture.swift` + `Sources/ScreenCapture.swift` + `Sources/VideoEncoder.swift` — `setFrameInterval` command end-to-end (phase 2).
8. `Sources/MetalViewerRenderer.swift` / `Sources/ViewerStatsOverlay.swift` — NACK/RTT/recovered counters.
9. Tests (below), then update CLAUDE.md's protocol + testing sections in the same commit (its own rule).

## Files to change / add

| File | Change |
|---|---|
| `Sources/RTPPacket.swift` | new control messages, caps handshake codecs, tunable reorder window |
| `Sources/NACKScheduler.swift` (new) | pure gap-tracking / NACK / PLI-fallback state machine |
| `Sources/RetransmitBuffer.swift` (new) | shared template ring, per-viewer seq index, budget decision |
| `Sources/TailscaleScreenShareServer.swift` | NACK/RR/PING handling, batch registration, `nextCongestionDecision`, fps-aware baseline |
| `Sources/TailscaleScreenShareClient.swift` | scheduler integration, RR/PING, gated PLI, extended HELLO |
| `Sources/CaptureHelperWire.swift`, `CaptureHelperMain.swift`, `HelperScreenCapture.swift`, `ScreenCapture.swift`, `VideoEncoder.swift` | `setFrameInterval` (phase 2) |
| `Sources/MetalViewerRenderer.swift`, `ViewerStatsOverlay.swift` | new stats |
| `Tests/TailscreenTests/` | `NACKSchedulerTests.swift`, `RetransmitBufferTests.swift`, `CongestionDecisionTests.swift` (new); extend `RTPLossyChannelTests.swift`, `RTPPacketTests.swift`, `ScreenShareControlChannelTests.swift` |
| `CLAUDE.md` | protocol table, test list ("add it to this list" rule) |

## Testing strategy

- **Extend `RTPLossyChannelTests` into a closed loop (CI-able, deterministic):** packetize → `LossyChannel` (Tests/.../LossyChannel.swift:34-86) → receiver (`NACKScheduler` + depacketizer) → NACKs → test-side `RetransmitBuffer` → retransmits re-injected after a configurable delay measured in packet-steps (simulated RTT). Assertions: `testLossRecoveredByNACKWithoutPLI` (≤3 % loss, zero `lostBeforeThisAU`, zero PLIs, no torn frames — reusing `assertIntactAndOrdered`, RTPLossyChannelTests.swift:120-137); `testPureReorderProducesNoNACKs`; `testNACKFallsBackToPLIWhenRingEvicted`; `testRetransmitDuplicatesAreHarmless`; HEVC siblings via the existing builders (:48-67).
- **Pure-decision tests (CI):** `NACKSchedulerTests` (reorder tolerance, retry cadence vs injected RTT, PLI fallback on ring-age/budget, rate cap); `RetransmitBufferTests` (seq→template lookup incl. UInt16 wrap, triple eviction, budget math); `CongestionDecisionTests` (loss-fraction cut/hold/raise bands, NACK-vs-PLI weighting, fps-ladder transitions + hysteresis, legacy-PLI-input parity so `AdaptiveBitrateTests` keep passing unchanged).
- **Wire-codec tests in `RTPPacketTests`:** NACK/RR/PING encode-decode round trips; extended HELLO/HELLO_ACK back-compat (assert legacy 5-byte `decodeHelloAck` rejects the 6-byte form — that's the compat mechanism, RTPPacket.swift:73-76).
- **Local E2E (not CI — tsnet, per CLAUDE.md):** extend `ScreenShareControlChannelTests` with a `sendNACKForTesting` seam asserting `onNACKServedForTesting` fires, mirroring the existing PLI seam (Server.swift:294-299, Client.swift:233-236).
- **Live validation (local-only):** `sudo ./scripts/net-impair.sh up --loss 3 --delay 80` + `./test-local.sh 2`; observe in the stats overlay: NACK-recovered count rising, PLI count near zero (vs. today's steady climb), bitrate holding higher; `--delay 200` to confirm DERP-ish RTT still converges; always `net-impair.sh down`.

## Risks & pitfalls

- **Reorder-window depth vs. stall:** a deeper window only delays packets *behind an open gap*; an abandoned loss could stall render for the full window — the gap-age bound (250 ms) in step 2 is load-bearing, not optional.
- **Retransmit storms:** a slow viewer NACKing frames the send-chain cap deliberately shed (Server.swift:1539-1544) re-adds the load we shed; the 25 % token bucket and PLI conversion are mandatory, not tuning.
- **Buffer-pool interaction:** retaining broadcast templates blocks `RTPPacketBufferPool` recycling via COW (RTPPacket.swift:207-216); the ring must own copies and the allocation delta should be checked under `make test-e2e-local`.
- **Per-viewer seq spaces:** the ring index is per viewer (random `nextSequence` start, Server.swift:1008); all arithmetic must be `&-`/`&+` wrap-safe like `RTPReorderBuffer`.
- **CLAUDE.md constraints:** tsnet suites are local-only (CI runs only the pure-logic suites — everything new here except the E2E seam must be pure); SCStream reconfiguration for the fps ladder happens **only in the capture helper** (never `SCShareableContent`/SCStream in the main process); port 7447 stays hardcoded; new control bytes must stay ≤ 0x7F for `looksLikeControl`; don't edit `TailscaleKitPackage/Sources` (no patch needed — `PacketListener` already suffices); Swift 6 — new networking types follow the `@unchecked Sendable` + internal-lock convention, pure structs are plain `Sendable`; update CLAUDE.md protocol/testing sections in the same commit.
- **Compat matrix must be tested explicitly:** old-viewer↔new-server (PLI path untouched, Server.swift:826-829), new-viewer↔old-server (0x08 dropped by `decode` nil → `handleIncoming` guard, Server.swift:790; viewer stays in PLI mode absent server caps).

## Estimated scope

**L.** Phase 1 (NACK + RR + congestion decision): ~1,100 LOC source (scheduler ~150, ring ~180, wire ~120, client ~180, server ~300, stats ~60, misc ~110) + ~800 LOC tests. Phase 2 (fps ladder): ~150 source + ~100 tests. Phase 3 (FEC): ~400 source + ~250 tests, deferred. Total landed over phases 1–2: ~2,150 LOC.
