# Per-viewer isolation: one slow viewer must not degrade the session for everyone

> Status: implemented in this PR.

## Problem & motivation

Tailscreen encodes once and fans out (per-viewer RTP header rewrite,
`Sources/TailscaleScreenShareServer.swift:1581-1588`). That architecture makes three "worst viewer
wins" couplings inevitable unless we explicitly break them:

1. **Audio fan-out shares one send chain.** `audioBroadcastTail`
   (`Sources/TailscaleScreenShareServer.swift:179-185`) serializes *all* audio sends — sharer mic
   (`sendAudioRTP`, `:1594-1606`) and viewer-to-viewer relay (`handleInboundAudioRTP`, `:897-907`) —
   through a single task chain, and each job iterates recipients sequentially. One viewer whose
   `pl.send` blocks (socketpair backpressure on a DERP-relayed path) delays audio to *every* other
   viewer, both within the current packet's recipient loop and for every chained packet behind it.
   The comment at `:181-184` acknowledges this as a deliberate tradeoff ("a single chain is fine") —
   it is fine for CPU, not for isolation.
2. **Bitrate adaptation is hostage to the worst link.** `adaptiveBitrateSweep` takes the *max*
   per-viewer PLI count (`worstPLIs`, `:1386-1397`; rationale comment `:1358-1361`) and feeds it to
   the global `nextAdaptiveBitrate` (`:1425-1442`). One viewer on hotel Wi-Fi drags every healthy
   viewer down to the 30 %-of-baseline floor, and because the encoder is shared, there is no way back
   up while that viewer keeps losing packets.
3. **Nobody can see which viewer is the problem.** PLIs are recorded per viewer
   (`Viewer.pliTimestampsNs`, `:89`, `recordPLI` `:929-938`) but never surfaced; video-frame drops
   for a backlogged viewer (`:1539-1545`) are not even counted. The sharer UI shows only names
   (`ViewersList`, `Sources/MenuBarView.swift:536-558`).

Video *transport* isolation already exists and is the pattern to copy: per-viewer send chains with a
bounded queue (`ViewerSendChain`, `:166-175`; fan-out loop `:1534-1566`).

## Goals / Non-goals

**Goals**
- Per-viewer audio send isolation mirroring the video pattern (bounded per-viewer chain, drop policy).
- Per-viewer loss attribution: distinguish "one bad viewer" from "everyone suffering"; throttle the
  isolated bad viewer (keyframe-only mode) instead of cutting the global bitrate; keep today's global
  cut for widespread loss.
- Per-viewer stats in logs + a health indicator in the sharer's viewer roster.
- All new decisions as pure static funcs, CI-tested (extending the `AdaptiveBitrateTests` /
  `ViewerLifecycleDecisionTests` pattern).

**Non-goals**
- No simulcast / per-viewer re-encode (stretch section below).
- No NACK/RTX; PLI remains the only video-loss feedback (CLAUDE.md protocol section).
- No change to the UDP wire protocol, HELLO/ACK handshake, or SSRC assignment.
- No changes to the capture-helper or its wire (`Sources/CaptureHelperWire.swift`).

## Current state (with file:line references)

- **Video fan-out**: `broadcast(avccData:isKeyframe:)` (`:1470-1567`). Packetizes once into
  zeroed templates (`:1499-1511`), reserves each viewer's sequence range under the `viewers` lock
  (`:1513-1526`), then per-viewer chains (`videoSendTails`, `:171`) rewrite seq/SSRC per packet
  (`:1553-1557`).
- **Full-queue handling — verified: drop-NEWEST.** At `maxQueuedVideoFramesPerViewer = 4` (`:175`),
  the incoming frame is skipped for that viewer (`:1539-1545`); crucially its sequence numbers were
  *already reserved* (`:1522`), so the skip reads as wire loss and the viewer's PLI fetches a
  keyframe (comment `:1540-1543`). Chains are pruned by rebuilding the dict every broadcast
  (`:1564-1565`).
- **Audio fan-out**: single global `audioBroadcastTail` (`:185`); outbound mic path `sendAudioRTP`
  (`:1594-1606`); relay path `handleInboundAudioRTP` (`:888-909`) with the pure anti-spoof gate
  `audioRelayDecision` (`:873-882`, tested in
  `Tests/TailscreenTests/ViewerLifecycleDecisionTests.swift:14-48`). No cap: under a stall, chained
  jobs park one-behind-one ("natural backpressure", `:183-185`) — bounded memory, unbounded latency,
  and shared across all viewers. Audio packets arrive ~every 21.3 ms (one AAC AU,
  `Sources/RTPAudio.swift:33-34`).
- **Adaptive loop**: `adaptiveBitrateSweep` (`:1369-1413`) — 5 s window, per-viewer PLI rings pruned
  in place (`:1386-1397`), `worstPLIs` max → `nextAdaptiveBitrate` (`:1425-1442`: cut 25 % above
  threshold 2 PLIs/5 s with 5 s down-hysteresis, +10 % recovery with 10 s up-hysteresis, floor 30 %
  of baseline / 500 kbps). Pure and already CI-tested (`Tests/TailscreenTests/AdaptiveBitrateTests.swift`).
- **Bitrate application**: `applyAdaptiveBitrate` (`:1448-1462`) → `helperCapture?.setBitrate` — one
  encoder, one knob (`Sources/CaptureHelperWire.swift:64` `setBitrate = 0x02`).
- **Keyframe cadence**: PLI → `helperCapture?.requestKeyframe()` (`:829`); CLAUDE.md protocol
  section: "PLI-driven keyframe roughly every 2 s".
- **Roster plumbing**: `ViewerInfo` (`:31-37`) → `viewerInfos` (`:112`) → `notifyViewersChanged`
  (`:1180-1186`) → `AppState.currentViewers` (`Sources/AppState.swift:77`, handler `:1772`) →
  `ViewersList` (`Sources/MenuBarView.swift:536-558`, currently a single truncated text line).
- **Idle sweep**: `sweepIdleViewers` (`:1289-1355`) ticks at 1 Hz — a convenient host for per-viewer
  stat logging and throttle-state transitions if we don't want a fourth loop.

## Design

### (a) Per-viewer audio send isolation

Mirror the video pattern rather than inventing a new one. Extract the chain bookkeeping that
`broadcast` uses inline (`:1534-1566`) into a small reusable helper owned by the server:

```swift
/// Generic per-destination bounded send chain (video frames today, audio packets now).
private struct PerViewerSendChains {
    var chains: [String: ViewerSendChain]   // existing struct, :166-169
    // Pure, testable: false = drop (queue full).
    static func shouldEnqueue(queued: Int, cap: Int) -> Bool { queued < cap }
}
```

Add `audioSendTails: OSAllocatedUnfairLock<[String: ViewerSendChain]>` beside `videoSendTails`
(`:171`) with `maxQueuedAudioPacketsPerViewer = 24` (~0.5 s at one AU per 21.3 ms — deep enough to
ride out a DERP hiccup, shallow enough that a stalled viewer's audio latency stays bounded).
**Drop policy: drop-newest, matching video** (`:1539-1545`): audio is loss-tolerant by design
(CLAUDE.md protocol section), receivers get gap concealment from the voice-resilience plan, and
drop-newest requires no queue surgery — the frame simply isn't enqueued.

Both call sites change from the shared tail to a per-recipient enqueue:
- `sendAudioRTP` (`:1594-1606`): for each viewer, enqueue `pl.send(packet, to: addr)` on that
  viewer's chain (packet is identical for all — no rewrite needed, unlike video).
- `handleInboundAudioRTP` (`:897-907`): same, over `validated.recipients`.

Pruning: reuse the video approach — rebuild/prune against the live recipient set on each send, plus
clear in `stop()` next to `videoSendTails.withLock { $0.removeAll() }` (`:1666`).
This is the smallest safe change: it deletes `audioBroadcastTail` (`:185`), reuses `ViewerSendChain`
verbatim, and leaves the packet bytes and validation untouched. The per-packet Task cost the
`:179-184` comment worried about stays bounded: one chained task per viewer per AU, exactly the
video path's economics at a smaller payload.

### (b) Per-viewer loss attribution + isolated-viewer throttling

New pure decision, fed by the same per-viewer PLI window the sweep already computes (`:1386-1397` —
change it to return the full `[String: Int]` map instead of just the max):

```swift
enum LossVerdict: Equatable {
    case healthy
    case isolated(addr: String, plis: Int)   // exactly one viewer over threshold AND
                                             // every other viewer clean (0 PLIs)
    case widespread(worstPLIs: Int)          // today's behavior: global cut
}
static func lossAttribution(pliCounts: [String: Int], lossThreshold: Int = 2) -> LossVerdict
```

Rules: no viewer over threshold → `.healthy`. Exactly one over threshold and all others at 0, *and*
`pliCounts.count >= 2` → `.isolated` (with a single viewer there is no "everyone else", so it stays
`.widespread` — identical to today). Anything else → `.widespread(max)`.

**Recommended policy: degrade-worst via keyframe-only mode (not drop-worst, not degrade-all).**
- *Degrade-all* (status quo) punishes healthy viewers — the problem statement.
- *Drop-worst* ejects a participant on what may be transient loss; SERVER_BYE teardown
  (`denyViewer` template, `:1143-1151`) is user-hostile as an automatic action.
- *Keyframe-only* is the only per-viewer frame-skipping that is actually decodable: P-frames form a
  reference chain, so skipping arbitrary non-keyframes corrupts everything until the next IDR.
  Keyframes are self-contained (broadcast prepends parameter sets in-band on every keyframe,
  `:1477-1485`; CLAUDE.md: "late-joining viewers can decode the very first frame they observe"), and
  arrive ~every 2 s under PLI pressure — the throttled viewer gets a valid slideshow at a fraction
  of the bandwidth, which is precisely what its link can afford.

Mechanics: add `var throttledUntilNs: UInt64 = 0` to `Viewer` (`:80-90`). The sweep (host it inside
`adaptiveBitrateSweep`'s existing 5 s tick, `:1375-1412`) applies a second pure func:

```swift
struct FairnessDecision: Equatable {
    var throttle: [String]        // viewers to put in keyframe-only mode this window
    var globalBitrateInput: Int   // worstPLIs *excluding throttled viewers* → nextAdaptiveBitrate
}
static func fairnessDecision(pliCounts: [String: Int], currentlyThrottled: Set<String>,
                             lossThreshold: Int = 2) -> FairnessDecision
```

- `.isolated(addr)` → throttle `addr` for the next 2 windows (10 s; renewed while it keeps PLI-ing),
  and exclude it from the max fed to `nextAdaptiveBitrate` so it can no longer drag the global rate.
- `.widespread` → throttle nobody new; feed the true max (today's path, `nextAdaptiveBitrate`
  unchanged, `AdaptiveBitrateTests` stay valid).
- Un-throttle by expiry: a viewer whose window is clean simply isn't renewed (asymmetric hysteresis
  for free, matching the sweep's existing style, `:1420-1424`).

In `broadcast`, the plan loop (`:1513-1526`) skips throttled viewers on non-keyframes — and **does
not reserve sequence numbers for skipped frames** (unlike the backlog drop at `:1539-1545`). The
throttled viewer then sees a contiguous, decodable keyframe-only stream instead of a perceived-loss
gap that would provoke a PLI storm and re-trigger the very signal we throttled on.

### (c) Per-viewer stats: logs + sharer UI health dot

- Add `var droppedFrames: Int` to `ViewerSendChain` (`:166-169`), incremented in the backlog-drop
  branch (`:1539-1545`) and in the new audio drop branch.
- Once per sweep tick (5 s), log one line per viewer with nonzero activity:
  `Viewer stats addr=… plis/5s=… vDrops=… aDrops=… throttled=…`.
- Extend `ViewerInfo` (`:31-37`) with `var health: ViewerHealth` (`enum ViewerHealth: Sendable
  { case good, degraded, throttled }` — `degraded` = over threshold this window, `throttled` =
  keyframe-only). Computed in the sweep, written to `viewerInfos`, published via the existing
  `notifyViewersChanged` (`:1180-1186`) → `AppState.currentViewers` (`Sources/AppState.swift:77`).
- UI (optional, small): convert `ViewersList` (`Sources/MenuBarView.swift:536-558`) from one
  truncated line to one row per viewer with a leading `Circle().fill(…)` dot (green/yellow/orange) +
  `.help(L("…"))` tooltip. All strings through `L(_:)` with catalog entries in
  `Sources/Resources/en.lproj/Localizable.strings` (CLAUDE.md Localization: keys byte-for-byte in
  sync — `LocalizationCatalogTests` enforces it).

### (d) Stretch (out of scope): simulcast / per-viewer re-encode

The clean fix for heterogeneous links is per-viewer quality, but the helper wire supports exactly
one encode session today: control commands are `requestKeyframe / setBitrate / contentFilter /
shutdown` (`Sources/CaptureHelperWire.swift:62-75`) with no session or layer identifier, AU messages
carry no stream tag (`:21-27`), and the server holds a single `helperCodec` + one packetizer pair
(`:217,234-235`). Simulcast would need: multi-encoder support in `CaptureHelperMain`, layer-tagged
AU frames on the wire, per-viewer layer selection in `broadcast`, and ~2× encode CPU in the helper —
plus new restart/watchdog semantics (`classifyHelperExit`, crash budget, `:447-474`). Keyframe-only
throttling gets ~80 % of the benefit for ~5 % of that cost, so simulcast is deferred; this plan's
per-viewer accounting (PLI maps, health states) is the substrate it would build on.

## Implementation steps (ordered checklist)

1. [ ] `Sources/TailscaleScreenShareServer.swift`: add `droppedFrames` to `ViewerSendChain`
   (`:166-169`); increment at the video drop branch (`:1539-1545`).
2. [ ] Add `audioSendTails` + `maxQueuedAudioPacketsPerViewer = 24`; add the trivial pure
   `shouldEnqueue(queued:cap:)`; rewrite `sendAudioRTP` (`:1594-1606`) and the relay leg of
   `handleInboundAudioRTP` (`:897-907`) to per-viewer chains; delete `audioBroadcastTail` (`:185`);
   clear the new dict in `stop()` beside `:1666`.
3. [ ] Add `LossVerdict`, `lossAttribution`, `FairnessDecision`, `fairnessDecision` as
   `static` internal funcs (same seam style as `audioRelayDecision`, `:873`).
4. [ ] Change the sweep's PLI aggregation (`:1386-1397`) to return `[String: Int]`; wire
   `fairnessDecision` in; set/renew `Viewer.throttledUntilNs`; feed the throttle-excluded max into
   the existing `nextAdaptiveBitrate` call (`:1400-1408`).
5. [ ] In `broadcast`'s plan loop (`:1513-1526`): for throttled viewers on non-keyframes, skip the
   plan entry *without* bumping `nextSequence`.
6. [ ] Add per-viewer stats log line to the sweep; add `ViewerHealth` to `ViewerInfo` (`:31-37`),
   compute in the sweep, publish via `notifyViewersChanged` (`:1180-1186`).
7. [ ] `Sources/MenuBarView.swift`: row-per-viewer `ViewersList` with health dot (`:536-558`);
   add any new user-facing strings to the `en.lproj` catalog.
8. [ ] New `Tests/TailscreenTests/PerViewerFairnessDecisionTests.swift`; extend
   `ViewerLifecycleDecisionTests` for the audio-chain drop decision; update CLAUDE.md's
   pure-decision-test list in the same commit.

## Files to change / add

- `Sources/TailscaleScreenShareServer.swift` — audio chains, attribution/throttle decisions, sweep
  wiring, broadcast skip, stats, `ViewerInfo.health`. (Bulk of the change.)
- `Sources/MenuBarView.swift` — `ViewersList` health dots.
- `Sources/AppState.swift` — none expected (`currentViewers` already flows snapshots, `:77,1772`).
- `Sources/Resources/en.lproj/Localizable.strings` — new tooltip/label keys.
- `Tests/TailscreenTests/PerViewerFairnessDecisionTests.swift` — new.
- `Tests/TailscreenTests/ViewerLifecycleDecisionTests.swift`, `AdaptiveBitrateTests.swift` — extended.
- `CLAUDE.md` — test-list bookkeeping.

## Testing strategy

**CI-able pure-decision tests** (no tsnet — the pattern CLAUDE.md mandates since tsnet can't run on CI):
- `lossAttribution`: all clean → `.healthy`; one bad + others at 0 → `.isolated`; one bad + another
  merely nonzero → `.widespread`; two bad → `.widespread`; single viewer bad → `.widespread`
  (no-peers rule); threshold boundary (exactly 2 PLIs is not "over", mirroring
  `AdaptiveBitrateTests.testNoCutAtOrBelowThreshold`).
- `fairnessDecision`: throttle set on isolated; renewal while PLIs persist; expiry after clean
  windows; throttled viewer excluded from `globalBitrateInput` (so `.isolated` never cuts global);
  widespread passes true max through.
- `shouldEnqueue`: at/below/above cap.
- Sequence-space invariant: simulate the plan loop's throttle skip and assert a throttled viewer's
  seq numbers stay contiguous across skipped non-keyframes (extend the header-rewrite tests in
  `ViewerLifecycleDecisionTests.swift:99-133`).
- Regression: existing `AdaptiveBitrateTests` must pass unchanged — `nextAdaptiveBitrate` is not
  modified, only its input.

**Local E2E** (`make test-e2e-local`; self-skips on CI per CLAUDE.md):
- `ScreenShareFanoutTests.testTwoViewersDecodeAndRelayAudio`
  (`Tests/TailscreenTests/ScreenShareFanoutTests.swift:24`) must stay green — it pins exactly the
  relay path step 2 rewrites (viewer1 audio → sharer `onAudioReceived` + relay to viewer2, `:101-126`).
- Extend the fanout suite: with two viewers connected, disconnect viewer1 mid-stream (BYE) and assert
  viewer2's audio keeps arriving — exercises per-viewer chain pruning.
- Throttle path end-to-end needs real loss: manual validation via
  `sudo ./scripts/net-impair.sh up --loss 5 --delay 80` + `./test-local.sh 3` (one impaired viewer);
  confirm via the new per-viewer stats log that only the impaired viewer goes `throttled` and the
  global bitrate log line (`applyAdaptiveBitrate`, `:1461`) stops cutting. This is the documented
  role split: net-impair is "the end-to-end complement, not a replacement" for the CI decision tests.

## Risks & pitfalls

- **PLI-storm feedback loop:** if throttling *did* reserve seq numbers for skipped frames, the
  throttled viewer would perceive ~100 % loss, PLI at max rate, and keep itself throttled forever.
  The no-reservation rule in step 5 is correctness-critical; the drop-at-cap branch (`:1539-1545`)
  intentionally keeps the opposite behavior — do not unify them.
- **Stuck-badge invariant:** none of this may touch capture restart ordering. The throttle path must
  never call `restartCapture()`/`stop()`; CLAUDE.md explicitly warns about the
  await-pending-restart-then-teardown ordering (`restartTask`, `:271,1621-1628`).
- **Locking discipline:** `viewers`, `videoSendTails`, and the new `audioSendTails` are separate
  `OSAllocatedUnfairLock`s (`:92,171`); never nest one `withLock` inside another (the existing code
  never does). Throttle state lives inside `Viewer` under the `viewers` lock, read into the plan
  snapshot (`:1513-1526`) in the same critical section that reserves sequences.
- **`ViewerInfo` is the Sendable seam** (`:108-112` comment: `Viewer` is intentionally not Sendable).
  `health` must be a value type; UI updates keep flowing through snapshot replacement, and callbacks
  still "bounce to `@MainActor`" (`:279-282`).
- **Audio-cap tuning:** 24 packets ≈ 0.5 s; too small re-introduces audible gaps on transient stalls,
  too large re-introduces the latency the shared tail already bounded via backpressure. The constant
  is a named `static let` next to `maxQueuedVideoFramesPerViewer` (`:175`) so it's greppable.
- **Approval/pending interactions:** pending viewers are never in `viewers` (`:120-125`), so they can
  never be throttled or receive audio chains — no change needed, but tests should assert fan-out
  ignores them (existing invariant, `:114-117`).
- **Localization:** every new UI string via `L(_:)` + catalog entry, or `LocalizationCatalogTests`
  fails CI (CLAUDE.md Localization section).

## Estimated scope

**M.** ~180-240 LOC in `TailscaleScreenShareServer.swift` (audio chains ~60, attribution/throttle
~80, stats/health ~60), ~40 LOC in `MenuBarView.swift`, ~10 LOC catalog, ~250 LOC tests. No wire or
helper changes; stretch (simulcast) explicitly deferred.

## Deviations (as implemented)

Line numbers in this plan predate six merged PRs (zoom/pan, voice-resilience, silent-failures,
source-switching, quality-settings, viewer-consent) — the implementation followed symbol names, not
the drifted line references. Substantive adaptations:

- **Audio-chain pruning is NOT rebuild-to-prune.** The plan suggested "reuse the video approach —
  rebuild/prune against the live recipient set on each send." That is unsafe for audio: video has a
  single producer (`broadcast`) that always addresses *every* viewer, so rebuilding the dict from its
  plan set prunes correctly. Audio has **multiple** producers (`sendAudioRTP` mic-out addresses all
  viewers; each viewer's `handleInboundAudioRTP` relay addresses all-but-the-sender) hitting
  *different* recipient subsets, so a rebuild-to-prune on one path would drop a non-recipient's live
  chain and break its ordering/backpressure. Instead `enqueueAudioPackets` mutates chains **in place**
  and stale chains are pruned at the viewer-removal points (`removeViewer`, `expelViewer`, the idle
  sweep's drop path, and `stop()`).
- **`shouldEnqueue` is the shared drop-policy seam**, extracted as the plan asked, but placed as a
  general per-chain gate (used by the audio path; the video path keeps its existing inline
  `>= cap` check to avoid churning the already-tested `broadcast` fan-out — the two are the same
  predicate, `queued < cap`).
- **`droppedFrames` lives on `ViewerSendChain`** (per the plan) and is incremented in both the video
  backlog-drop branch and the new audio drop branch; because video and audio keep separate chain
  dicts, a video chain's count is that viewer's video drops and an audio chain's is its audio drops
  (the stats line reports both).
- **`fairnessDecision` takes `currentlyThrottled` and excludes *all* throttled viewers (current +
  newly) from `globalBitrateInput`, in every verdict** — not only `.isolated`. A viewer already in
  keyframe-only mode is deliberately frame-skipped, so its PLIs are expected and must never drive the
  global cut, even in a `.widespread` window caused by a *different* viewer. When `currentlyThrottled`
  is empty (the common case) this equals the plan's "true max," so `.healthy`/`.widespread` behave
  exactly as before and `AdaptiveBitrateTests` are untouched (they test `nextAdaptiveBitrate`
  directly). Throttle renewal is also driven off `currentlyThrottled` (renewed while still over
  threshold; expires after a clean window).
- **Throttle skip is gated by the pure `shouldSendFrame(isKeyframe:throttledUntilNs:nowNs:)`** so the
  "keyframe always sent; inter frame skipped without advancing `nextSequence`" rule is CI-testable —
  the sequence-space-contiguity invariant the plan flags as correctness-critical is asserted in
  `ViewerLifecycleDecisionTests` by replaying the plan loop's advance-only-on-send logic.
- **UI:** `ViewersList` became one row per viewer with a leading health dot (green/yellow/orange) and
  a `.help` tooltip; the old single "%lld watching: %@" summary line is dropped from the roster view
  (the count still shows in the card header). Three new tooltip strings added to both `en.lproj` and
  `sv.lproj`.
- **Constant home:** `maxQueuedAudioPacketsPerViewer = 24` lives in `TransportTuning` next to
  `maxQueuedVideoFramesPerViewer` (both were centralized there by the quality-settings PR) and is
  pinned in `QualitySettingsTests`.
