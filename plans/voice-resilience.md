# Voice-path resilience: retryable decoder failures, adaptive jitter buffer, loss handling

> Status: implemented in this PR.

## Problem & motivation

The voice path (AAC-LC mono 48 kHz over RTP/UDP 7447, one AU per packet) is functional but brittle
in exactly the conditions `scripts/net-impair.sh` simulates:

1. **A single decoder-init failure permanently mutes a peer.** `VoiceChannel.receive` blacklists an
   SSRC forever (`Sources/VoiceChannel.swift:91-97`) on the first `AACDecoder()` init throw. Init can
   fail for transient reasons (`AACCodecError.converterCreate` under AudioToolbox resource pressure,
   `missingMagicCookie` if the throwaway encoder alloc fails once — `Sources/AACCodec.swift:242-244,
   254-257`). The blacklist is only cleared by `reset()` at session end (`Sources/VoiceChannel.swift:109-114`),
   so one bad moment silences that participant for the whole share.
2. **The jitter buffer is fixed and blind.** Playback starts after 3 queued buffers
   (`jitterBufferThreshold`, `Sources/VoiceChannel.swift:708`) and hard-caps at 6
   (`maxPendingBuffers`, `:718`); overflow silently drops the *incoming* buffer
   (`Sources/VoiceChannel.swift:727`). ~64 ms of headroom is right for LAN, wrong for an 80 ms-RTT
   lossy WAN path, and there is no measurement to tell us which world we're in — no underrun or
   overrun counters exist anywhere.
3. **Lost packets simply vanish.** `AudioRTPDepacketizer` parses `sequenceNumber`
   (`Sources/RTPAudio.swift:45,58`) but `VoiceChannel.receive` never reads it
   (`Sources/VoiceChannel.swift:72-105`): no gap detection, no concealment, no
   duplicate/reorder rejection. A lost AU is 21.3 ms of missing audio plus an MDCT
   overlap-add discontinuity (audible click) at the gap boundary.
4. **Clamping masks codec bugs.** Every decoded sample is clamped to [-1, 1]
   (`Sources/VoiceChannel.swift:87`). The comment (`:81-86`) documents peaks of ~6.0 — that clamp is
   load-bearing, but it fires invisibly, so a regression that clips constantly (e.g. the 3ch→1ch
   downmix bug the comment references) would ship silently.

## Goals / Non-goals

**Goals**
- Broken-SSRC entries become retryable with cooldown + a permanent cap, as a pure decision function.
- Jitter buffer depth adapts to observed inter-arrival jitter, with bounded growth and explicit
  underrun/overrun counters.
- Sequence-gap detection with minimal PCM-side concealment (bounded silence fill) and
  duplicate/reorder rejection.
- Clamp instrumentation: count clamped buffers, log at threshold crossings.
- All new decision logic CI-able (no tsnet, no real audio hardware), per CLAUDE.md's
  extract-the-decision pattern.

**Non-goals**
- No FEC, no RED, no NACK/retransmit for audio (UDP loss stays accepted, per the protocol section of
  CLAUDE.md).
- No change to the wire format, payload type (98), or SSRC-assignment/relay protocol
  (`TailscaleScreenShareServer.audioRelayDecision`, `Sources/TailscaleScreenShareServer.swift:873-882`).
- No true codec-level PLC: AudioToolbox's `AudioConverter` API exposes no error-concealment input
  path (there is no "decode this AU as corrupt" flag on `AudioConverterFillComplexBuffer`,
  `Sources/AACCodec.swift:289-345`), so concealment is PCM-side.
- No changes outside `VoiceChannel.swift` / `AACCodec.swift` / `RTPAudio.swift` + tests.

## Current state (with file:line references)

- **Blacklist**: `brokenSSRCs: Set<UInt32>` (`Sources/VoiceChannel.swift:45`), checked at `:77`,
  inserted at `:94` on decoder-*init* failure only; decode failures keep the decoder (`:98-102`).
  Cleared only in `reset()` (`:109-114`).
- **Decode path**: `receive(_:)` (`:72-105`) — unpack → self-loopback drop (`:76`) → blacklist gate
  (`:77`) → `ensureDecoder` (`:116-121`) → `decode` → clamp (`:87`) → `onMixedPCM` (`:88`).
  `parsed.sequenceNumber` and `parsed.timestamp` are discarded.
- **Playback / jitter buffer**: `MicCapture.scheduleSamples` (`:725-752`): drop-newest at
  `maxPendingBuffers` (`:727`), `pendingBuffers` counted via schedule/completion (`:723,740-747`),
  deferred `player.play()` after `jitterBufferThreshold` (`:749-751`). All `@MainActor`.
- **Packetizer clocking**: seq +1 and RTP timestamp +1024 per AU (`Sources/RTPAudio.swift:33-34`),
  i.e. one AU == 1024 samples == 21.33 ms; a seq gap of N == exactly N×1024 missing samples.
- **Decoder priming**: first decode may return <1024 or 0 samples (`Sources/AACCodec.swift:286-288`,
  `VoiceChannelTests.swift:38` "encoder primer drops first AU") — any gap logic must not confuse
  priming with loss.
- **Ingress points**: viewer side `TailscaleScreenShareClient` routes PT=98 to `onAudioReceived`
  (`Sources/TailscaleScreenShareClient.swift:443-447`); sharer side
  `TailscaleScreenShareServer.handleInboundAudioRTP` (`Sources/TailscaleScreenShareServer.swift:888-909`).
  Both feed `VoiceChannel.receive` unchanged — this plan needs no changes there.
- **Existing tests**: `VoiceChannelTests` (encode→RTP→decode round trip), `RTPAudioTests`
  (packetizer/depacketizer incl. seq wraparound, `Tests/TailscreenTests/RTPAudioTests.swift:35-44`),
  `LossyChannel` (deterministic seeded loss/reorder/dup, `Tests/TailscreenTests/LossyChannel.swift`,
  documented in CLAUDE.md as reusable by any in-process packet test).

## Design

### (a) Retry-after-cooldown blacklist (pure decision function)

Replace `brokenSSRCs: Set<UInt32>` with `[UInt32: DecoderFailureRecord]`:

```swift
struct DecoderFailureRecord: Equatable {
    var consecutiveInitFailures: Int
    var lastFailureNs: UInt64
}

enum BlacklistAction: Equatable { case allow, drop }

/// Pure: drop while inside the cooldown window; allow a retry once it
/// elapses; drop forever after `permanentAfter` consecutive failures.
static func blacklistAction(
    record: DecoderFailureRecord?,
    nowNs: UInt64,
    cooldownNs: UInt64 = 5_000_000_000,     // 5 s between retries
    permanentAfter: Int = 5                 // then give up for the session
) -> BlacklistAction
```

Semantics: `nil` record → `.allow`. `consecutiveInitFailures >= permanentAfter` → `.drop` (permanent,
matches today's behavior after 5 strikes ≈ 25 s of trying). Otherwise `.drop` until
`nowNs - lastFailureNs > cooldownNs`, then `.allow` (one retry attempt; a failure re-arms the
cooldown and increments the count — so logging stays ≤1 line per 5 s, preserving the
"don't spam stderr at 50 Hz" property the blacklist exists for, `Sources/VoiceChannel.swift:92-93`).
A *successful* `ensureDecoder` + first non-throwing `decode` removes the record entirely.

### (b) Adaptive jitter buffer with counters

`VoiceChannel` computes RFC 3550-style smoothed inter-arrival jitter on its serial queue (it has both
the RTP timestamp and the arrival clock): `J += (|D| - J) / 16`, where `D` compares arrival-time
delta against RTP-timestamp delta (48 kHz units → ms). A pure sizing function converts jitter to a
target depth:

```swift
/// Pure: target queue depth in 21.33 ms buffers. One buffer of slack per
/// ~21 ms of smoothed jitter, +1 base; clamped to [2, 12]; only moves one
/// step per call (bounded growth, no oscillation).
static func jitterBufferTarget(smoothedJitterMs: Double, currentTarget: Int,
                               minDepth: Int = 2, maxDepth: Int = 12) -> Int
```

`MicCapture` replaces the two `let`s (`:708,:718`) with a `targetDepth` (initial 3) and
`maxPending = targetDepth + 3`, refreshed from the channel via a new thread-safe getter
(`VoiceChannel.currentJitterTargetDepth`, read in `scheduleSamples` — cheap `queue.sync` read or an
`OSAllocatedUnfairLock`-published value to avoid sync-on-MainActor; prefer the lock). Max depth 12
buffers ≈ 256 ms bounds added latency.

Counters (new `VoiceStats` value struct, lock-published from `VoiceChannel`/`MicCapture`):
- `overrunDrops`: increment in the existing drop branch (`:727`), currently silent.
- `underruns`: in the completion handler (`:744-746`), when `pendingBuffers` hits 0 while
  `player.isPlaying` — that is the audible starve.
- plus `concealedFrames`, `discontinuities`, `clampedBuffers`, `smoothedJitterMs` (below).
Logged once per minute via the existing `TSLogger` (`Sources/VoiceChannel.swift:771-777`).

### (c) Minimal loss concealment (sequence-gap handling)

Per-SSRC `lastSequence: UInt16?` tracked next to the decoder map. Pure decision:

```swift
enum GapAction: Equatable {
    case decode                    // in order
    case dropStale                 // duplicate or reordered-late: do not decode
    case concealThenDecode(missing: Int)  // fill gap, then decode
    case discontinuity             // gap too large: resync, count it, no fill
}
static func gapAction(lastSeq: UInt16?, newSeq: UInt16, maxConcealFrames: Int = 5) -> GapAction
```

Wrap-aware via `UInt16` two's-complement delta (`newSeq &- expected`; delta in `1...maxConceal` →
conceal; delta 0 or in the "behind" half-space (> 0x8000) → `.dropStale`; larger → `.discontinuity`).
On `.concealThenDecode(n)`: emit `n × 1024` samples of silence through `onMixedPCM` *before* the
decoded frame, with a short linear fade-out over the last ~64 samples of the previously emitted
frame's tail and fade-in on the new frame to mask the MDCT-discontinuity click (VoiceChannel keeps a
copy of the last emitted 64 samples per SSRC for this). Cap 5 frames ≈ 107 ms keeps a long outage
from scheduling a wall of silence; beyond that we resync (`.discontinuity`) — the playback side
already tolerates cadence gaps (the player node emits silence when unscheduled). Since AudioToolbox
exposes no concealment input (verified: `AudioConverterFillComplexBuffer` input callback has no
corrupt-frame affordance, `Sources/AACCodec.swift:308-338`), the decoder is *not* fed anything for
lost AUs; only its next real AU. Priming safety: `lastSequence == nil` (first packet per SSRC) is
always `.decode` — priming's short/empty output (`Sources/AACCodec.swift:286-288`) never enters the
gap math because gaps are keyed on sequence numbers, not sample counts.

### (d) Clamp instrumentation

In `receive` (`:87`): compute `hadOutOfRange` while clamping (single pass, no extra allocation:
replace `raw.map` with a loop that also ORs a flag). If true, `clampedBuffers += 1`. Pure helper
`static func shouldLogClamp(count: Int, threshold: Int = 50, every: Int = 1000) -> Bool` — log at the
first crossing of `threshold` and then every `every` buffers, so a persistent clipping regression is
visible without 50 Hz spam.

## Implementation steps (ordered checklist)

1. [x] `Sources/VoiceChannel.swift`: add `DecoderFailureRecord`, `BlacklistAction`, and
   `static func blacklistAction(...)` (internal, not private — test seam convention per CLAUDE.md).
2. [x] Replace `brokenSSRCs: Set<UInt32>` (`:45`) with `decoderFailures: [UInt32: DecoderFailureRecord]`;
   rewrite the gate at `:77` to call `blacklistAction`; on init-failure (`:91-97`) upsert the record
   (increment + timestamp) and log once per transition; clear the record after the first successful
   decode for that SSRC. Update `reset()` (`:109-114`).
3. [x] Add `GapAction` + `static func gapAction(lastSeq:newSeq:maxConcealFrames:)`; add per-SSRC
   `lastSequence` and last-64-samples tail storage; wire into `receive` before `ensureDecoder`:
   `.dropStale` returns early, `.concealThenDecode` emits fade-masked silence via `onMixedPCM`,
   `.discontinuity` resyncs and counts.
4. [x] Add RFC 3550 jitter estimator (per-SSRC, on the queue) + `static func jitterBufferTarget(...)`;
   publish `currentJitterTargetDepth` and `VoiceStats` via `OSAllocatedUnfairLock`.
5. [x] `MicCapture`: convert `jitterBufferThreshold` (`:708`) / `maxPendingBuffers` (`:718`) to
   adaptive `targetDepth` read in `scheduleSamples`; add `overrunDrops` increment at `:727` and
   `underruns` detection in the completion handler (`:744-746`).
6. [x] Clamp instrumentation in `receive` (`:81-89`) + `shouldLogClamp`; fold counters into
   `VoiceStats`; add a 60 s stats log line (guarded so it only logs when any counter moved).
7. [x] New test file `Tests/TailscreenTests/VoiceResilienceDecisionTests.swift` (see Testing).
8. [x] Extend `Tests/TailscreenTests/VoiceChannelTests.swift` with a `LossyChannel`-driven
   end-to-end case (packetize → seeded loss/reorder/dup → `receive`), asserting concealment counters
   and that audio keeps flowing.
9. [x] Update CLAUDE.md's pure-decision-test list ("When you extract a new pure decision … add it to
   this list") with the new suite, same commit.

## Files to change / add

- `Sources/VoiceChannel.swift` — blacklist rework, gap handling, jitter estimator, counters,
  adaptive depth in `MicCapture`. (Bulk of the change.)
- `Sources/RTPAudio.swift` — no functional change expected; `Parsed` already carries
  `sequenceNumber`/`timestamp` (`:44-48`). Only touched if a helper for seq-delta lands here.
- `Sources/AACCodec.swift` — no functional change; optionally tag `AACCodecError` cases with a
  `isRetryableInit` hint (converterCreate/missingMagicCookie retryable; setMagicCookie retryable).
- `Tests/TailscreenTests/VoiceResilienceDecisionTests.swift` — new.
- `Tests/TailscreenTests/VoiceChannelTests.swift` — extended.
- `CLAUDE.md` — test-list bookkeeping.

## Testing strategy

**CI-able pure-decision tests** (pattern: `AdaptiveBitrateTests` / `ViewerLifecycleDecisionTests`):
- `blacklistAction`: allow when no record; drop inside cooldown; allow exactly after cooldown;
  permanent after N consecutive failures; success clears (tested via VoiceChannel integration case).
- `gapAction`: in-order; dup (`delta 0`); reordered-late; gap of 1..5 → conceal; gap of 6 →
  discontinuity; wraparound at 0xFFFF→0x0000 (mirror `RTPAudioTests.testSequenceWraparound`,
  `Tests/TailscreenTests/RTPAudioTests.swift:35-44`); first-packet nil case.
- `jitterBufferTarget`: monotone in jitter, clamped [2,12], one-step-per-call bounded growth.
- `shouldLogClamp`: threshold crossing + modulo behavior.

**CI-able pipeline tests** (real codec, no tsnet — `VoiceChannelTests` already runs AAC on CI):
- Lossy end-to-end: encode 100 frames on one `VoiceChannel`, pass packets through `LossyChannel`
  (seeded loss 10%, reorder, dup — CLAUDE.md documents it as reusable), feed a listener channel;
  assert `onMixedPCM` total sample count ≈ sent duration (concealment fills), `concealedFrames > 0`,
  `discontinuities` bounded, no wedge. Skip-if-no-output guard mirrors `ScreenShareSyntheticFramesTests`'
  VideoToolbox policy in case virtualized runners lack the AAC converter.
- Clamp counter: feed a decoder path with a synthetic out-of-range `onMixedPCM` injection is not
  possible (clamp is pre-callback), so assert via a crafted decode of a hot signal OR unit-test the
  single-pass clamp helper directly with an out-of-range array.

**Local E2E** (not CI, per CLAUDE.md "tsnet suites can't run on CI"):
- `make test-e2e-local` → `ScreenShareFanoutTests.testTwoViewersDecodeAndRelayAudio`
  (`Tests/TailscreenTests/ScreenShareFanoutTests.swift:24`) must stay green — relay is byte-for-byte,
  untouched.
- Manual: `TAILSCREEN_VOICE_TEST_TONE=1 ./test-local.sh 2` under
  `sudo ./scripts/net-impair.sh up --loss 3 --delay 80 --reorder 2` — listen for gap clicks
  (should soften), watch the new stats log line for concealed/underrun counts, then
  `net-impair.sh down`.

## Risks & pitfalls

- **Threading (Swift 6, per CLAUDE.md conventions):** all new VoiceChannel state must stay confined
  to its serial queue (`Sources/VoiceChannel.swift:10-17`); `MicCapture` state stays `@MainActor`.
  Publish cross-thread values (`VoiceStats`, target depth) via `OSAllocatedUnfairLock`, never by
  letting MainActor `queue.sync` into the audio path. `VoiceChannel` stays `@unchecked Sendable` —
  we own the invariants; document each new field's confinement in the class comment.
- **Retry storms:** the whole reason `brokenSSRCs` exists is 50 Hz log spam (`:92-93`). The cooldown
  gate must be evaluated *before* attempting decoder init, and failure logging must occur only on
  record transitions.
- **Priming vs loss:** decoder priming returns short/zero output (`Sources/AACCodec.swift:286-288`);
  never infer loss from output sample counts — only from sequence numbers.
- **Late-arrival double-fill:** after concealing a gap, the late packet may still arrive; `.dropStale`
  must eat it or we play 21 ms twice. Covered by the reorder tests.
- **Latency creep:** adaptive depth is capped (12 buffers ≈ 256 ms) and steps down on calm windows;
  keep the existing drop-at-cap behavior (`:727`) as the clock-drift backstop — do not remove it.
- **Don't touch the relay/SSRC protocol:** server-side anti-spoof gate
  (`Sources/TailscaleScreenShareServer.swift:873-882`) and HELLO_ACK SSRC assignment are out of scope;
  changing `receive`'s signature would ripple into `AppState` wiring — keep the signature.
- **`reset()` semantics:** must clear failure records, sequence state, jitter estimate, and tails so
  the next session starts fresh (`:109-114`).

## Estimated scope

**M.** ~220-280 LOC in `Sources/VoiceChannel.swift` (blacklist ~40, gap/conceal ~80, jitter ~60,
counters/logging ~40, MicCapture depth plumbing ~30), ~0-10 LOC in `AACCodec.swift`, ~250 LOC of
tests. No wire, protocol, or UI changes.

## Deviations

Recorded while implementing; all are minor adaptations to the actual code, none change the design.

- **`gapAction` delta semantics clarified.** The design text said "delta 0 or in the behind
  half-space → `.dropStale`" with `delta = newSeq &- expected`, which contradicts its own enum
  comment (`.decode // in order`). As implemented: `delta == 0` (== expected) → `.decode`;
  `delta > 0x8000` (duplicate or reordered-late) → `.dropStale`; `1...maxConcealFrames` →
  `.concealThenDecode`; otherwise `.discontinuity`. The pure-decision tests pin all four regions
  plus wraparound.
- **Target-depth refresh is rate-limited on the channel queue.** `jitterBufferTarget` is
  one-step-per-call; calling it per packet (~50 Hz) would make the step bound meaningless, so the
  live path re-derives and publishes the target at most once per second (from the worst per-SSRC
  smoothed jitter). The pure function is unchanged from the plan.
- **`AACCodec.swift` untouched.** The optional `isRetryableInit` hint on `AACCodecError` was not
  needed — the cooldown blacklist retries every init failure uniformly, which subsumes the hint.
  `RTPAudio.swift` is also untouched (the seq-delta helper landed as `VoiceChannel.gapAction`, as
  the plan's file list anticipated).
- **"Success clears" is tested via an injection seam, not a forced init failure.** A real
  `AACDecoder()` init failure can't be provoked in-process (the shared magic cookie is cached
  process-wide), so DEBUG-only seams (`injectDecoderFailureForTesting`,
  `decoderFailuresForTesting`) let `VoiceChannelTests` cover both the elapsed-cooldown retry+clear
  path and the inside-cooldown drop path with the real decode pipeline.
- **Jitter update skips discontinuities.** A resync's huge RTP-timestamp jump would poison
  `J += (|D| - J) / 16` with a one-off multi-second |D|, so the estimator only folds in packets
  classified `.decode` / `.concealThenDecode` (and resyncs its clocks on `.discontinuity`).
- **Stats logging is opportunistic.** `VoiceChannel` has no timer; the once-per-minute stats line
  is emitted from the inbound path (first packet past the 60 s mark), guarded to log only when a
  counter moved — dead-idle channels stay silent, matching the plan's intent.
