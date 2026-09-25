# Change what you're sharing mid-share (re-pick source without dropping viewers)

> **Status: shipped.** `AppState.changeShareSource()` / `TailscaleScreenShareServer.changeSource(filterData:)`.

## Problem

Previously, switching from "this window" to "whole display" (or a
different window) mid-share required Stop Sharing — tearing down the
server, disconnecting every viewer, and requiring everyone to reconnect by
hand — even though the pieces to avoid that already existed: the server
already survives capture-helper restarts, the helper wire already has a
`contentFilter` message, and viewers already adapt to mid-stream
resolution/codec changes via in-band parameter sets.

## Design decision: restart the helper, don't hot-swap it

Two options were evaluated:

- **(a) Hot-swap the live helper** via `SCStream.updateContentFilter` —
  ~0.3s gap, no replayd re-registration, but changes the helper wire
  protocol's semantics (`contentFilter` becomes dual-purpose instead of
  "sent once at startup"), adds an SCStream code path untestable on CI,
  and bypasses the one-process-one-target simplicity the helper
  architecture is built on.
- **(b) Restart the helper with the new selection (chosen).** Server-side
  only: swap `lastFilterData`, run the existing tracked restart
  (`restartCapture`/`scheduleHelperRestart`). Costs a ~1-2s freeze (helper
  spawn + SCStream bring-up + first IDR) — the same gap users already
  tolerate on a helper crash — but reuses the hardened orphan-safe restart
  lock, crash budget, and `forceH264` latch entirely, rather than
  re-proving them for a second code path. Process death also cleanly frees
  replayd's slot for the old target before the new one registers.

(a) remains a possible later optimization; the API shape (`changeSource(filterData:)`
next to `restartCapture()`) was kept so it could slot in behind it without
changing the call site.

**Nothing changes on the viewer side.** A new helper produces a fresh
encoder whose first AU is an IDR with in-band parameter sets — the same
path that already handles a live resolution change
(`extractParameterSets` → `setParameterSets` → `onVideoSizeChanged` →
window re-snap). A same-resolution switch is invisible; a
different-resolution one re-snaps the viewer window, exactly like today's
mid-stream resolution changes.

**The sharer overlay is rebuilt, not retargeted**, because
`SharerOverlayWindow.mode` is immutable by design (per-mode collection
behavior and window tracking). Rebuild happens lazily, on the next viewer
op or Draw toggle, rather than eagerly at switch time.

## What else the switch does

- Broadcasts `.clearAll` for annotations on switch — a window-relative
  stroke means nothing once the shared region changes, and stale strokes
  shouldn't float over unrelated content.
- Re-derives share metadata (name/resolution) the same way share-start
  does.
- Does **not** touch `forceH264`, `parameterSets`, or `helperCodec` — the
  new helper overwrites those in order before its first AU, same as any
  restart.

## Review fixes worth knowing about (not obvious from the design alone)

- **Restart serialization.** A crash-triggered auto-restart racing a
  `changeSource` could previously let both see no active helper and both
  spawn one, orphaning the loser (the stuck-recording-badge failure mode).
  `scheduleHelperRestart` now snapshot-installs the task slot under one
  lock hold, and each new restart task awaits its predecessor first —
  `stop()`'s drain still transitively drains the whole chain.
- **`lastFilterData` is lock-published** (`OSAllocatedUnfairLock`), not
  MainActor-only as first assumed — it's written by a nonisolated-async
  function and read inside detached restart tasks.
- **Post-await re-validation** in `changeShareSource`: after the retarget
  returns, it re-checks the share is still active *and* still the same
  server instance before any success side effect (clearAll, overlay
  rebuild, metadata update) — otherwise a stale picker result could
  retarget a share that was stopped and restarted while the picker was
  open, or advertise a phantom share. A `CancellationError` from the
  retarget is treated as a deliberate-stop artifact (log and return, no
  second teardown, no alert) rather than an error.
- **`.clearAll` now empties per-connection stroke tracking on the server**,
  not just the sharer's own overlay — otherwise a later viewer disconnect
  replayed `.undo` for already-cleared strokes and resurrected a
  torn-down overlay.

## Known limitation, accepted for v1

If the user picks a window and it closes before the helper resolves it,
the helper exits `permanent:` and the whole share tears down with an
alert — there's no "revert to the previous source" recovery. Fixing this
needs the previous selection's bytes kept aside; noted as a one-line
follow-up, not done.

## Where it lives

- `Sources/TailscaleScreenShareServer.swift` — `changeSource(filterData:)`,
  `lastFilterData`.
- `Sources/AppState.swift` — `changeShareSource()`, `isChangingSource`,
  `runPickerOrAlert()` (shared between share-start and change-source
  picker entry points).
- `Sources/MenuBarView.swift` — the SharingCard "Change Source…" button.
- `Sources/AppState.swift` — `overlayMode(for:)` (the pure
  selection→overlay-mode decision), tested by `OverlayModeDecisionTests`.
- Tests: `OverlayModeDecisionTests` (CI), `ScreenShareSyntheticFramesTests
  .testClientAdaptsToMidStreamResolutionChange` (CI-eligible, no capture
  helper — proves the viewer-side param-reinstall path),
  `ScreenShareCaptureHelperTests
  .testChangeSourceRestartsCaptureWithoutDroppingViewer` (local-only, real
  helper — the only place the full flow runs end to end).
- Shared local-E2E bring-up helpers live in `TailscreenE2E`
  (`skipCaptureTestOnCI`, `overrideHelperExecutable`, `mainDisplayFilterData`,
  `startCursorJiggle`).
