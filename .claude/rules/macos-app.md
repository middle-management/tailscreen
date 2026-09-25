---
paths:
  - "Apps/macOS/**"
---

# macOS app — architecture, UI surfaces, helper IPC

## Architecture & data flow

Capture/encoding run in a **capture-helper** child process (`Tailscreen --capture-helper`), one per share; a **picker-helper** child (`--picker-helper`) runs the native picker. Both exist because ScreenCaptureKit couples to `replayd`/WindowServer via XPC, and process death is the only reliable way to clear that coupling — isolating it in a child is what makes "Stop Sharing" always work.

```
AppState (@MainActor)
 ├─ ViewerPresentationState (portable phase + reconnect target)
 ├─ presentNativePicker() ──spawn──▶ picker-helper (SCContentFilter via stdout)
 ├─ TailscaleScreenShareServer
 │    ├─ HelperScreenCapture ──spawn──▶ capture-helper (filter via stdin, AUs via stdout)
 │    └─ RTP → UDP/7447, annotations/metadata → TCP/7447
 ├─ TailscaleScreenShareClient (UDP/7447 → depacketize → VideoDecoder → MetalViewerRenderer)
 ├─ VoiceChannel (PCM ↔ Opus ↔ RTP)
 ├─ TailscalePeerDiscovery / TailscaleIPNWatcher / TailscaleAuth
 └─ TailscreenMetadataService
```

The viewer `NSWindow`/`CAMetalLayer` is held for the process lifetime to avoid a teardown race between AppKit's autoreleasepool and VideoToolbox/Metal.

- **No stored "current view."** `MainWindowView` derives its pane per render from `(sharingState, connectionState)`; `paneName`/`recordsDiagnosticSurface` mirror that derivation for diagnostics rather than adding a second source of truth. `AppState.nodePhase` is likewise a **projection** of `TailscaleAuth`'s `isAuthenticated`/`isLoading` + discovery flags + `nodeFailure` (pure function pinned by `NodeBringUpPhaseProjectionTests`), never a stored phase — `TailscaleAuth` is portable, shared state this app doesn't own, so a parallel stored phase would just drift. Read `isAuthenticated` **before** `isLoading` (they settle at different points in login). `SharingState` (a `ShareBringUpPhase` typealias) IS stored, because the share is this app's own state; every exit from `beginSharing` funnels through one `defer` so a failure reason always lands as `.failed` (a `CancellationError` records nothing — stopping on purpose isn't a failure).

## UI surfaces

Two SwiftUI scenes, one `AppState`: the `Window` (`MainWindowView`) and the `MenuBarExtra` popover (`MenuBarView`). App is permanently `.regular` activation policy. The menu bar is declared via SwiftUI `Commands` (`AppCommands.swift`) — never a hand-built `NSApp.mainMenu` (SwiftUI's scene machinery stomps a manually-installed one back to default on every popover re-render).

- **Both surfaces render the same sharing view** out of the same components (`SharePreviewThumbnail`, `ShareSessionControls`, `ViewersList`, `PendingViewersList`, `ControlRequestsList`, `ApprovalToggle`, `ShareViaLinkSection`, `AudioDevicePickers`, …) — the popover is a sharer tool reachable without raising a window, not a lesser copy. Anything added to one surface belongs on the other in the same commit. Only deliberate diffs: Stop Sharing's position, and preview height (fixed 180pt in window, aspect-derived in popover).
- **Account menu / avatars.** `AccountMenuButton` is `NSViewRepresentable` around a real `NSMenu` (SwiftUI `Menu` flattens custom row labels). `MonogramAvatar` colors hash the name with **djb2, not `hashValue`** (per-process seeded, would reshuffle every launch).
- **Accessibility.** Color-only status (health dots) must also be spoken — hide the dot from VoiceOver and fold meaning into the adjacent label. Gate animation on `@Environment(\.accessibilityReduceMotion)`. No hover-only affordances. Use `minHeight` not `height` around scaling text; `@ScaledMetric` for fixed widths around text/symbols.
- **Notifications.** One poster (`SharerNoticeCenter`), one delegate, one decision layer (`SharerNoticeDecision`). Button *label* is localized via `L(_:)`; button *key* is `NoticeAction.rawValue` — passed as separate args to `UNNotificationAction`, because a label in the key slot works in English and silently drops every press elsewhere. `SharerNotice.id` is the notification identifier (re-post replaces the banner); resolve the peer against the **live** list before acting — a banner can outlive the peer by an hour. Register categories in `install()` before anything posts, or delivery silently drops the buttons.
- **Viewer window.** Built once in `AppState.ensureViewer()`, kept for process lifetime. One placard covers both pre-video phases (`connecting`/`awaitingApproval`); the terminal pane's `viewerSessionEnding` is the `ended` reason ONLY (a `failed` phase gets `failureMessage` in its own words) — check `viewerSessionIsOver`, never `viewerSessionEnding != nil`, to ask "is a terminal pane up." Mid-session problems render as non-modal `ViewerNoticeBanner`, never `NSAlert`. Toolbar validates via `NSToolbarItemValidation` (AppKit auto-validation re-enables capability-disabled items).
- **Hotkeys are user-remappable** (`HotkeyChordStore`). Never print a chord literal — read `AppState.micShortcutDisplay`/`revokeShortcutDisplay` (nil = hide, don't misprint default).
- **Share by token.** Menubar Share-via-Link section; hub's Join-a-Share (sheet + welcome-pane field, both edit `AppState.joinInput`, also fed by the `tailscreen:` URL scheme — registered only in the packaged .app, never a `make run` binary); Settings → Link sharing; guest rows show a Guest badge with plain Accept/Deny only (guests have no StableNodeID). A guest-only share started signed out turns the link's off-toggle into a mode line (turning it off would strand the only transport) and hides the approval toggle (no tailnet viewers to approve).
- **Capture outline** (`CaptureOutlineWindow`) is a separate window from the annotation overlay (`sharingType = .none` — never captured, or every viewer sees a border around their own view) and tracks the same region statics so the two can't disagree.

## Capture-helper IPC

- **Spawn.** Same binary re-execed with `--capture-helper`; stdin/stdout pipes, stderr passthrough. Quality knobs travel as env vars: `TAILSCREEN_FPS_CAP`, `TAILSCREEN_CODEC_PREF`, `TAILSCREEN_MAX_BITRATE`, `TAILSCREEN_ENCODER_QUALITY`, `TAILSCREEN_FORCE_H264` (wins over codec pref). An explicit `hevc` preference drops the H.264 fallback rung entirely (`VideoEncoder.allowsH264Fallback`) and the server ignores viewer CODEC_NO. `Process.environment` **replaces**, doesn't merge — always seed from the parent's env first. Color: `TAILSCREEN_FORCE_8BIT=1` pins 8-bit; `TAILSCREEN_ENABLE_10BIT`/`TAILSCREEN_ENABLE_HDR` are Settings-driven (not user env), projected via the static `HelperScreenCapture.colorEnvironment` lock (crash-restart builds its own `HelperScreenCapture` deep inside TailscreenSharer, which knows nothing about macOS Settings) so every spawn picks up the current choice. Also call `server.setTenBitCaptureRequested(_:)` on every flip — the env overlay tells the helper what to capture, this call tells the server whether to police viewers' `.tenBit` capability.
- **Startup.** Helper waits on stdin for a framed `contentFilter` (JSON `PickerSelection`), resolves IDs via `SCShareableContent` (legal only here, never in the main process). **Cloaked Apps** rides the same JSON (`excludedBundleIDs`); mid-share cloak edits or a cloaked app launching mid-share re-push the filter through the tracked restart.
- **Wire.** `[type:1][len:4 BE][payload:N]`. Types: AU (AVCC), parameter sets, preview thumbnail, heartbeat (~1Hz, proves the pipeline alive even on idle/no-pixel frames), system-audio AU (raw Opus, `OutType.audioAccessUnit 0x07`), log, fatal, user-stopped; controls: request-keyframe, set-bitrate, content-filter, `setAudioEnabled` (0x04, 1-byte latch), `setFrameInterval` (0x05, `[fps:4 BE]`, live SCStream reconfigure), shutdown. `HelperFrameWriter` is lock-serialized — written from 4 threads (encoder, MainActor previews, SCStream video delegate, SCStream audio-output).
- **Lifecycle.** Helper exit 0 + `userStopped` = quiet teardown; any other exit auto-restarts up to 3× within 30s, reusing cached selection bytes. "Change Source…" rides this same restart path, plus a `.clearAll` annotation broadcast. **Hung-helper watchdog**: 15s silence → idle sweep restarts capture (the heartbeat is what keeps a healthy static-screen share from tripping it); escape hatch `TAILSCREEN_DISABLE_HELPER_WATCHDOG=1`.

## Picker-helper IPC

Re-execed with `--picker-helper`; only stdout is a pipe. Wire: `[length:4 BE][JSON:N]` (`PickerSelection`); `length==0` = cancelled. Exit 0 selected / 1 cancelled / ≥2 error. Can't ship a live `SCContentFilter` — it doesn't conform to `NSCoding`. Parent `waitUntilExit()`s so consecutive spawns can't race the singleton's teardown.

## macOS pitfalls

- **Notarized build: "Microphone permission denied", no row in Privacy & Security.** The hardened runtime blocks any TCC-gated device not claimed in `Apps/macOS/Resources/Tailscreen.entitlements` — no prompt, no row. `make run` isn't hardened and works, which is how this can ship unnoticed. Add new device/API keys there; codesign's self-check greps the signed app for them. The file is XML — a comment must not contain `--`, or the plist fails to parse.
- **"A closure a `@MainActor` type hands to an imported ObjC API" traps at runtime, not compile time.** `AVAudioPlayerNode.scheduleBuffer(_:completionHandler:)`, `installTap`, `UNUserNotificationCenter.requestAuthorization` etc. call their (non-`@Sendable`) closure off the main queue; a closure literal written inside a `@MainActor` type inherits that isolation and traps (`EXC_BREAKPOINT`) when the framework calls it back. Fix: bind the handler to an explicit `@Sendable` local, or form it in a `nonisolated` helper, then `Task { @MainActor in … }` inside. `make lint-isolation` (`scripts/check-callback-isolation.py`'s `API_CALLBACKS`) catches known APIs in source — add new ones there. `make sil-isolation-report` is a diagnostic to diff, not a gate.
- **Inbound voice goes silent for the rest of the session** when the mic comes on or the output device changes (outbound keeps working). `MicCapture` counts scheduled buffers per `AVAudioPlayerNode` and drops as overruns past the jitter cap; every engine restart discards queued buffers (with or without their completions) without the count coming down, so it's wrong by the discarded depth. Rule: `resetPlaybackQueues` at every point queues are known empty, called **before** `node.stop()` (else discarded buffers' completions arrive as orphans). Never call `play()` after a restart — `scheduleSamples`' kick re-primes.
- **The same executor precondition rides every `@objc` override on a `@MainActor` view/window**, including a one-line `override var`, and AppKit calls some from geometry paths thousands of times/minute (e.g. `isFlipped` from hit-testing). If the override changes nothing, delete it. If load-bearing, mark it `nonisolated` when safe by inspection (a getter returning a literal). `make lint-isolation` does **not** catch this shape — it only checks closures.
- **Never call `SCShareableContent` in the main process** — it registers the parent with `replayd`, and the helper's `SCStream` then fails with "application connection being interrupted."
- **Never present `SCContentSharingPicker` in the main process** — spawn `--picker-helper`.
- **Never deserialize an `SCContentFilter` in the main process** — the decoded filter retains XPC handles; unarchive only inside the capture-helper.
- **All SCStream lifecycle lives in the helper** — the main process only spawns it and broadcasts what comes back.
- **Stuck "Stop Sharing" badge** = an orphaned helper from a stop/restart race — preserve the screen-share server's await-pending-restart-then-teardown ordering, including on the "Change Source…" path (always via `changeSource(filterData:)`, never a direct spawn).
- **Auth flow needs an active node** — interactive login only works after Start Sharing or Connect-to has initialized the tsnet node.
