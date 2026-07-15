# Change what you're sharing mid-share (re-pick source without dropping viewers)

> Status: implemented in this PR.

## Problem & motivation

Once a share is live, the picked source is frozen. To switch from "this window" to "whole
display" (or to a different window) the sharer must Stop Sharing — which tears down the
server, disconnects every viewer (`SERVER_BYE` fan-out, `Sources/TailscaleScreenShareServer.swift:1630-1652`),
drops the tsnet listeners, and releases the share lock (`Sources/AppState.swift:663-697`) —
then re-pick and re-share, and every viewer must reconnect by hand. All the machinery to
avoid this already exists: the server keeps viewers alive across capture-helper restarts
(`restartCapture`, `Sources/TailscaleScreenShareServer.swift:609-614`), the helper wire has a
`contentFilter` control message (`Sources/CaptureHelperWire.swift:72`), and viewers already
adapt to mid-stream resolution/codec changes via in-band parameter sets. We only need to
let the user re-run the picker and point the existing capture pipeline at the new selection.

## Goals / Non-goals

**Goals**
- A "Change Source…" action available while `sharingState == .active` (SharingCard button
  in the menubar popover; optionally a menu item later).
- Re-run the `--picker-helper`; on selection, retarget capture to the new
  `PickerSelection` without disturbing the UDP/TCP listeners, viewer roster, voice channel,
  approval state, or share lock. Picker cancel = keep current share, no-op.
- Viewers recover automatically (new keyframe + in-band parameter sets → decoder rebuild →
  `onVideoSizeChanged` window snap).
- Sharer-side UI follows: SharingCard preview/resolution, `SharerOverlayWindow` mode,
  metadata served to peers.
- CI-able decision tests + a local E2E test.

**Non-goals**
- Hot-swap with zero-frame gap (evaluated below; recommended as a follow-up, not v1).
- Changing multiple sources / picture-in-picture.
- Any wire-protocol change on the viewer-facing RTP/TCP side (none is needed).
- Preserving on-screen annotations across a source switch (they're scoped to the shared
  region; carrying a window-relative stroke onto a display share is meaningless).

## Current state (with file:line references)

- **Selection caching.** `TailscaleScreenShareServer.lastFilterData` holds the JSON
  `PickerSelection` bytes (`Sources/TailscaleScreenShareServer.swift:201-207`), set once in
  `start()` (`:421-423`) and reused verbatim by every helper respawn
  (`scheduleHelperRestart`, `:641-674`, cached-filter read at `:653-658`). The selection is
  primitive IDs, not a live filter (`Sources/PickerSelection.swift:9-25`), and each helper
  re-resolves them independently — restart against new bytes is architecturally identical
  to restart against old bytes.
- **Does the helper accept a second `contentFilter`?** **No.** The stdin reader dispatches
  `.contentFilter` at any time (`Sources/CaptureHelperMain.swift:103-128`), but
  `CaptureHelperRunner.startWithFilter` explicitly refuses a second start:
  `"capture-helper: ignored duplicate start request"` guarded by `hasStarted`
  (`Sources/CaptureHelperMain.swift:248-256`). So option (a) requires helper changes;
  option (b) requires none.
- **Restart machinery.** `restartCapture()` → `scheduleHelperRestart(resetCrashBudget:)`
  (`Sources/TailscaleScreenShareServer.swift:609-674`): stops the old helper, respawns
  against `lastFilterData`, tracked in `restartTask` so `stop()` drains it first
  (`:1617-1628`) — the orphan-safe/stuck-badge protections CLAUDE.md warns about. Crash
  budget: `classifyHelperExit` / `slidingWindowCrashCount` (`:447-474`). The codec-fallback
  path already triggers exactly this kind of live respawn (`handleCodecUnsupported`,
  `:853-865`), and `forceH264` is re-read on every spawn (`:585`).
- **Picker.** `PickerHelperClient.run()` spawns `--picker-helper`, reads one framed
  `PickerSelection`, `waitUntilExit()`s so consecutive spawns can't race the picker
  singleton (`Sources/PickerHelperClient.swift:31-97`); the helper presents with all modes
  and exits on first callback (`Sources/PickerHelperMain.swift:82-113`). Nothing about it is
  share-start-specific — it is already reusable mid-share.
- **AppState flow.** `presentNativePicker()` → `startSharing(filterData:)`
  (`Sources/AppState.swift:445-461, 467-661`). `startSharing` acquires the cross-instance
  `shareLock` (`:473-481`), decodes `currentSelection` (`:487`), builds the server once
  (`server == nil` branch, `:504`), and updates metadata (`:650`). `stopSharing`
  (`:663-697`) is the only teardown. There is no re-entry path for "already sharing."
- **Resolution changes mid-stream — verified end-to-end.** Helper: new frame dims →
  encoder rebuild → `onParameterSets` + `onEncodedData` written inline, in order
  (`Sources/CaptureHelperMain.swift:377-416`, ordering comment `:392-400`). Server: params
  cached before the first new AU broadcasts (`Sources/HelperScreenCapture.swift:199-220`,
  `Sources/TailscaleScreenShareServer.swift:487-509`), prepended in-band on every keyframe
  (`:1477-1485`). Viewer: `extractParameterSets` on each IDR → `decoder.setParameterSets`
  on change (`Sources/TailscaleScreenShareClient.swift:509-518, 526-558`) → renderer resizes
  drawable and fires `onVideoSizeChanged` (`Sources/MetalViewerRenderer.swift:366-378`) →
  viewer window re-snaps (`Sources/AppState.swift:1010-1028`). A source switch is just a
  bigger resolution change, plus the same-dims case (which needs a forced keyframe, which
  a fresh encoder emits anyway).
- **Sharer overlay.** `SharerOverlayWindow`'s mode is immutable (`private let mode: Mode`,
  `Sources/SharerOverlayWindow.swift:46`, set in `init` `:79`), with per-mode collection
  behavior and a window-tracking timer (`:93-105, 217-235`). It cannot be retargeted —
  it must be rebuilt. `AppState.ensureSharerOverlay()` builds it from `currentSelection`
  (`Sources/AppState.swift:722-760`).
- **Metadata.** `TailscreenMetadataService.updateMetadata` (`Sources/TailscreenMetadata.swift:104-115`)
  regenerates name + resolution; note it reads `NSScreen.main` (`:91-101`) — already
  approximate for window shares, so a switch only needs `updateMetadata` re-called (the
  SharingCard's aspect, `Sources/MenuBarView.swift:316-341`, follows `currentMetadata`).

## Design

**Evaluated options**

*(a) Hot-swap in the live helper.* Send a second `contentFilter`; helper calls
`SCContentFilter`-rebuild (`buildFilter`, `Sources/CaptureHelperMain.swift:154-188`) then a
new `ScreenCapture.updateContentFilter(_:)` wrapping `SCStream.updateContentFilter`
(pattern exists for `updateConfiguration`, `Sources/ScreenCapture.swift:197-220`). The
existing contentRect-change debounce (`Sources/CaptureHelperMain.swift:306-333`) would then
resize the buffer, and the dims-change encoder rebuild does the rest. Pros: ~0.3 s gap, no
replayd re-registration. Cons: changes helper protocol *semantics* (`contentFilter` becomes
dual-purpose — `Sources/CaptureHelperWire.swift:65-72` documents "sent once at startup"),
adds an SCStream code path we can't exercise on CI at all, must handle mid-swap
`SCShareableContent` re-resolution failures inside a live helper, and bypasses the
one-process-one-target simplicity that the whole helper architecture buys.

*(b) Restart the helper with the new selection.* Server-side only: swap `lastFilterData`,
then run the existing tracked restart. Pros: zero helper changes; reuses the hardened
orphan-safe restart lock (`restartTask` drain in `stop()`, `:1617-1628`); process death
cleanly releases replayd's slot for the old target before the new one registers; identical
to the already-shipping codec-fallback respawn. Cons: ~1-2 s video gap (helper spawn +
SCStream bring-up + first IDR) — viewers see a brief freeze, then recover, exactly as they
do today on a helper crash.

**Recommendation: (b) for v1.** The gap is the same one users already tolerate on
auto-restart, and every hard property (no orphaned helper, no stuck recording badge, crash
budget, forceH264 latch) is inherited rather than re-proven. Option (a) is a clean later
optimization once `updateContentFilter` behavior across kind changes (window→display) is
validated by hand; the v1 API below is deliberately shaped so (a) can slot in behind it.

**New server API** — `Sources/TailscaleScreenShareServer.swift`:

```swift
/// Retarget capture to a new PickerSelection without touching listeners,
/// viewers, or approval state. Reuses the tracked-restart path so it is
/// safe against concurrent stop()/auto-restart.
func changeSource(filterData: Data) async throws {
    guard isRunning else { return }
    lastFilterData = filterData           // future restarts use the new target too
    try await restartCapture()            // resetCrashBudget: true — fresh budget for the new target
}
```

Do **not** clear `forceH264` (viewer decode capability didn't change) and do not touch
`parameterSets`/`helperCodec` — the new helper overwrites them in-order before its first AU
(see "verified end-to-end" above). `lastFilterData` is only ever written from the
`@MainActor` call sites (`start`, `changeSource`) and read inside the tracked restart task;
document that, matching the existing `@unchecked Sendable` conventions of this class.

**New AppState flow** — `Sources/AppState.swift`:

```swift
func changeShareSource() async {
    guard sharingState == .active, let server else { return }
    let result: Data?
    do { result = try await PickerHelperClient.run() }
    catch { presentError(...); return }
    guard let filterData = result else { return }          // cancel = keep current share
    guard sharingState == .active else { return }          // user stopped while picking
    currentSelection = try? JSONDecoder().decode(PickerSelection.self, from: filterData)
    do { try await server.changeSource(filterData: filterData) }
    catch { await stopSharing(reason: "changeSource failed: \(error)"); presentError(...); return }
    // Rebuild the overlay for the new mode; preserve the draw toggle.
    let wasDrawing = isSharerOverlayVisible
    sharerOverlay?.hide(); sharerOverlay = nil
    if wasDrawing { ensureSharerOverlay().setInputEnabled(true) }
    metadataService.updateMetadata(isSharing: true, shareName: ...)  // same string as :650
    previewImage = nil                                      // next helper preview repopulates
}
```

No `shareLock` interaction — we hold it already (`:473`); re-acquiring would deadlock the
guard. The picker-cancel and picker-error paths leave the share untouched.

**UI** — SharingCard (`Sources/MenuBarView.swift:422-458`): add an icon button
(`rectangle.on.rectangle`, `.help(L("Change Source…"))`) to the existing button row,
calling `Task { await appState.changeShareSource() }`. While the picker is up the share
keeps running, so no interstitial state is needed; disable the button while a change is
in flight (a small `@Published var isChangingSource` flag).

**Viewers:** nothing to do. New helper → fresh encoder → first AU is an IDR with in-band
params; same-resolution switches change content invisibly, different-resolution switches
ride the existing `setParameterSets` → `onVideoSizeChanged` path. The server's existing
per-viewer `requestKeyframe` on join/PLI covers stragglers.

## Implementation steps (ordered checklist)

1. [ ] `Sources/TailscaleScreenShareServer.swift`: add `changeSource(filterData:)` next to
   `restartCapture()` (`:609`); update `lastFilterData`'s doc comment (`:201-207`) to say
   "or the most recent `changeSource`".
2. [ ] `Sources/AppState.swift`: add `@Published var isChangingSource = false` and
   `func changeShareSource() async` (near `presentNativePicker`, `:445`); overlay rebuild
   uses existing `ensureSharerOverlay()` (`:722-741`) after nil-ing `sharerOverlay`.
3. [ ] Factor the share-name string ("\(hostname)'s Screen", duplicated at `:506,647,650`)
   into a private helper so `changeShareSource` reuses it.
4. [ ] `Sources/MenuBarView.swift:422-458`: add the Change Source button (disabled when
   `appState.isChangingSource`); add `L("Change Source…")` / help/accessibility keys to
   `Sources/Resources/en.lproj/Localizable.strings`.
5. [ ] Make `AppState.overlayMode(for:)` (`:747-760`) `static` internal (drop `private`) —
   it's the pure selection→overlay-mode decision; add `OverlayModeDecisionTests`.
6. [ ] Tests (below): new unit suite + `ScreenShareSyntheticFramesTests` extension +
   `ScreenShareCaptureHelperTests` extension.
7. [ ] Update CLAUDE.md: add the new pure-decision suite to the extract-the-decision list
   (the file mandates this) and note `changeSource` beside the restart-lock pitfall.
8. [ ] Manual pass: `./test-local.sh 2`, share display → switch to a window → switch back;
   verify viewer window re-snaps twice, recording badge never sticks, Control Center
   "Stop" during the gap still tears down quietly (`userStopped` path,
   `Sources/TailscaleScreenShareServer.swift:513-525` → `Sources/AppState.swift:531-535`).

## Files to change / add

| File | Change |
|---|---|
| `Sources/TailscaleScreenShareServer.swift` | `changeSource(filterData:)` (~15 LOC) near `:609`; doc tweaks |
| `Sources/AppState.swift` | `changeShareSource()`, `isChangingSource`, overlay rebuild, share-name helper, `overlayMode` visibility |
| `Sources/MenuBarView.swift` | SharingCard button (`:422-458`) |
| `Sources/Resources/en.lproj/Localizable.strings` | new keys |
| `Tests/TailscreenTests/OverlayModeDecisionTests.swift` | **new** — CI-able |
| `Tests/TailscreenTests/ScreenShareSyntheticFramesTests.swift` | mid-stream resolution-change case |
| `Tests/TailscreenTests/ScreenShareCaptureHelperTests.swift` | live source-switch case (local-only) |
| `CLAUDE.md` | test-list + pitfalls updates |

## Testing strategy

- **CI-able pure decisions:** `OverlayModeDecisionTests` — every `PickerSelection.kind` ×
  missing-ID fallback maps to the right `SharerOverlayWindow.Mode` (`Sources/AppState.swift:747-760`).
  The restart plumbing itself is already covered by `HelperRestartDecisionTests`
  (`classifyHelperExit`, crash budget) — `changeSource` adds no new branching there.
- **CI-eligible pipeline test:** extend `ScreenShareSyntheticFramesTests` (server with
  `filterData: nil`, no helper — `Sources/TailscaleScreenShareServer.swift:1707-1731` test
  seams): inject H.264 params+IDR at 640×360, assert first decode, then
  `injectSyntheticParameters` + IDR at 960×540 and assert the client's
  `onDecodedFrameForTesting` delivers the new dims — proving the viewer-side switch path
  (param re-install → decoder rebuild) with zero capture machinery. Skips on
  VideoToolbox-less runners like the existing suite.
- **Local-only E2E:** extend `ScreenShareCaptureHelperTests` (real helper, on-screen
  window): start via `TAILSCREEN_AUTOSHARE_DISPLAY=1`, await first frame, then call
  `server.changeSource(filterData:)` with a freshly encoded main-display `PickerSelection`
  (same-target switch — deterministic on a one-display CI-less Mac) and assert (1) a new
  helper PID via the spawn log, (2) decoding resumes on the viewer within a timeout, (3)
  no `onCaptureStopped` fired. Self-skips on `CI`/`GITHUB_ACTIONS` like its siblings —
  tsnet + SCStream can't run on hosted runners per CLAUDE.md.
- **Not testable in-process:** the real picker UI mid-share — covered only by the manual
  pass (mirrors `PickerHelperSmokeTests`' opt-in lifecycle test rationale).

## Risks & pitfalls

- **Restart-lock ordering (CLAUDE.md: "Stop Sharing badge stuck on").** `changeSource` must
  go through `restartCapture`/`scheduleHelperRestart` — never spawn a helper directly —
  so `stop()`'s drain (`:1617-1628`) and the post-spawn `isRunning` re-check (`:666-669`)
  keep protecting against orphaned helpers.
- **Never touch SC* in the main process.** The new flow only moves JSON bytes: picker runs
  in `--picker-helper`, filter reconstruction stays in the capture-helper
  (`buildFilter`, `Sources/CaptureHelperMain.swift:154-188`). No `SCShareableContent`, no
  `SCContentFilter` deserialization, no picker presentation parent-side.
- **Concurrent auto-restart.** A crash-triggered respawn racing `changeSource` is benign in
  either order (both funnel through `scheduleHelperRestart`; whichever runs last wins, and
  `lastFilterData` is the new bytes by then) — but note it in the code comment; the
  finished-task-left-in-slot semantics (`:636-639`) already tolerate overlapping restarts.
- **Stale-ID selection.** The user can pick a window and close it before the helper
  resolves it — helper exits with `permanent:` (`Sources/CaptureHelperMain.swift:119-127`)
  → `onCaptureStopped` → AppState tears the share down with an alert (`:520-545`). Accept
  for v1; a friendlier "revert to previous source" needs the old bytes kept aside (one-line
  follow-up).
- **Picker serialization.** `PickerHelperClient.run()` already `waitUntilExit()`s
  (`Sources/PickerHelperClient.swift:86-89`); the `isChangingSource` flag prevents a second
  concurrent picker from the UI. Don't call `changeShareSource` from
  `presentNativePicker`'s path — they're separate entry points.
- **Overlay/annotation semantics.** Rebuilding the overlay drops existing strokes; viewers'
  canvases are not cleared automatically. Broadcast a `.clearAll` annotation op on switch
  (`broadcastAnnotation`, `Sources/TailscaleScreenShareServer.swift:735-737`) so stale
  strokes don't float over unrelated content.
- **Metadata accuracy.** `getCurrentScreenResolution` uses `NSScreen.main`
  (`Sources/TailscreenMetadata.swift:91-101`) — pre-existing inaccuracy for window shares;
  do not "fix" it in this PR beyond re-calling `updateMetadata` (real dims reach the
  server via `onEncoderResolution`, `Sources/HelperScreenCapture.swift:199-206`).

## Deviations

Where the implementation departs from the letter of this plan (all line numbers above
have drifted — symbols were trusted over positions):

- **`changeSource` body.** Implemented as `lastFilterData = filterData` followed by
  `try await restartCapture()` rather than inlining the `scheduleHelperRestart` call —
  identical semantics (tracked restart, `resetCrashBudget: true`), one fewer copy of the
  guard.
- **`changeShareSource` re-entry checks.** Beyond the sketched `sharingState == .active`
  re-check after the picker returns, the implementation also identity-checks
  `self.server === server` so a stale selection can't retarget a share that was torn
  down and restarted while the picker was up. The `isChangingSource` flag additionally
  gates entry into the function itself (not just the UI button).
- **Share-name helper.** Current code duplicated the hostname computation twice and the
  share-name string once (not three times as the plan's stale line refs said); both were
  factored into `AppState.localHostname()` / `localShareName()`.
- **Local E2E assertions.** `ScreenShareCaptureHelperTests.
  testChangeSourceRestartsCaptureWithoutDroppingViewer` asserts (1) the viewer decodes
  again after the switch — the post-switch expectation is installed only after
  `changeSource` returns, when the old helper is provably dead — and (2)
  `onCaptureStopped` never fired. The planned "assert a new helper PID via the spawn
  log" was dropped: the spawn log line isn't programmatically observable from the test
  process, and decode-after-switch with the old helper stopped is equivalent evidence.
- **Overlay rebuild.** When the sharer wasn't drawing at switch time, the overlay is
  left nil instead of eagerly rebuilt — `ensureSharerOverlay()` lazily rebuilds (with
  the new mode from the updated `currentSelection`) on the next viewer op or Draw
  toggle, matching the existing lazy-creation contract.
- **Localized strings.** Keys added to both `en.lproj` and `sv.lproj` (the plan predates
  the Swedish catalog).

The full mid-share flow is local-E2E-only; the covering local suite is
**`ScreenShareCaptureHelperTests`** (`testChangeSourceRestartsCaptureWithoutDroppingViewer`),
with the viewer-side param-reinstall path covered CI-eligibly by
`ScreenShareSyntheticFramesTests.testClientAdaptsToMidStreamResolutionChange` and the
selection→overlay-mode decision by `OverlayModeDecisionTests`.

### Review fixes

Post-implementation review batch (independent-reviewer findings):

- **Restart serialization.** `scheduleHelperRestart` now snapshot-and-installs the
  `restartTask` slot under a single lock hold, and each new restart task's first act is
  to await its predecessor. Two overlapping restarts (crash auto-restart racing a
  `changeSource`) could previously both see `helperCapture == nil`, both spawn helpers,
  and the second assignment clobbered the first — an orphaned `--capture-helper` holding
  replayd's slot (the stuck-badge pitfall). `stop()`'s drain is unchanged: the slot holds
  the newest task, and awaiting it transitively drains the whole chain.
- **`lastFilterData` locked.** Now `OSAllocatedUnfairLock<Data?>` — it's written by the
  nonisolated-async `changeSource` and read inside detached restart tasks, so the
  earlier "MainActor-only writes" doc claim was a data race under TSan.
- **`changeSource` signals no-ops.** Returns `Bool` (`false` when the server isn't
  running) and schedules the tracked restart directly instead of via `restartCapture()`,
  so a stop racing the call surfaces as the restart task's `CancellationError` rather
  than silently succeeding past `restartCapture`'s own `isRunning` guard.
- **Post-await re-validation.** `changeShareSource` re-checks
  `didRetarget && sharingState == .active && self.server === server` after
  `changeSource` returns, before any success side effect (clearAll broadcast, overlay
  rebuild, `updateMetadata(isSharing: true, …)`, preview drop) — killing the
  phantom-share-advertised bug. `CancellationError` from the retarget is treated as a
  deliberate-stop artifact: log and return, no second `stopSharing`, no alert (the stop
  path owns teardown).
- **Server-broadcast `.clearAll` clears tracking.** `broadcastAnnotation` now empties
  every connection's tracked-UUID set on any `.clearAll` — otherwise a later viewer
  disconnect replayed `.undo` for already-cleared strokes and (via the sharer's
  `onAnnotationReceived` → `ensureSharerOverlay`) resurrected a torn-down sharer
  overlay. The tracking has no test seam (it's private and observable only through the
  live control listener), so this is covered by the local E2E flow rather than a unit
  test.
- **Picker-failure alert localized + deduped.** Both picker entry points now share
  `AppState.runPickerOrAlert()`; the alert strings route through `L()` with keys added
  to both `en.lproj` and `sv.lproj`.
- **Shared E2E bring-up helpers.** The CI-skip guard, `TAILSCREEN_HELPER_EXE` override,
  main-display `PickerSelection` encode, and cursor-jiggle task moved from the two
  `ScreenShareCaptureHelperTests` tests into `TailscreenE2E`
  (`skipCaptureTestOnCI` / `overrideHelperExecutable` / `mainDisplayFilterData` /
  `startCursorJiggle`), behavior-identical.

## Estimated scope

**M** — ~250-350 LOC: ~40 server+AppState logic, ~40 UI/strings, ~180-250 tests. No wire
changes, no helper changes; the risk lives entirely in lifecycle ordering, which is why v1
piggybacks on the existing tracked-restart path.
