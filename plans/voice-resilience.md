# Voice-path resilience: retryable decoder failures, adaptive jitter buffer, loss handling

> **Status: shipped.** All items implemented and reviewed; see `Sources/VoiceChannel.swift`.

## Problem

The voice path (AAC-LC mono 48 kHz over RTP/UDP 7447, one AU per packet) was
brittle under the conditions `scripts/net-impair.sh` simulates:

1. A single decoder-init failure permanently blacklisted an SSRC for the
   whole session, even though init can fail for transient reasons.
2. The jitter buffer was fixed (3 buffers threshold, 6 cap, silent
   overflow-drop) with no jitter measurement and no under/overrun counters
   — right for LAN, wrong for a lossy WAN path.
3. Lost packets simply vanished — `sequenceNumber` was parsed but never
   read, so no gap detection, concealment, or dup/reorder rejection.
4. Every decoded sample was silently clamped to [-1, 1] with no
   instrumentation, so a clipping regression would ship unnoticed.

Non-goals (still true): no FEC/RED/NACK for audio (UDP loss stays
accepted, per protocol design); no wire/payload-type/SSRC-relay changes;
no true codec-level PLC (AudioToolbox's `AudioConverter` exposes no
corrupt-frame input, so concealment is PCM-side only).

## Design decisions and why

- **Retry-after-cooldown blacklist**, not permanent. `[SSRC:
  DecoderFailureRecord]` replaces the `Set`; a pure `decoderGateAction`
  decides allow/drop from cooldown (5s) and a permanent-after-N-failures
  cap (5) — preserves the original "don't spam stderr at 50 Hz" property
  (≤1 log line per cooldown window) while letting transient failures
  recover. A successful decode clears the record.
- **Jitter buffer target is RFC 3550 smoothed jitter → a pure sizing
  function** (`jitterBufferTarget`), clamped [2,12] buffers and moving one
  step per call — bounded growth so it can't oscillate. Refreshed at most
  once/second from the worst per-SSRC jitter (calling it per-packet would
  make the one-step bound meaningless).
- **Loss concealment is PCM-side silence fill, not decoder-level PLC** —
  AudioToolbox genuinely has no concealment input path (verified against
  `AudioConverterFillComplexBuffer`). Gaps of 1–5 missing AUs get faded
  silence inserted before the next real decode; larger gaps resync as a
  `.discontinuity` with no fill, because the player already tolerates
  cadence gaps and a long silence wall would be worse than a click.
  Sequence-keyed (not sample-count-keyed) specifically so decoder-priming's
  short/zero first output is never mistaken for loss.
- **Concealment is capped by playback slack, not the original 5-frame
  cap** (review fix): live queue headroom isn't readable from the audio
  callback's queue (`pendingBuffers` is MainActor-confined), so the cap
  was tightened to `playbackSlackBuffers - 1` (2) frames per gap — enough
  emitted silence can't by itself overrun the queue and drop the gap's
  first real frame.
- **Clamp instrumentation** logs at a threshold crossing and then every N
  buffers, not every occurrence, so a persistent clipping regression is
  visible without 50 Hz spam.
- **Jitter estimator skips discontinuities and mute-pause deviations**
  (review fixes): a resync's huge timestamp jump, or a send-side pause
  (seq-contiguous but a multi-hundred-ms arrival gap), would otherwise
  poison the RFC 3550 EWMA with a one-off outlier.
- **Idle-SSRC eviction** (review fix): state for an SSRC silent >10s is
  evicted so a departed peer's frozen jitter estimate doesn't keep the
  shared target pinned high.

## Where it lives

- `Sources/VoiceChannel.swift` — `DecoderFailureRecord`/`decoderGateAction`,
  `GapAction`/`gapAction`, the RFC 3550 estimator + `jitterBufferTarget`,
  `VoiceStats` (lock-published counters: `overrunDrops`, `underruns`,
  `concealedFrames`, `discontinuities`, `clampedBuffers`,
  `smoothedJitterMs`), `MicCapture`'s adaptive `targetDepth`.
- `Tests/TailscreenTests/VoiceResilienceDecisionTests.swift` — pure-decision
  suite (gate transitions, gap classification incl. wraparound, jitter
  target monotonicity/clamping, clamp-log threshold).
- `Tests/TailscreenTests/VoiceChannelTests.swift` — `LossyChannel`-driven
  end-to-end case, plus DEBUG-only injection seams
  (`injectDecoderFailureForTesting`) since a real `AACDecoder()` init
  failure can't be provoked in-process (the magic cookie is cached
  process-wide).
- Local-only regression: `ScreenShareFanoutTests.testTwoViewersDecodeAndRelayAudio`
  must stay green (relay path untouched); manual soak via
  `scripts/net-impair.sh` + `TAILSCREEN_VOICE_TEST_TONE=1`.

## Pitfalls for future changes here

- All new `VoiceChannel` state must stay confined to its serial queue;
  cross-thread values go through a lock (`OSAllocatedUnfairLock`), never a
  MainActor `queue.sync` into the audio path.
- Never infer loss from decoded sample counts — only from sequence
  numbers (priming produces short/zero output on the first AU too).
- A conceal-then-late-arrival must be dropped (`.dropStale`), or the same
  21ms plays twice.
- Don't touch the relay/SSRC-assignment protocol
  (`TailscaleScreenShareServer.audioRelayDecision`) or `receive`'s
  signature — out of scope, and `AppState` wiring depends on it.
