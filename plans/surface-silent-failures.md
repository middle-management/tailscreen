# Stop swallowing pipeline errors — degraded-state signals + self-healing

> Status: **shipped**, including a post-implementation security/robustness
> review pass. No known gaps remain.

## Problem it solved

Several failure paths logged-and-returned with no signal and no recovery:
persistent decode failures left the viewer on a frozen frame forever (only
session-*creation* failure had a callback); the server's and client's UDP
receive loops permanently exited on any non-timeout error, so a share could
look "active" while dead; encoder `VTSessionSetProperty` failures were
discarded, so a machine that rejected e.g. `DataRateLimits` silently ran
unbounded bitrate.

## What shipped

- A consecutive-decode-failure escalation ladder in `VideoDecoder`: request
  keyframe → recreate decode session → mark "Connection degraded" → surface
  the existing alert, each rung firing once per episode.
- Restartable server and client UDP receive loops with capped exponential
  backoff (250 ms → 5 s) and a give-up threshold that routes into existing
  teardown/alert paths instead of silently dying.
- Structured counters (decode failures, PLIs sent, degraded flag) in
  `ViewerStats`, shown in `ViewerStatsOverlay` and as a toolbar badge.
- Encoder property-set failures logged once per session with the failing
  property name.

## Key decisions and why

- **Escalation is a pure, CI-testable decision function**
  (`decodeRecoveryAction`), same pattern as the existing `nextAdaptiveBitrate`
  — takes the failure count plus which rungs already fired, returns the
  highest unfired rung whose threshold is met. A naive "exact count match"
  version was tried first and had a bug (see review fix #2 below).
- **Keyframe request reuses the existing adaptive-bitrate PLI path** rather
  than a separate signal, so step 1 of the ladder feeds the server's existing
  loss-driven bitrate adaptation for free.
- **Session recreate keeps the format description, only clears the VT
  session** — reuses `shutdown()`'s drain sequence to avoid the
  known "no `Task{self}` in deinit" SIGSEGV hazard from CLAUDE.md.
- **Give-up in a receive loop routes through the existing teardown
  callback** (`onCaptureStopped` server-side, `.tailscreenViewerPeerClosed`
  client-side) rather than a new path — but AppState's handler needed a
  distinguishable error domain, because its default `onCaptureStopped`
  response (`restartCapture()`) can't fix a dead socket loop; it now goes
  straight to `stopSharing` for this cause.
- **`TailscaleError.readFailed` needed elapsed-time classification, not a
  blanket "timeout".** It's thrown both for the benign 1 s poll timeout and
  for a dead fd (POLLHUP, near-instant return) — treating both as timeout let
  a dead socket busy-spin with its error counter perpetually reset by the
  "timeout" branch. Fixed by timing each `recv` and classifying < 200 ms as
  an error (`ReceiveLoopPolicy.classifyReadFailedAsError`).
- **A pure error-count threshold isn't enough** — a socket alternating
  error/timeout/error never reaches N *consecutive* errors, so both loops
  also give up at a capped count within a trailing 60 s sliding window (same
  shape as the existing helper-crash budget).
- **Ladder-triggered PLIs bypass the normal 100 ms throttle**; they fire at
  most once per episode so there's no amplification risk, and a swallowed
  ladder PLI would otherwise stall recovery until the next rung. Loss-driven
  PLIs (the pre-existing path) stay throttled.
- **A failed *mid-session rebuild* must not re-trigger the "no hardware
  decode" CODEC_NO/alert path** — that's reserved for the initial session
  creation; an `isRebuildingSession` flag routes rebuild failures to
  log+count only.

## Where it lives now

- `Sources/VideoDecoder.swift` — failure counter, `decodeRecoveryAction`,
  `recreateSession`, `onRecoveryAction`/`onRecovered`.
- `Sources/ReceiveLoopPolicy.swift` — shared backoff/give-up/classification
  policy, used by both the server's `receiveControlLoop`
  (`TailscaleScreenShareServer.swift`) and the client's `receiveLoop`
  (`TailscaleScreenShareClient.swift`); also adopted by the annotation
  back-channel's retry, replacing its own inline doubling.
- `Sources/MetalViewerRenderer.swift` — `ViewerStats` fields +
  `noteDecodeFailure`/`notePLISent`/`setDegraded` (coalesced to one pending
  main-queue publish, not one per failing frame).
- `Sources/ViewerStatsOverlay.swift` / `Sources/ViewerToolbar.swift` —
  degraded rows/banner and toolbar badge, both localized including the
  accessibility summary.
- `Sources/VideoEncoder.swift` — property-set failure aggregation, logged via
  `TSLogger` (not bare `print`).
- Tests: `DecodeRecoveryDecisionTests`, `ReceiveLoopPolicyTests` (pure), plus
  a `VideoCodecTests` extension feeding garbage AVCC into a real decoder.
  Local-only E2E extensions (`ScreenShareSyntheticFramesTests`/
  `ScreenShareControlChannelTests`) that need a live tsnet bring-up were
  **not added** in this environment — the pure-decision suites plus a manual
  `net-impair.sh` pass covered it instead.

## Other robustness fixes worth remembering

- `stopSharing` gained a reentrancy guard (`isStoppingShare`) — a give-up
  path and a user-initiated stop could otherwise interleave across await
  points and double-run `server.stop()`.
- Degraded state is explicitly cleared on `disconnect()` so it can't leak
  into the next viewing session.
- The decoder's per-frame guards (`formatDescription`/`session` nil-checks in
  the rebuild path) originally returned without counting a failure at all,
  freezing the ladder at the recreate rung forever if rebuild kept failing —
  fixed by routing every early-out through the same failure recorder.
