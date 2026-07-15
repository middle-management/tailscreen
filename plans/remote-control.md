# Opt-in Remote Control (viewer input injected on the sharer's machine)
> Status: proposed — this PR contains only the plan; implementation is a follow-up iteration.

## Problem & motivation
Tailscreen today is view-only plus annotations. A common ask for pair-programming
and remote-assist is letting a viewer *drive* the sharer's machine: move the
mouse, click, scroll, type. This plan adds an **opt-in, single-grantee** remote
control path that reuses the existing reliable TCP control channel for input
events and injects them with `CGEvent` on the sharer side, behind an explicit
grant the sharer can revoke instantly.

Safety is the whole point: nothing is ever injected unless the sharer has
actively granted control to exactly one viewer, the grant auto-revokes on
disconnect, and a hotkey/menu kills it immediately. This builds directly on the
per-viewer approval machinery that already exists (`requireApproval`,
`approveViewer`/`denyViewer`, `PendingViewerInfo`).

## Goals / Non-goals
Goals:
- Viewer can *request* control; sharer grants to **one** viewer at a time.
- Mouse move/down/up/scroll + key down/up injected on the sharer via `CGEvent`.
- Normalized-coordinate schema that maps correctly for display / window / app shares.
- Instant revoke (menu item + global hotkey), auto-revoke on viewer disconnect.
- Server-side hard gate: events from any non-granted viewer are dropped.
- Rate-limit / coalesce mouse-moves so a 120 Hz viewer can't flood the injector.

Non-goals (this iteration):
- Multi-viewer simultaneous control (explicitly one grantee).
- Clipboard sync, drag-and-drop of files, IME/dead-key composition correctness
  beyond basic keycode+modifier passthrough.
- Controlling a *window* share's off-screen or occluded regions — we inject at
  global display coordinates; whatever is under that point receives the event.
- Gamepad / pen / multi-touch gestures.

## Current state (with file:line references)
- **No input injection anywhere.** `grep CGEvent|CGEventPost|AXIsProcessTrusted`
  over `Sources/` returns nothing. This is greenfield.
- **TCP control channel** is the transport to extend:
  - `ScreenShareProtocol.swift:22-54` — `ScreenShareMessage` enum, `MessageType`
    (`annotation = 0x03`, `requestToShare = 0x04`), 5-byte framing `[type:1][len:4 BE][payload]`.
  - `ScreenShareProtocol.swift:57-109` — `ScreenShareMessageParser` incremental decode.
  - `TailscreenControlListener.swift:24-169` — long-lived listener; `onAnnotation`,
    `onRequestToShare`, `onConnectionClosed` callbacks (`:34-43`), per-connection
    `UUID` (`:118-120`), `send(_:to:)` (`:90-93`), `broadcast(_:excluding:)` (`:98-111`),
    `dispatch` (`:161-168`).
  - Viewer side: `TailscaleScreenShareClient.swift:116-124` `sendAnnotationOp`,
    `:131-150` `receiveAnnotationLoop`, `:88-101` annotation channel plumbing.
  - Sharer side: `TailscaleScreenShareServer.swift:681-719` `installControlHandlers`
    wires `listener.onAnnotation`/`onConnectionClosed`; `:276` `onAnnotationReceived`.
- **Per-viewer identity / approval** to build the grant on:
  - `TailscaleScreenShareServer.swift:44-49` `PendingViewerInfo`, `:31-36` `ViewerInfo`
    (both keyed by `"ip:port"` = `id`).
  - `:1083-1130` `approveViewer`, `:1135-1152` `denyViewer`, `:136` `requireApproval` lock,
    `:282-287` `onViewersChanged`/`onPendingViewersChanged`.
  - `AppState.swift:80-95` `pendingViewers` + `requireViewerApproval` binding,
    `:1793-1813` approve/deny pass-through.
  - **Prerequisite:** the viewer-consent/allow-list work in
    `plans/viewer-consent-and-access-control.md`. Remote control MUST require that
    a viewer is an approved, connected viewer before it can even request control;
    the allow-list identity (stable per-peer, not just `ip:port`) is what the grant
    is pinned to so a NAT rebind can't inherit a grant.
- **Coordinate context already computed** for annotations/overlay — reuse:
  - `Annotation.swift:16-19` — coords normalized `[0,1]`, origin top-left, video-frame
    space. Same convention for input.
  - `MetalViewerRenderer.swift:127-129,342-378` — `videoSize`, `onVideoSizeChanged`.
  - `AppState.swift:980-1034` + `AspectFitHostView` (`:1891-1975`) — viewer maps window
    points ↔ letterboxed video rect (`aspectFitRect()` `:1957`); `normalize(_:in:)` at
    `AnnotationCanvasView.swift:99-106`.
  - `SharerOverlayWindow.swift:300-340` — **the sharer-side mapping**: `cgWindowFrame(for:)`
    (CGWindowList bounds for a `CGWindowID`), `cgToCocoaFrame` (Quartz↔Cocoa). We need the
    *inverse* (normalized → global Quartz) but the same primitives.
  - `PickerSelection.swift:9-25` — `kind`/`displayID`/`windowID`/`bundleIDs` = capture
    geometry; cached at `AppState.swift:487` (`currentSelection`) and server `:207`
    (`lastFilterData`).
- **Injection placement:** capture+SCStream live only in the `--capture-helper` child
  (CLAUDE.md forbids `SCContentFilter`/`SCShareableContent` in the main process). The
  **main process** owns the tsnet node, control listener, and `@MainActor` `AppState`.
  `CGEvent` needs **Accessibility** TCC (not Screen Recording) and never touches
  `replayd`, so it needs no helper isolation.
- **Toolbar/draw gate:** `ViewerToolbar.swift:37,161-221` (`.selectOne` tool radio);
  `AnnotationCanvasModel.swift:30,36` (`currentTool`/`isInputEnabled`); overlay input
  gate `AnnotationOverlayHostView.swift:44`.
- **Global hotkey** primitive exists: `GlobalHotkey.swift:16-27` (Carbon, no
  Accessibility needed) — reuse for the sharer's panic-revoke.

## Design

### 1. Where injection lives — the MAIN process
Inject in the main process (a new `RemoteControlInjector`), **not** the capture-helper:
`CGEvent` posting requires **Accessibility** (`AXIsProcessTrusted`), a per-bundle
process-level grant — the long-lived main process is the natural holder (the helper
is re-spawned per share, `HelperScreenCapture.start`). Injection has no `replayd`
coupling, so the helper-isolation rationale doesn't apply, and the grant state,
control listener, and viewer roster already live in the main process.

The helper stays a pure capture/encode pipe. Window-share geometry is resolved in the
main process via `CGWindowListCopyWindowInfo` — exactly as
`SharerOverlayWindow.cgWindowFrame` already does — so no new capture-helper wire
message is needed.

### 2. Grant flow (single grantee)
State added to `TailscaleScreenShareServer`:
- `controlGrant: OSAllocatedUnfairLock<ControlGrant?>` where
  `ControlGrant = (viewerID: String /* ip:port */, connectionID: UUID, grantedAt: Date)`.
- `pendingControlRequests: OSAllocatedUnfairLock<[String: Date]>` (viewer addr → arrival).

Flow:
1. Viewer clicks "Request Control" → `TailscaleScreenShareClient.requestControl()`
   sends `.controlRequest` over the TCP channel.
2. Server `installControlHandlers` gains `listener.onControlRequest = { op, connID in … }`.
   It maps `connectionID → viewer addr` (needs a small addition — see §6), records
   a pending request, fires `onControlRequestChanged` up to `AppState`.
3. `AppState` surfaces it in the SharingCard next to the pending-viewer UI
   (reuse `pendingViewers` presentation patterns, `MenuBarView`), and posts a
   `UNUserNotification` (`ViewerJoinNotifier` pattern in `ViewerApproval.swift:35-77`).
4. Sharer clicks **Grant** → `server.grantControl(toViewerID:)`. It sets
   `controlGrant`, clears the pending entry, sends `.controlGranted` to that
   viewer's connection, and `.controlRevoked` to any previously granted viewer.
   Only one grant may exist; granting a new viewer implicitly revokes the old.
5. **Revoke paths** all call `server.revokeControl(reason:)`:
   - Sharer menu item "Stop Remote Control" (`AppMenu`) + SharingCard button.
   - **Global hotkey** panic revoke via a second `GlobalHotkey` instance
     (e.g. `⌃⌥.`) — `GlobalHotkey.swift` supports one ID today; extend to a
     second registered id (its comment at `:50-54` notes the id-dispatch design).
   - Viewer disconnect: `onConnectionClosed` (`TailscreenControlListener.swift:43`,
     server `:700-718`) — if the closed `connectionID` matches the grant, revoke.
   - Viewer UDP `.bye` / idle sweep (`server :823-825`, `:1289-1355`) — revoke if
     the dropped addr holds the grant.
   - Share stop (`server.stop()` `:1613`) clears the grant.
6. Grant is pinned to the **allow-list identity** (prerequisite plan), not just
   `ip:port`; the `ip:port` and `connectionID` are the live routing handles but a
   grant never survives an identity change.

### 3. Event message schema
New `ScreenShareMessage` cases + `MessageType` bytes (extend
`ScreenShareProtocol.swift:28-31`; unknown types are already safely skipped by
`ScreenShareMessageParser.next()` `:79-82`, so old peers ignore new messages):
```
.controlRequest      = 0x05   payload: {} (or optional label)
.controlGranted      = 0x06   payload: {} (server→viewer)
.controlRevoked      = 0x07   payload: { reason: String }  (server→viewer)
.inputEvent          = 0x08   payload: JSON InputEvent      (viewer→sharer)
```
`InputEvent` (JSON, `Codable`, `Sendable`), coords normalized `[0,1]` top-left in
video space to match `Annotation` (`Annotation.swift:16-19`):
```swift
enum InputEvent: Codable, Sendable {
    case mouseMove(x: Double, y: Double)
    case mouseDown(x: Double, y: Double, button: MouseButton)
    case mouseUp(x: Double, y: Double, button: MouseButton)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)   // dx/dy in normalized/line units
    case keyDown(keyCode: UInt16, modifiers: UInt32)            // CGKeyCode + CGEventFlags raw
    case keyUp(keyCode: UInt16, modifiers: UInt32)
    enum MouseButton: String, Codable { case left, right }
}
```
Notes:
- Key events carry **CGKeyCode** (hardware virtual keycode) + a modifier bitmask
  mapped to `CGEventFlags`. The viewer captures via its window's `keyDown`/`flagsChanged`
  (`NSEvent.keyCode`, `NSEvent.modifierFlags`) — the same AppKit host that already
  does tool shortcuts (`AnnotationOverlayHostView.swift:51-74`). Keycode passthrough
  (not characters) keeps layout handling on the sharer's side.
- Scroll deltas are line-based; the injector converts to `CGEvent` scroll units.
- No timestamps on the wire — TCP already preserves order; the injector applies
  events as they arrive.

### 4. Coordinate mapping (normalized → global Quartz), per share kind
Injection needs to turn a normalized `[0,1]` video point into a **global display
coordinate** for `CGWarpMouseCursorPosition` / `CGEvent(mouseEventSource:…)`.
The sharer holds `currentSelection: PickerSelection` (`AppState.swift:487`).

- **`.display`**: capture region = the whole display. Resolve the display's
  Quartz bounds with `CGDisplayBounds(displayID)` (top-left origin, global). Global
  point `= bounds.origin + (nx*bounds.width, ny*bounds.height)`. `CGEvent` mouse
  coordinates are global top-left, so no Cocoa flip needed.
- **`.window`**: capture region = the window's current on-screen rect. Resolve
  with `CGWindowListCopyWindowInfo` filtered by `windowID` — **exactly**
  `SharerOverlayWindow.cgWindowFrame(for:)` (`SharerOverlayWindow.swift:308-319`),
  which returns Quartz top-left bounds. Global point maps into that live rect, so
  window drags/resizes are followed automatically (re-resolve per event, cheap).
  Guard: if the window isn't currently on-screen (returns nil), **drop** the event.
- **`.application`**: capture region is the whole display filtered to the app's
  windows (`CaptureHelperMain.buildFilter` `:172-187`, and
  `SharerOverlayWindow` treats app mode as full-display, `:96-99,277`). Map onto the
  display bounds like `.display`. The event lands wherever it lands on that
  display — acceptable and matches the annotation-overlay behavior already shipped.

Extract the mapping as a **pure function** for CI testing (no display hardware):
```swift
enum RemoteControlMapping {
    static func globalPoint(nx: Double, ny: Double, captureRect: CGRect) -> CGPoint
}
```
with the display/window rect fetched by a thin, side-effecting resolver the pure
function doesn't touch.

### 5. Injection + permission
New `RemoteControlInjector` (main process, serialized on one queue so ordering is
preserved):
- On first grant, check `AXIsProcessTrusted()`; if false call
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` and deep-link to
  Privacy → Accessibility (mirror `ScreenCapture.openScreenRecordingSettings` `:97-103`,
  pane `…?Privacy_Accessibility`), surfaced via `appState.showAlertMessage`. `CGEventPost`
  no-ops silently when untrusted — detect it up front and refuse the grant with a clear
  message rather than leave a dead grant.
- Apply: mouse via `CGEvent(mouseEventSource:…, mouseCursorPosition: global,…)` +
  `post(tap: .cghidEventTap)` (warp cursor first for moves); scroll via
  `CGEvent(scrollWheelEvent2Source:…)`; keys via `CGEvent(keyboardEventSource:…,
  virtualKey:, keyDown:)` with `.flags` from the modifier mask.

### 6. Rate limiting & coalescing
- **Server-side**: coalesce consecutive `.mouseMove` — keep only the latest per drain
  tick (~120 Hz cap) via a small bounded queue, exactly like the video send-chain drop
  policy (`TailscaleScreenShareServer.swift:1534-1566`). Hard per-viewer event-rate
  ceiling drops + logs excess (defense against a malicious granted viewer).
- **Viewer-side**: throttle `.mouseMove` emits to ~60–120 Hz (reuse the annotation drag
  throttle, `AnnotationCanvasModel.swift:52-54,108-114`); down/up/key/scroll never dropped.

### 7. Security posture
- **Server-side gate is authoritative.** The `.inputEvent` handler in
  `installControlHandlers` checks `controlGrant?.connectionID == connectionID` (plus
  allow-list identity) before touching the injector. Events from any other connection
  are dropped and counted — a non-granted viewer cannot inject even if it crafts frames.
- Grant is single-holder, auto-revoked on disconnect/idle/stop, instantly revocable by
  hotkey/menu. No injection while `sharingState != .active`.
- Viewer UI shows "You are controlling <host>"; sharer UI shows "<viewer> is controlling
  your Mac" with a prominent Stop button.
- The gate matches purely on `connectionID` (the listener already carries it in
  `onAnnotation`/`onConnectionClosed`), so no addr↔UUID map is needed for the gate —
  only for UI labeling, which can fall back to "the granted viewer".

### 8. Annotation-tool interaction (control vs draw mutually exclusive)
- Add a **Control** mode to the viewer toolbar as a distinct toggle, *not* a
  member of the `.selectOne` tool radio group (`ViewerToolbar.swift:161-221`) — it's
  a mode, not a shape tool.
- While control mode is active AND the grant is live:
  - The annotation overlay's `isInputEnabled` is forced **false**
    (`AnnotationCanvasModel.swift:36`, gate at `AnnotationOverlayHostView.swift:44`)
    so pointer/keys route to input capture instead of drawing.
  - The viewer window installs an input-capture responder (extend the existing
    AppKit host, `AnnotationOverlayHostView` / `AspectFitHostView`) that converts
    `mouseMoved/mouseDown/mouseUp/scrollWheel/keyDown/flagsChanged` into `InputEvent`s
    using the same `normalize(_:in:)` + aspect-fit rect the annotation path uses.
- Leaving control mode (or losing the grant) restores draw mode and re-enables
  the overlay. The two are strictly mutually exclusive in the UI.

## Implementation steps (ordered checklist)
1. **Protocol.** `ScreenShareProtocol.swift`: add `MessageType` bytes `0x05–0x08`,
   `ScreenShareMessage` cases, `encode()` arms, and parser `decode…` for
   `.controlRequest/.controlGranted/.controlRevoked/.inputEvent`. Add `InputEvent`
   `Codable` type (new file `Sources/RemoteControl.swift`).
2. **Listener callbacks.** `TailscreenControlListener.swift`: add
   `onControlRequest: ((UUID) -> Void)?`, `onInputEvent: ((InputEvent, UUID) -> Void)?`;
   extend `dispatch(_:connectionID:)` (`:161-168`).
3. **Pure mapping + decision.** New `Sources/RemoteControlMapping.swift`:
   `globalPoint(nx:ny:captureRect:)`; `Sources/RemoteControlPolicy.swift`:
   `shouldInject(grant:connectionID:) -> Bool`, mouse-move coalescer, rate-limit
   accounting (all pure/static for CI tests).
4. **Injector.** `Sources/RemoteControlInjector.swift`: Accessibility check/prompt,
   `apply(_ event: InputEvent, captureRect: CGRect)`, serialized posting.
5. **Server grant state.** `TailscaleScreenShareServer.swift`: `controlGrant`,
   `pendingControlRequests`, `grantControl(toViewerID:)`, `revokeControl(reason:)`,
   `onControlRequestChanged`/`onControlGrantChanged` callbacks; wire the listener
   `onControlRequest`/`onInputEvent` in `installControlHandlers` (`:681`); revoke
   hooks in `onConnectionClosed` (`:700`), `.bye`/idle sweep (`:823`,`:1289`), and
   `stop()` (`:1613`). Server resolves `captureRect` from cached `PickerSelection`.
6. **Viewer.** `TailscaleScreenShareClient.swift`: `requestControl()`, `sendInputEvent(_:)`
   (serialize via existing `ConnectionWriter` `:675-679`), handle `.controlGranted`/
   `.controlRevoked` in `receiveAnnotationLoop` (`:131-150`) → new callbacks
   `onControlGranted`/`onControlRevoked`.
7. **Viewer input capture UI.** Add Control toggle to `ViewerToolbar.swift`
   (outside the tool radio group) + `ViewerCommands` selector; input-capture
   responder in the AppKit host that emits `InputEvent`s using `aspectFitRect`
   (`AppState.swift:1957`) + `normalize` (`AnnotationCanvasView.swift:99`). Force
   `isInputEnabled=false` on the annotation model while controlling.
8. **Sharer UI + revoke.** SharingCard rows for control requests + "Stop Remote
   Control"; `AppMenu` item; second `GlobalHotkey` (`GlobalHotkey.swift`) for panic
   revoke; `AppState` pass-through to `server.grantControl`/`revokeControl`
   (mirror approve/deny at `:1807-1813`).
9. **Accessibility prompt UX.** Deep-link helper + alert (mirror
   `ScreenCapture.openScreenRecordingSettings` `:97-103`).
10. **Localization.** Route all new user-facing strings through `L(_:)` and add
    keys to `en.lproj/Localizable.strings` (CLAUDE.md Localization section;
    `LocalizationCatalogTests` enforces sync).

## Files to change / add
Change: `Sources/ScreenShareProtocol.swift`, `Sources/TailscreenControlListener.swift`,
`Sources/TailscaleScreenShareServer.swift`, `Sources/TailscaleScreenShareClient.swift`,
`Sources/ViewerToolbar.swift`, `Sources/ViewerCommands.swift`,
`Sources/AnnotationOverlayHostView.swift` (or `AspectFitHostView` in `AppState.swift`),
`Sources/AppState.swift`, `Sources/AppMenu.swift`, `Sources/MenuBarView.swift`,
`Sources/GlobalHotkey.swift`, `Sources/Resources/en.lproj/Localizable.strings`.
Add: `Sources/RemoteControl.swift` (InputEvent + message helpers),
`Sources/RemoteControlInjector.swift`, `Sources/RemoteControlMapping.swift`,
`Sources/RemoteControlPolicy.swift`.
Tests: `Tests/TailscreenTests/RemoteControlMappingTests.swift`,
`RemoteControlPolicyTests.swift`, `ScreenShareRemoteControlTests.swift`.

## Testing strategy
CI-able **pure-decision** tests (the CLAUDE.md pattern — no tsnet, no injection):
- `RemoteControlMappingTests`: `globalPoint(nx:ny:captureRect:)` for display/window
  rects incl. non-zero origins and multi-display offsets; boundary clamping `[0,1]`.
- `RemoteControlPolicyTests`: `shouldInject` gate (granted vs non-granted
  connectionID), single-grantee invariant (granting B revokes A), mouse-move
  coalescing keeps only the latest, rate-limit ceiling drops excess, revoke-on-close
  matches only when `connectionID` holds the grant.
- Protocol round-trip in `ScreenShareProtocolTests` (existing file): encode/parse
  every new `ScreenShareMessage` case incl. `InputEvent` JSON; assert old parser
  skips unknown types (already true, `ScreenShareProtocol.swift:79-82`).

Local-only E2E (mirrors `ScreenShareControlChannelTests`, tsnet + local headscale):
- `ScreenShareRemoteControlTests`: two nodes; viewer sends `.controlRequest` →
  server `onControlRequestChanged` fires; grant → viewer `onControlGranted`; viewer
  sends `.inputEvent` → server routes to a **test seam** (`onInputEventForTesting`,
  internal-not-private, matching `onPLIRecordedForTesting` `:299`) — assert the gate
  admits granted events and drops non-granted ones **without** actually calling
  `CGEventPost` (injection is stubbed under xctest; real posting is manual-only,
  like the picker-lifecycle opt-in test).
- Manual/opt-in: a `TAILSCREEN_RUN_REMOTE_CONTROL_INJECT_TEST=1` gate (à la
  `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST`) that actually posts one `CGEvent` locally.

## Risks & pitfalls (CLAUDE.md constraints)
- **Do NOT put injection in the capture-helper or main-process SCStream code** —
  injection is unrelated to capture; keep the helper a pure capture pipe (CLAUDE.md:
  "Don't add SCStream lifecycle to the main process", helper isolation is about
  `replayd`, not applicable here).
- **Accessibility ≠ Screen Recording.** Distinct TCC grant; `CGEventPost` no-ops
  silently when untrusted — must detect `AXIsProcessTrusted()` and refuse the grant
  with a clear message rather than a dead grant.
- **Security first.** The server-side grant gate is the only thing standing between
  a viewer and the sharer's keyboard/mouse — it must be checked on *every*
  `.inputEvent`, keyed on `connectionID` (+ allow-list identity), never trusting the
  client. Depends on `plans/viewer-consent-and-access-control.md`.
- **Port 7447 hardcoded** (CLAUDE.md) — no new ports; ride the existing TCP channel.
- **Swift 6 concurrency**: injector touches AppKit/CG on `@MainActor`; the listener
  callbacks fire off arbitrary tasks (`TailscreenControlListener` is
  `@unchecked Sendable`) — hop to the injector's isolation before posting events.
- **Window-share coordinate drift**: re-resolve `cgWindowFrame` per event; drop
  events when the window is off-screen (nil), mirroring the overlay's miss-debounce
  (`SharerOverlayWindow.swift:284-289`).
- **Grant survives NAT rebind?** No — pin to allow-list identity, not `ip:port`, or a
  rebinding peer could inherit a grant (same class of bug the audio SSRC check
  guards against, `TailscaleScreenShareServer.swift:867-882`).

## Estimated scope
**L** — ~900–1200 LOC. Protocol + policy/mapping/injector ~350; server grant state
+ revoke wiring ~200; viewer input-capture UI + client send ~300; sharer UI/menu/
hotkey ~200; tests ~250; localization + polish ~100. The pure-decision extraction
keeps most logic CI-testable; the risk concentration is the Accessibility prompt UX
and the viewer input-capture responder.
