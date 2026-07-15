# Stop swallowing pipeline errors — degraded-state signals + self-healing

> Status: implemented in this PR.

## Problem & motivation

Several failure paths in the video pipeline log-and-return, leaving the user staring at a frozen last frame (viewer) or an invisibly dead share (sharer) with no signal and no recovery:

- A **persistently failing decode** never escalates. `VideoDecoder` drops each bad frame silently; only session-*creation* failure has a callback. If VideoToolbox starts rejecting frames mid-session (corrupt reference state after heavy loss, GPU reset), the viewer shows a frozen frame forever.
- The **server's UDP control-receive loop exits permanently** on any non-timeout error. After that, HELLOs, KEEPALIVEs, PLIs and viewer audio are never read again: existing viewers get idle-swept after 15 s, new viewers can never join, yet the share still looks "active" to the sharer.
- The **client's UDP receive loop has the same one-way exit** — and unlike the idle-timeout path, the generic-error path doesn't even post `.tailscreenViewerPeerClosed`, so the window sits on a stale frame with a live-looking UI.
- **Encoder property-set failures are discarded** wholesale, so a machine whose VT encoder rejects e.g. `DataRateLimits` silently runs unbounded-bitrate.

Per CLAUDE.md's error-surfacing convention, errors at the UI go through `appState.showAlertMessage(title:message:)` / `presentError` — these paths never reach it.

## Goals / Non-goals

**Goals**
1. Consecutive-decode-failure escalation ladder on the viewer: PLI → recreate decode session → "Connection degraded" in stats overlay → existing alert path.
2. Restartable server + client UDP receive loops with capped exponential backoff and a give-up threshold that surfaces through existing teardown callbacks.
3. Structured failure counters (decode failures, PLIs sent, receive-loop restarts) plumbed into `ViewerStats` / `ViewerStatsOverlay`.
4. Encoder `VTSessionSetProperty` failures logged once per session with the failing property name.
5. All new decision logic extracted as pure static functions (CI-testable per CLAUDE.md); all user-visible strings through `L(...)` + catalog.

**Non-goals**
- No wire-protocol changes (existing PLI / CODEC_NO messages suffice).
- No sharer-side UI for receive-loop health beyond logs (counter in logs only, per the task scope).
- No retry policy changes for the capture-helper (crash budget / watchdog in `TailscaleScreenShareServer` stays as is).
- No changes under `TailscaleKitPackage/` (patches-only rule).

## Current state (with file:line references)

**VideoDecoder — per-frame failures swallowed** (`Sources/VideoDecoder.swift`):
- `decodeOnQueue` bails silently on `CMBlockBufferCreateWithMemoryBlock` (guard at :170), `CMBlockBufferReplaceDataBytes` (:181), `CMSampleBufferCreateReady` (:196); `VTDecompressionSessionDecodeFrame` failure only logs (:208-211).
- The async output callback logs-and-returns on bad `status` / nil `imageBuffer` (:226-232).
- Only session-**create** failure fires `onDecodeFailure` (:248-256), latched by `didReportDecodeFailure` (:26), consumed by the client's `handleDecodeFailure` (`Sources/TailscaleScreenShareClient.swift:370-385`) which sends CODEC_NO ×3 and posts `.tailscreenViewerDecodeFailed`; AppState's observer (`Sources/AppState.swift:299-316`) alerts via `showAlertMessage` (:1761) — note its strings at :309-313 bypass `L(...)` today.
- `shutdown()` (:259-278) already knows how to drain + invalidate a session; there is no mid-session "recreate" entry point.

**VideoEncoder — statuses ignored** (`Sources/VideoEncoder.swift`):
- Every `VTSessionSetProperty` in `createSession` (:139-195) and `applyBitrate` (:220-226) discards its `OSStatus`; the comment at :161-167 acknowledges "we ignore status".
- Saturation drops print every 60th (:257-264); `VTCompressionSessionEncodeFrame` failure prints per-call (:285-290). These run inside the capture-helper subprocess (`Sources/CaptureHelperMain.swift:377-416`), so "surfacing" means the helper log wire (`HelperFrameWriter.writeLog`, `Sources/CaptureHelperWire.swift:129-132`), not UI.

**Server receive loop — permanent break** (`Sources/TailscaleScreenShareServer.swift:761-776`): `receiveControlLoop` continues on `TailscaleError.readFailed` (poll timeout, :767-768) but `break`s on any other error while `isRunning` (:769-774). Nothing restarts it; `handleIncoming` (:778) is then unreachable, so joins/keepalives/PLIs/audio all die while the share appears healthy. The loop is spawned once at `start()` (:417).

**Client receive loop — permanent break, no notification** (`Sources/TailscaleScreenShareClient.swift:387-507`): idle timeout (15 s, :396) posts `.tailscreenViewerPeerClosed` (:498) so AppState disconnects (`AppState.swift:283-294`); but the generic `catch` at :502-505 just logs and breaks — no notification, frozen frame, keepalive loop (:560-569) keeps running.

**Stats overlay** (`Sources/ViewerStatsOverlay.swift:17-27` rows; model `ViewerStats`/`ViewerStatsModel` in `Sources/MetalViewerRenderer.swift:16-102`): shows latency/fps/dropped/bitrate/codec; `framesDropped` counts renderer-side overwrites only (:246-253). No decode-failure or degraded signal. `TailscaleScreenShareClient` already pushes into the model via `renderer.noteReceivedBytes/noteCodec` (:456-467) and resets per session (:251).

**Adaptive bitrate**: server reacts to viewer PLIs only (`recordPLI` :929-938, sweep :1369-1413, pure `nextAdaptiveBitrate` :1425-1442). Escalation step 1 (PLI) therefore feeds the existing adaptive inputs for free.

## Design

### (a) Viewer decode-failure escalation ladder

Add a consecutive-failure counter to `VideoDecoder`, mutated only on its serial `queue`: incremented at each of the four per-frame failure points (block-buffer create/replace, sample-buffer create, `DecodeFrame` status ≠ noErr) **and** in the output callback on bad status; reset to 0 on every successful `onDecodedFrame` delivery.

Escalation policy is a pure, CI-testable decision function (mirroring `nextAdaptiveBitrate`):

```swift
enum DecodeRecoveryAction: Equatable { case requestKeyframe, recreateSession, signalDegraded, surfaceError }
static func decodeRecoveryAction(consecutiveFailures: Int) -> DecodeRecoveryAction?
// nil otherwise; fires at exact thresholds so each action runs once per episode:
// 5 → .requestKeyframe   (a keyframe often un-wedges a decoder; cheap)
// 30 → .recreateSession  (invalidate + rebuild from installed formatDescription) + .requestKeyframe again
// 90 → .signalDegraded   (~1.5–3 s of dead video at 30–60 fps: overlay/toolbar badge)
// 300 → .surfaceError    (existing alert path; once per episode)
```

`VideoDecoder` gains `var onRecoveryAction: ((DecodeRecoveryAction) -> Void)?` (fired on the decode queue) and an internal `recreateSession()` that reuses the `shutdown()` drain sequence (:267-277) but keeps `formatDescription` and clears only `session`. `didReportDecodeFailure` stays for the create-failure path.

`TailscaleScreenShareClient` wires it in `connect()` next to the existing `onDecodeFailure` hookup (:317-319):
- `.requestKeyframe` → send `.pli` via `packetListener`, reusing the existing `lastPLISentNs`/`pliMinIntervalNs` throttle (:573-577; hoist the throttle check into a small method so both call sites share it). This also feeds the server's adaptive-bitrate PLI window automatically.
- `.recreateSession` → handled inside the decoder itself; client just logs + counts.
- `.signalDegraded` → set a new `isDegraded` flag on the stats model (below); cleared on next successful frame (decoder fires a paired `onRecovered` when the counter resets from ≥ degraded-threshold).
- `.surfaceError` → post a new `Notification.Name.tailscreenViewerVideoStalled` (pattern: `tailscreenViewerDecodeFailed`, :667-670); AppState observer calls `showAlertMessage(title: L("Video Has Stalled"), message: L("Decoding has been failing for several seconds…"))`. While touching this, route the existing decode-failed alert strings (`AppState.swift:309-313`) through `L(...)` too.

### (b) Restartable UDP receive loops with backoff

Shared pure policy in a new small type (used by both server and client):

```swift
enum ReceiveLoopPolicy {
    static let maxConsecutiveErrors = 10
    static func retryDelayNs(consecutiveErrors: Int) -> UInt64  // 250ms · 2^(n-1), capped 5s
}
```

(The 250 ms → 5 s doubling matches the annotation back-channel's proven backoff, `TailscaleScreenShareClient.swift:162-170`.)

**Server** (`receiveControlLoop`, :761-776): replace `break` with: increment consecutive-error counter, log `"Server: receive error #N: …"`, sleep `retryDelayNs`, `continue`. Reset the counter on any successful `recv` **or** `readFailed` timeout. After `maxConsecutiveErrors`, log a final line with the total restart counter and — because a share whose control loop is dead is unrecoverable — fire `onCaptureStopped?(error)` so AppState's existing recovery/teardown branch (`AppState.swift:520-544`) handles it. Keep a monotonically increasing `receiveLoopErrorTotal` (`OSAllocatedUnfairLock<Int>`) surfaced in the give-up log line and in `stop()`'s summary log.

**Client** (`receiveLoop` generic catch, :502-505): same counter + backoff + `continue`. On give-up, post `.tailscreenViewerPeerClosed` (the missing notification) so AppState disconnects and the UI tears down instead of freezing. The idle-timeout branch (:493-500) is untouched.

### (c) Structured counters → stats overlay

Extend `ViewerStats` (`MetalViewerRenderer.swift:16-48`) with `var decodeFailures: Int`, `var plisSent: Int`, `var isDegraded: Bool` (all reset in `resetStats`, :287-289). Client pushes via two new `ViewerStatsModel`-hopping methods on the renderer next to `noteReceivedBytes` (:261): `noteDecodeFailure()`, `notePLISent()`, `setDegraded(_:)`. `ViewerStatsOverlay` adds two rows after "Dropped" (:20-22) — `row(L("Decode errs"), …)`, `row(L("PLIs sent"), …)` — and a degraded banner: when `stats.isDegraded`, a top row `Label(L("Connection degraded"), systemImage: "exclamationmark.triangle.fill")` tinted with the existing red (:114). Update `accessibilitySummary` (:158-166) accordingly. Overlay may be hidden, so degraded state must also reach the always-visible toolbar: `ViewerToolbar` (`Sources/ViewerToolbar.swift`) subscribes to the stats model (Combine, same pattern as `micCancellable`, :49-55) and swaps the stats item's symbol to `exclamationmark.triangle` while degraded, with `.help(L("Connection degraded — click for stats"))`.

### (d) Encoder property-set logging

In `VideoEncoder.createSession`/`applyBitrate`, replace bare `VTSessionSetProperty` calls with a helper: `@discardableResult private static func setProperty(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef, log: inout [String])` that appends `"\(key)=\(status)"` on failure; after the property block, emit **one** `print("VideoEncoder: unsupported properties: …")` line listing all failures (empty → no line). Runs in the helper, so it reaches the merged log via inherited stderr. Best-effort properties (:161-167) stay best-effort — they're just named now.

## Implementation steps

1. [ ] `Sources/VideoDecoder.swift`: add `consecutiveFailures`, `static decodeRecoveryAction(consecutiveFailures:)`, `onRecoveryAction`/`onRecovered` callbacks, `recreateSession()`; increment at :170/:181/:196/:208 and in the output callback (:226-232); reset + fire `onRecovered` in the success path (:234).
2. [ ] New `Sources/ReceiveLoopPolicy.swift`: `maxConsecutiveErrors`, `retryDelayNs(consecutiveErrors:)` (pure).
3. [ ] `Sources/TailscaleScreenShareServer.swift`: rework `receiveControlLoop` (:761-776) per (b); add `receiveLoopErrorTotal`; give-up → `onCaptureStopped`.
4. [ ] `Sources/TailscaleScreenShareClient.swift`: rework `receiveLoop` generic catch (:502-505) per (b); wire `onRecoveryAction` in `connect()` (:312-320); hoist the PLI throttle into `sendPLIThrottled()` used by :471-483 and the new path.
5. [ ] `Sources/MetalViewerRenderer.swift`: extend `ViewerStats` (:16-48) + `resetStats` (:287); add `noteDecodeFailure/notePLISent/setDegraded` beside `noteReceivedBytes` (:261).
6. [ ] `Sources/ViewerStatsOverlay.swift`: new rows + degraded banner (:17-27); update `accessibilitySummary` (:158).
7. [ ] `Sources/ViewerToolbar.swift`: degraded badge on the stats toolbar item (Combine subscription pattern from :49-55).
8. [ ] `Sources/AppState.swift`: observer for `.tailscreenViewerVideoStalled` beside :299-316; localize the existing decode-failed alert strings (:309-313) via `L(...)`.
9. [ ] `Sources/VideoEncoder.swift`: property-set logging helper per (d) (:139-195, :220-226).
10. [ ] `Sources/Resources/en.lproj/Localizable.strings`: add every new key byte-for-byte (`Connection degraded`, `Decode errs`, `PLIs sent`, `Video Has Stalled`, alert bodies, `.help` text, plus the newly-localized decode-failed strings).
11. [ ] Tests (below), then update CLAUDE.md's pure-decision-test list (its instruction: "add it to this list").

## Files to change / add

| File | Change |
|---|---|
| `Sources/VideoDecoder.swift` | counter, ladder, recreate, callbacks |
| `Sources/ReceiveLoopPolicy.swift` (new) | backoff + give-up policy |
| `Sources/TailscaleScreenShareServer.swift` | restartable control loop, error counter |
| `Sources/TailscaleScreenShareClient.swift` | restartable receive loop, ladder wiring, PLI throttle hoist |
| `Sources/MetalViewerRenderer.swift` | `ViewerStats` fields + note methods |
| `Sources/ViewerStatsOverlay.swift` | rows + degraded banner |
| `Sources/ViewerToolbar.swift` | degraded toolbar badge |
| `Sources/AppState.swift` | stalled-video alert, localization fix |
| `Sources/VideoEncoder.swift` | property-status logging |
| `Sources/Resources/en.lproj/Localizable.strings` | new keys |
| `Tests/TailscreenTests/DecodeRecoveryDecisionTests.swift` (new) | ladder math |
| `Tests/TailscreenTests/ReceiveLoopPolicyTests.swift` (new) | backoff math |

## Testing strategy

**CI-able pure-decision tests** (pattern per CLAUDE.md — `AdaptiveBitrateTests`, `ViewerLifecycleDecisionTests`):
- `DecodeRecoveryDecisionTests`: thresholds fire exactly once (nil at 4/6/29/31…), ordering keyframe < recreate < degraded < error, reset-to-zero yields nil.
- `ReceiveLoopPolicyTests`: delay doubles from 250 ms, caps at 5 s, give-up at `maxConsecutiveErrors`.
- Extend `VideoCodecTests`: garbage AVCC fed to a `VideoDecoder` with installed real parameter sets increments the counter and fires `.requestKeyframe` at 5 (no tsnet needed; skip if VT unavailable, same guard as `ScreenShareSyntheticFramesTests`).
- `LocalizationCatalogTests` automatically enforces the new `L(...)` keys.

**Local E2E** (headless, local headscale, per CLAUDE.md):
- Extend `ScreenShareSyntheticFramesTests`: after clean decode, broadcast corrupted AUs and assert the server records PLIs via the existing `onPLIRecordedForTesting` seam (proves the ladder's step 1 crosses the wire).
- Extend `ScreenShareControlChannelTests`: assert a viewer still joins after the server logs a receive error (inject by closing/reopening under impairment is not deterministic — instead unit-drive `receiveControlLoop`'s policy and rely on the pure tests; the E2E case just pins "loop still alive after N minutes idle").
- Manual: `scripts/net-impair.sh up --loss 20 --delay 200` + `./test-local.sh 2` — verify degraded badge appears, then clears on `net-impair.sh down`; alert fires only if loss persists.

## Risks & pitfalls

- **Threading**: decoder counter must stay on the decoder's serial queue; output callback runs on VT's thread — route the increment through `queue.async` like `setParameterSets` (:33-37). Client/renderer stats hops go through `DispatchQueue.main` as `ViewerStatsModel` requires (`MetalViewerRenderer.swift:50-58`).
- **PLI amplification**: reuse the existing 100 ms throttle (:573-577); the ladder must not bypass it, or lossy links loop (comment at :471-477 explains the loss-amplification hazard).
- **No `Task { self }` in deinit / teardown ordering** (CLAUDE.md): the recreate path must reuse `shutdown()`'s wait-for-async-frames sequence (:267-277) to avoid the documented SIGSEGV.
- **Don't over-alert**: `.surfaceError` once per episode; reset only after recovery. `showAlertMessage` is `private` (`AppState.swift:1761`) — new alerts are wired inside AppState observers, matching :308.
- **Server give-up reuses `onCaptureStopped`**: AppState will try `restartCapture()` first (:537-542) which won't fix a dead socket loop — pass a distinguishable `NSError` domain (`Tailscreen.ReceiveLoop`) and add a guard in the handler to go straight to `stopSharing`.
- **Localization**: every user-visible string via `L(...)` + catalog or `LocalizationCatalogTests` fails CI; log lines stay unlocalized (CLAUDE.md).
- **CI cannot run tsnet/SCK** — anything touching live loops is local-only; keep the decision math pure.

## Estimated scope

**M** — ~450-550 LOC total: ~120 decoder, ~80 loops/policy, ~100 stats/overlay/toolbar, ~40 encoder logging, ~30 AppState, ~30 strings, ~150-200 tests. No wire or dependency changes.

## Deviations

Where the implementation diverges from the letter of the plan, and why:

- **PLI throttle state is now lock-guarded.** The plan's "hoist the throttle
  check into a small method" implied shared state, but `lastPLISentNs` was a
  plain `var` only ever touched from the receive task. The ladder now sends
  PLIs from decoder-escalation `Task`s too, so it became an
  `OSAllocatedUnfairLock<UInt64>` inside `sendPLIThrottled()` rather than a
  bare hoist.
- **Per-failure stats plumbing uses a decoder callback, not polling.** The
  plan named the renderer methods (`noteDecodeFailure()` etc.) but not how the
  client learns of each failure; a `VideoDecoder.onFrameDecodeFailed`
  callback (fired on the decoder queue alongside the ladder) was added for
  that, and the counter hooks publish to the stats model immediately instead
  of waiting for the display-link flush — during a stall there is no flush.
- **Degraded row is a banner + toolbar badge only.** As designed in (c); the
  overlay's accessibility summary also carries the degraded state and the two
  new counters (unlocalized, matching the existing summary strings).
- **Encoder helper signature.** `setProperty(_:key:value:failures:)` with an
  `inout [String]` instead of the sketched `log: inout [String]` name, and
  `applyBitrate` gained the same `failures:` parameter. Runtime `setBitrate`
  refusals log once per session via a latch cleared on `createSession` (the
  plan's "once per session" applied to the create path; the sweep calls
  `setBitrate` every few seconds, so it needed its own latch).
- **Local-only E2E extensions deferred.** The Testing strategy's extensions to
  `ScreenShareSyntheticFramesTests` / `ScreenShareControlChannelTests` need a
  live local-headscale tsnet bring-up, which neither CI nor this
  implementation environment can run; the CI-able suites
  (`DecodeRecoveryDecisionTests`, `ReceiveLoopPolicyTests`, and the new
  garbage-AVCC ladder test in `VideoCodecTests`) were added instead. The
  manual `net-impair.sh` verification stands as described.
- **`.signalDegraded` does not send an extra PLI.** The two keyframe-shaped
  rungs (`.requestKeyframe`, `.recreateSession`) do, through the shared
  throttle; the degraded rung only flips the indication, exactly as listed in
  design (a). *(Superseded by review fix 6 below: ladder PLIs now bypass the
  throttle.)*

### Review fixes

A verified post-implementation review batch changed the following (severity
order):

1. **Ladder freeze at the recreate rung.** `decodeOnQueue`'s
   `guard let formatDescription` / `guard let session` early-outs returned
   without counting a failure, so after `.recreateSession` nil'd the session
   a persistently failing rebuild pinned the counter at 30 and the
   degraded/alert rungs never fired. Both guards now call
   `recordDecodeFailureOnQueue(reason:)`.
2. **`>=` thresholds + per-episode latch.** `decodeRecoveryAction` no longer
   matches exact counts; it takes the count plus the set of already-fired
   rungs and returns the highest unfired rung whose threshold is met (rungs
   below a fired higher rung are superseded, never fired late). Latches reset
   with the counter on the first successful frame.
3. **`readFailed` dead-socket classification.** `TailscaleError.readFailed`
   covers both the benign 1 s poll timeout and a dead fd (POLLHUP → instant
   return); treating it always as a timeout let a dead socket busy-spin with
   the error counter permanently reset. Both loops now measure elapsed time
   around `recv` and classify via
   `ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs:)`
   (< 200 ms → error).
4. **Windowed give-up backstop.** A socket alternating error → timeout →
   error never reached `maxConsecutiveErrors`; both loops additionally give
   up at `ReceiveLoopPolicy.maxErrorsPerWindow` (30) errors within a trailing
   60 s window (`slidingWindowErrorCount`, same shape as the helper crash
   budget).
5. **Rebuild failures skip the codec-unsupported path.** An
   `isRebuildingSession` flag makes a failed mid-session
   `createDecompressionSession` log + count only; `onDecodeFailure` (CODEC_NO
   ×3 + the "lacks hardware decode" alert) fires solely for the initial
   session creation.
6. **Ladder PLIs bypass the 100 ms throttle** (`sendPLIUnthrottled`): rungs
   fire once per episode, so no amplification risk, and a swallowed ladder
   PLI stalled recovery until the next rung. Loss-driven PLIs stay throttled.
7. **Degraded state clears on disconnect.** `client.disconnect()` calls
   `renderer.setDegraded(false)` so the toolbar triangle/banner can't leak
   into the next session.
8. **Receive-loop share death now alerts** ("Sharing Stopped", localized in
   en + sv) instead of tearing down with only a log.
9. **`stopSharing` reentrancy guard** (`isStoppingShare` MainActor flag) —
   give-up paths could interleave with a user-initiated stop across await
   points, double-running `server.stop()` / `shareLock.release()`.
10. **Healthy-path cost.** The VT output callback only dispatches the
    success-reset hop while an `episodeActive` flag (set by failures) reads
    true, instead of a per-frame `queue.async` at 60 fps.
11. **Failure-path publish coalescing.** `noteDecodeFailure` keeps at most
    one pending main-queue stats publish (pending flag) instead of one per
    failing frame; the `isDegraded` flip stays immediate.
12. **Per-frame failure logs throttled** to the first of a run and every
    60th, via the `reason:` parameter on `recordDecodeFailureOnQueue`.
13. **Annotation back-channel reuses `ReceiveLoopPolicy.retryDelayNs`**
    instead of its own inline 250 ms → 5 s doubling (behavior identical).
14. **Accessibility summary localized.** `ViewerStatsOverlay`'s
    `accessibilitySummary` fragments route through `L(...)` (Doubles
    pre-formatted to `String` so keys carry `%@`/`%lld`); keys added to both
    catalogs.
15. **Stats toolbar icon keeps a VoiceOver description.** `updateStatsIcon`
    passes the degraded/normal `L(...)` string as the symbol's
    `accessibilityDescription` instead of nil.
16. **`VideoEncoder` diagnostics use the per-file `TSLogger`** pattern
    (matching `VideoDecoder`) instead of bare `print`.
