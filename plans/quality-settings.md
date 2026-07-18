# Quality settings pane — promote hardcoded encoder/transport constants to user-configurable

> Status: implemented in this PR.

## Problem & motivation

Every quality/performance knob in Tailscreen is a hardcoded literal scattered across five files: encoder quality, bits-per-pixel ceilings, fps, keyframe interval, in-flight cap, rate-limit window, plus half a dozen transport timeouts. Users on constrained links (or sharing to many viewers) can't trade fidelity for bandwidth; users on LANs can't opt into maximum quality. Meanwhile the constants themselves are duplicated — the server re-derives the encoder's bitrate formula with a **hardcoded 60.0 fps** (`TailscaleScreenShareServer.swift:502`) that would silently diverge if the helper's fps ever changed. `SettingsView` explicitly says it has "room to grow" (`Sources/SettingsView.swift:10-11`). This plan introduces a persisted `QualitySettings` value type, exposes the three knobs worth exposing (bitrate ceiling, fps cap, codec preference, wrapped in a simple preset), and centralizes the rest into one constants type without UI.

## Goals / Non-goals

**Goals**
1. `QualitySettings` value type persisted in `UserDefaults`, whose static defaults reproduce today's behavior bit-for-bit.
2. Settings UI: preset picker (Low / Balanced / High / Custom) mapping onto fps cap (60/30/15), codec preference (Auto/HEVC/H.264), and a max-bitrate ceiling.
3. Deliver settings to the capture-helper at spawn time (env, following the `TAILSCREEN_FORCE_H264` precedent) + live bitrate-ceiling changes over the existing `setBitrate` wire message.
4. Centralize internal-only timeouts/tuning into a `TransportTuning` constants enum (no UI).
5. Defined mid-share semantics: bitrate ceiling live-applies; fps/codec apply on next share (settings snapshot per share).
6. All new user-facing strings via `L(...)` + `en.lproj` catalog.

**Non-goals**
- No per-viewer or per-peer settings; one global config.
- No UI for timeouts, in-flight cap, keyframe interval, VT quality, DataRateLimits shape — centralized but internal.
- No wire-protocol additions (reuse `InType.setBitrate`; no settings negotiation with viewers — the viewer auto-detects codec from RTP payload type already).
- No changes under `TailscaleKit/`.

## Current state (with file:line references)

**Encoder constants** (`Sources/VideoEncoder.swift`):
- VT quality `0.7` (:183); bits-per-pixel ceiling `0.08` HEVC / `0.10` H.264 (`defaultBitsPerPixel`, :110-115); `maxInFlight = 2` (:56); keyframe-interval safety net `fps * 10` (:194-195); `DataRateLimits` = 1.75× per-second budget over a 0.5 s window (`applyBitrate`, :220-226); bitrate formula `w*h*bpp*fps` (`computeBitrate`, :209-211). `setBitrate(_:)` (:233-239) already live-updates the ceiling. `setup(width:height:fps:preferredCodec:bitsPerPixel:)` (:79-103) already parameterizes fps/codec/bpp — callers just never pass anything but defaults.

**fps pinned to 60** in two places that must stay in lockstep: `SCStreamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 60)` (`Sources/ScreenCapture.swift:235`) and `newEncoder.setup(width:height:fps: 60, …)` in the helper (`Sources/CaptureHelperMain.swift:387`). The helper already reads `TAILSCREEN_FORCE_H264` from env (:384-386) — set by `HelperScreenCapture.start(filterData:forceH264:)`, which seeds child env from the parent's (`Sources/HelperScreenCapture.swift:79-87`, with an explicit comment that `environment` replaces rather than merges).

**Server transport constants** (`Sources/TailscaleScreenShareServer.swift`): `pendingApprovalTimeoutNs` 60 s (:141), `maxQueuedVideoFramesPerViewer` 4 (:175), `viewerIdleTimeoutNs` 15 s (:196), `helperLivenessTimeoutNs` 15 s (:258), adaptive-bitrate floor `max(baseline * 3/10, 500_000)` duplicated at :1383 and :1435, sweep window/hysteresis/loss threshold (:1370-1373, defaulted again at :1431-1432), baseline anchor `w*h*bpp*60.0` (:494-509 — the hardcoded `60.0` at :502). Crash budget 3-in-30 s (:459, :469).

**Client**: idle disconnect 15 s (`Sources/TailscaleScreenShareClient.swift:396`), deliberately matched to the server's 15 s sweep (comment :391-395); keepalive cadence 500 ms (:560-565); PLI min interval 100 ms (:577).

**Wire** (`Sources/CaptureHelperWire.swift`): `InType.setBitrate = 0x02` carrying `[4 bytes bitrate BE]` (:63-64), sent via `HelperControlWriter.sendBitrate` (:222-226), received in the helper's stdin reader (`CaptureHelperMain.swift:100-102`) → `runner.setBitrate` → `encoder?.setBitrate` (:339-342). `InType.contentFilter` payload is bare JSON `PickerSelection` (:65-72) — extending it would be a schema change; env is cleaner.

**Settings UI & persistence pattern**: `SettingsView` is a grouped `Form` with Viewers/Audio/About sections (`Sources/SettingsView.swift:21-62`, fixed frame 440×380 :65). The persistence precedent is `ViewerApprovalDefaults` (`Sources/ViewerApproval.swift:9-19`) + a `@Published` property with `didSet` save-and-push (`Sources/AppState.swift:92-95`).

**Restart path**: helper respawns reuse cached `lastFilterData` (`TailscaleScreenShareServer.swift:207`, `startHelperCapture` :476-588, `scheduleHelperRestart` :641-674) — whatever carries settings must survive respawn identically.

## Design

### `QualitySettings` value type + store

```swift
// Sources/QualitySettings.swift
struct QualitySettings: Codable, Equatable, Sendable {
    enum CodecPreference: String, Codable, CaseIterable { case auto, hevc, h264 }
    enum Preset: String, Codable, CaseIterable { case low, balanced, high, custom }
    var preset: Preset = .balanced
    var fpsCap: Int = 60                      // allowed: 15 / 30 / 60
    var codecPreference: CodecPreference = .auto
    var maxBitrateBps: Int? = nil             // nil = automatic (bpp formula); else clamp of the computed ceiling
    static let `default` = QualitySettings()
    func normalized() -> QualitySettings      // pure: clamp fpsCap to {15,30,60}, maxBitrateBps to 500 kbps…50 Mbps
    static func applying(preset: Preset, to base: QualitySettings) -> QualitySettings  // pure preset mapping
    func helperEnvironment() -> [String: String]  // pure: TAILSCREEN_FPS_CAP / TAILSCREEN_CODEC_PREF / TAILSCREEN_MAX_BITRATE
    static func fromEnvironment(_ env: [String: String]) -> QualitySettings  // pure inverse, used inside the helper
}
enum QualitySettingsStore {   // mirrors ViewerApprovalDefaults (ViewerApproval.swift:9-19)
    static let key = "qualitySettings"        // JSON-encoded blob; absent → .default
    static func load() -> QualitySettings
    static func save(_ s: QualitySettings)
}
```

Preset mapping (pure, testable): **low** = fps 15, codec auto, ceiling 2 Mbps; **balanced** = fps 60, auto, ceiling nil (today's exact behavior); **high** = fps 60, prefer HEVC, ceiling nil. Editing any knob directly flips `preset` to `.custom`. `default` == `balanced` — a fresh install behaves identically to today (pin with a test).

### Internal constants centralization

New `Sources/TransportTuning.swift` (`enum TransportTuning`) holding: `viewerIdleTimeoutNs`, `pendingApprovalTimeoutNs`, `helperLivenessTimeoutNs`, `clientIdleDisconnectNs`, `keepaliveIntervalNs`, `maxQueuedVideoFramesPerViewer`, `adaptiveFloorFraction` (3/10), `adaptiveFloorMinBps` (500_000), `helperCrashWindowNs`, `maxHelperCrashesPerWindow`. Server/client literals become references. **Invariant to preserve in one place**: `clientIdleDisconnectNs == viewerIdleTimeoutNs` (the coupling documented at `TailscaleScreenShareClient.swift:391-395` and `TailscaleScreenShareServer.swift:186-196`) — assert it in a unit test. Similarly `EncoderTuning` (can live in `VideoEncoder.swift`): `quality = 0.7`, `maxInFlight = 2`, `keyframeIntervalMultiplier = 10`, `dataRateBurstFactor = 1.75`, `dataRateWindowSeconds = 0.5`, plus the existing `defaultBitsPerPixel` (:110-115) untouched. Pure moves, zero behavior change.

### Reaching the helper

- **Spawn-time (fps, codec, ceiling)**: `HelperScreenCapture.start` gains a `qualityEnv: [String: String]` parameter merged into the child env exactly like `TAILSCREEN_FORCE_H264` (:79-87 — seed from `ProcessInfo`, then overlay; `forceH264` still wins over `TAILSCREEN_CODEC_PREF` since codec fallback is a correctness mechanism). In the helper: `CaptureHelperRunner.handleFrame` (`CaptureHelperMain.swift:377-416`) reads `QualitySettings.fromEnvironment` once, passes `fps: settings.fpsCap` and `preferredCodec` into `newEncoder.setup` (:387) and clamps the computed bitrate via `bitsPerPixel` → after setup, if `maxBitrateBps` set, call `newEncoder.setBitrate(min(computed, max))`. `ScreenCapture.startStream` gets an `fps` parameter for `minimumFrameInterval` (`ScreenCapture.swift:235`), threaded from the runner.
- **Live (ceiling only)**: the server's adaptive sweep already pushes ceilings via `helperCapture?.setBitrate` (`TailscaleScreenShareServer.swift:1455`) over `InType.setBitrate` (`CaptureHelperWire.swift:63-64`). Add `func updateQualityCeiling(_ bps: Int?)` on the server: recompute `baselineBitrate = min(anchoredBaseline, userCeiling)` and push `currentBitrate` if it now exceeds the new baseline. The baseline anchor at :494-509 changes to `Int(Double(w*h) * bpp * Double(fpsCap))` clamped by the ceiling — fixing the hardcoded `60.0` divergence at :502 in the same stroke.

### Share-session snapshot & mid-share semantics

`TailscaleScreenShareServer` captures a `let sessionQuality: QualitySettings` at `start()` (passed in by AppState alongside `filterData`, :320-328) and reuses it for **every** helper respawn (`startHelperCapture` :476, `scheduleHelperRestart` :641) — so a crash-restart mid-share can't silently pick up different settings. Semantics:
- **Max bitrate**: live-applies (Settings `didSet` → `server?.updateQualityCeiling(...)`), no restart.
- **fps cap / codec preference**: apply on the next share. The Settings pane shows a caption `L("Frame rate and codec changes apply the next time you start sharing.")`. (Live-apply via `restartCapture()` is technically available (:609-614) but deliberately out of scope: a respawn blanks video for ~1 s per toggle and burns nothing for a setting users rarely flip mid-share.)
- Viewer side needs nothing: codec is auto-detected from RTP PT 96/97, and fps is encoder-driven.

### Settings UI

New `Section(L("Quality"))` in `SettingsView` between Viewers and Audio (:30-32), bound to a new `@Published var qualitySettings: QualitySettings` on AppState (pattern of `requireViewerApproval`, `AppState.swift:92-95`: `didSet { QualitySettingsStore.save(...); server?.updateQualityCeiling(...) }`):
- `Picker(L("Preset"))` — segmented: `L("Low")` / `L("Balanced")` / `L("High")` / `L("Custom")`.
- `Picker(L("Frame rate"))` — `60 fps` / `30 fps` / `15 fps` (values, not localized keys, except via `L("\(fps) fps")` → `%lld fps`).
- `Picker(L("Codec"))` — `L("Automatic")` / "HEVC" / "H.264" (brand-ish codec names unlocalized per CLAUDE.md's brand-noun rule; "Automatic" localized).
- `Toggle(L("Limit bandwidth"))` + `Slider`/`Stepper` for Mbps shown as `L("\(mbps) Mbps")`; disabled state = automatic.
- Caption rows via the existing `.font(.caption).foregroundStyle(.secondary)` idiom (:25-29). Window height 380 → ~520 (:65).

## Implementation steps

1. [ ] New `Sources/QualitySettings.swift`: struct, presets, `normalized()`, `helperEnvironment()`/`fromEnvironment(_:)`, `QualitySettingsStore` (pattern `ViewerApproval.swift:9-19`).
2. [ ] New `Sources/TransportTuning.swift`; replace literals at `TailscaleScreenShareServer.swift:141/:175/:196/:258/:1383/:1435` and `TailscaleScreenShareClient.swift:396/:565`; add `EncoderTuning` constants in `VideoEncoder.swift` for :56/:183/:194-195/:222-223. Pure refactor commit — no behavior change.
3. [ ] `Sources/VideoEncoder.swift`: no API change needed (`setup` already takes fps/codec/bpp, :79-85).
4. [ ] `Sources/ScreenCapture.swift`: add `fps` parameter to `start(filter:)`/`startStream` (:226-249), used at :235 and in the log line :248.
5. [ ] `Sources/CaptureHelperMain.swift`: read `QualitySettings.fromEnvironment` in `CaptureHelperRunner`; thread fps into `captureWrapper.start` and `newEncoder.setup` (:387); apply ceiling clamp after setup; keep `TAILSCREEN_FORCE_H264` (:384-386) overriding codec preference.
6. [ ] `Sources/HelperScreenCapture.swift`: `start(filterData:forceH264:qualityEnv:)` merging env (:79-87).
7. [ ] `Sources/TailscaleScreenShareServer.swift`: accept `quality: QualitySettings` in `start()` (:320); store as session snapshot; pass env in `startHelperCapture` (:585); fix baseline anchor (:502) to use `fpsCap` + ceiling clamp; add `updateQualityCeiling(_:)`.
8. [ ] `Sources/AppState.swift`: `@Published qualitySettings` with `didSet` persist + live push (pattern :92-95); pass snapshot into `server.start(...)` at the share-start call site (~:507 onward).
9. [ ] `Sources/SettingsView.swift`: Quality section (:30), frame bump (:65).
10. [ ] `Sources/Resources/en.lproj/Localizable.strings`: all new keys byte-for-byte (incl. `%lld fps`, `%@ Mbps` interpolated forms).
11. [ ] Tests (below); update CLAUDE.md pure-decision list + the "port 7447"-style pitfalls if constants move.

## Files to change / add

| File | Change |
|---|---|
| `Sources/QualitySettings.swift` (new) | value type, presets, env mapping, store |
| `Sources/TransportTuning.swift` (new) | internal timeout/tuning constants |
| `Sources/VideoEncoder.swift` | `EncoderTuning` constants (refactor only) |
| `Sources/ScreenCapture.swift` | fps parameter |
| `Sources/CaptureHelperMain.swift` | env → encoder/SCStream config |
| `Sources/HelperScreenCapture.swift` | qualityEnv spawn plumbing |
| `Sources/TailscaleScreenShareServer.swift` | session snapshot, baseline fix, `updateQualityCeiling` |
| `Sources/TailscaleScreenShareClient.swift` | constants refactor only |
| `Sources/AppState.swift` | published setting + wiring |
| `Sources/SettingsView.swift` | Quality section |
| `Sources/Resources/en.lproj/Localizable.strings` | new keys |
| `Tests/TailscreenTests/QualitySettingsTests.swift` (new) | see below |

## Testing strategy

**CI-able pure/unit tests** (no tsnet, no SCK — per CLAUDE.md):
- `QualitySettingsTests`:
  - **Defaults pin today's literals**: `.default` → fps 60, codec auto, ceiling nil; `EncoderTuning.quality == 0.7`, `defaultBitsPerPixel(.hevc) == 0.08` / `(.h264) == 0.10`, `maxInFlight == 2`, keyframe multiplier 10; `TransportTuning` values equal the old literals; `clientIdleDisconnectNs == viewerIdleTimeoutNs` invariant.
  - `normalized()` clamping (fps 45 → 30? define: snap down to nearest allowed; ceiling bounds).
  - Preset round-trips: `applying(preset:)` idempotent; editing a knob ⇒ `.custom`.
  - `helperEnvironment()` ↔ `fromEnvironment()` round-trip, including absent-vars → `.default` and garbage values → `.default` fields.
  - Store round-trip through a scratch `UserDefaults(suiteName:)`; missing key → `.default`.
- Extend `AdaptiveBitrateTests`: baseline computed with fps 30 and a 2 Mbps ceiling feeds `nextAdaptiveBitrate` correctly (floor derives from clamped baseline).
- `LocalizationCatalogTests` enforces the new keys automatically.
- Existing `CaptureHelperWireTests` already cover `sendBitrate` framing — unchanged.

**Local E2E** (local-only per CLAUDE.md — CI can't grant TCC or run tsnet):
- `ScreenShareCaptureHelperTests` variant: spawn the real helper with `TAILSCREEN_FPS_CAP=30 TAILSCREEN_CODEC_PREF=h264` (via the existing `TAILSCREEN_HELPER_EXE` seam) and assert the helper's log line `"capture-helper: encoder h264 …@30fps"` (:389) plus H.264 payload type at the viewer.
- `ScreenShareSyntheticFramesTests` unaffected (server `filterData: nil` mode skips the helper).
- Manual: `./test-local.sh 2` with Settings ceiling 1 Mbps → stats overlay bitrate stays ≤ ~1 Mbps; flip ceiling mid-share and watch the live change; verify a helper crash-restart keeps the same fps (session snapshot).

## Risks & pitfalls

- **`Process.environment` replaces, doesn't merge** — the existing comment at `HelperScreenCapture.swift:80-86` is the trap; always seed from `ProcessInfo.processInfo.environment`. Losing `TAILSCREEN_INSTANCE`/auth vars breaks multi-instance and E2E.
- **Baseline/fps coherence**: the server-side anchor (:502) and the helper's encoder fps must come from the same snapshot, or the adaptive sweep's ceiling is wrong by fps-ratio. The session-snapshot design exists precisely for this; don't read `UserDefaults` inside the server or helper-respawn paths.
- **Respawn consistency**: `scheduleHelperRestart` (:641-674) must reuse the snapshot env — a mid-share settings edit must not leak into a crash-restart (stuck-badge machinery notes at :616-640 mean this path is delicate; do not reorder its isRunning checks).
- **`forceH264` precedence**: codec fallback (`forceH264` latch, :227, :585) must override `codecPreference == .hevc`, or a viewer that can't decode HEVC re-black-screens after respawn.
- **Don't touch capture from the main process** (CLAUDE.md): all SCStream/encoder config stays in the helper; the main process only sets env + wire messages.
- **UserDefaults key stability**: version the JSON via `Codable` optional fields with defaults (decode-with-fallback), so an older blob never crashes settings load.
- **Localization**: interpolated keys must land in the catalog in `%lld`/`%@` form or `LocalizationCatalogTests` fails; codec names / "fps" unit treated per the brand-noun/glyph rule.
- **Linker/package rules**: no `Package.swift` changes needed; keep the relative `-L Packages/TailscaleKit/lib` untouched.

## Estimated scope

**M** — ~500-600 LOC: ~140 `QualitySettings` + store + env mapping, ~60 `TransportTuning`/`EncoderTuning` refactor, ~80 helper/spawn plumbing, ~40 server snapshot + ceiling, ~90 SettingsView + AppState, ~40 strings, ~150 tests. Two-commit structure recommended: (1) pure constants centralization (zero behavior change), (2) settings type + UI + plumbing.

## Deviations

The plan was written against an older `main`; three PRs (viewer zoom/pan, voice resilience, and assorted server/client work) landed since, so every `file:line` reference above has drifted — the implementation trusted symbol names over line numbers. Substantive deviations from the letter of the plan:

- **Session snapshot is a lock, and the live ceiling is folded into it.** `sessionQuality` is an `OSAllocatedUnfairLock<QualitySettings>` (not a plain `let`) because `updateQualityCeiling` mutates its `maxBitrateBps` mid-share: the ceiling live-applies, so a helper *crash-restart* respawns with the ceiling the user last set (fps/codec remain frozen at share start, exactly as planned). A plain immutable snapshot would have respawned the helper with a stale ceiling after a mid-share Settings edit.
- **Raw anchor stored separately.** The server keeps `anchoredBaselineBitrate` (the un-clamped `w×h×bpp×fpsCap` formula value) alongside the effective `baselineBitrate = min(anchor, ceiling)`, so *raising or removing* the ceiling mid-share can recompute the baseline without waiting for the next encoder reinit. The plan's sketch only described the min(); it needs the raw anchor retained to be reversible.
- **`updateQualityCeiling` reuses `applyAdaptiveBitrate`** for the down-push (same bookkeeping + forced keyframe as an adaptive down-step) instead of hand-rolling the `setBitrate` push. A raised ceiling is not pushed immediately — the adaptive sweep recovers toward the new baseline at its usual +10 %/clean-window pace.
- **`fromEnvironment` semantics**: unparseable values (garbage) leave the field at its default, as planned; values that parse but are out of range are `normalized()` (fps snaps *down* to the nearest of {15, 30, 60}; ceiling clamps to 500 kbps…50 Mbps) rather than discarded.
- **The dead `floor` local** in `adaptiveBitrateSweep` (leftover from the `nextAdaptiveBitrate` extraction, one of the two duplicated floor sites the plan flagged) was deleted rather than centralized; the surviving site inside `nextAdaptiveBitrate` uses `TransportTuning.adaptiveBitrateFloor(baseline:)`.
- **`sv.lproj` updated too.** The plan predates the Swedish catalog; per the repo's Localization rule, all new keys were added byte-for-byte to both `en.lproj` and `sv.lproj` (values translated). `"Codec"` already existed in both catalogs and was not duplicated.
- **Naming**: the ceiling bounds live on `QualitySettings` as `minCeilingBps` / `maxCeilingBps` (a static named `maxBitrateBps` would collide with the instance property), plus `initialCeilingBps` (10 Mbps) installed when the user first enables "Limit bandwidth". `QualitySettings` also grew `preferredVideoCodec(forceH264:)` — the pure codec-resolution decision the helper uses, unit-tested for the forceH264-wins invariant.
- **Store API** takes an injectable `UserDefaults` (`load(from:)` / `save(_:to:)`, defaulting to `.standard`) so the persistence round-trip is testable against a scratch suite, per the testing strategy.
- **`ScreenCapture.start(filter:fps:)`** defaults `fps` to 60 so the picker-helper-side and any legacy callers are untouched; the capture-helper is the only caller that passes a non-default value.

### Review fixes

Applied after code review of the implementation above; where these contradict earlier sections, this section wins.

1. **Anchor stability.** The server's `onEncoderResolution` handler used to reset `currentBitrate`/`lastBitrateChangeNs` on *every* parameter-sets emit — and parameter sets re-emit on every IDR (~2 s under PLI-driven keyframes), so the adaptive sweep's state was wiped each keyframe and cuts/recovery never survived a hysteresis window. The anchor inputs (width, height, codec, fpsCap, effective ceiling) are now recorded per anchor (`AnchorInputs` + `lastAnchorInputs`) and a same-inputs emit is a no-op. The record is cleared per helper spawn (a fresh helper's encoder restarts at the formula/ceiling bitrate, so it must re-anchor), and `updateQualityCeiling` folds a live ceiling edit into it so the next IDR doesn't re-anchor over the push it already applied.
2. **Self-heal `current > baseline`.** A mid-share ceiling drop can race an in-flight sweep apply and leave `currentBitrate` above the new baseline forever on a loss-free link (the raise arm requires `current < baseline`). `nextAdaptiveBitrate` now has a clamp-down arm: `current > baseline` returns `baseline` immediately, no hysteresis. Pinned in `AdaptiveBitrateTests`.
3. **First-anchor codec ordering.** `HelperScreenCapture`'s `.parameterSets` dispatch now fires `onParameterSets` (which caches `helperCodec`) *before* `onEncoderResolution` (which reads it), so the session's first baseline anchor uses the real codec's bits-per-pixel instead of defaulting to HEVC's on an H.264 session. The ordering invariant is commented at the dispatch site.
4. **Ceiling bounds coherence.** `minCeilingBps` is now 1 Mbps — a UX floor for the whole-Mbps stepper, decoupled from `TransportTuning.adaptiveFloorMinBps` (the old equality pin is replaced by a `>=` assertion). `normalized()` also rounds a non-nil ceiling to a whole Mbps (`normalizedCeiling`), the Settings stepper derives its range from `minCeilingBps/maxCeilingBps` instead of a hardcoded `1...50`, the `max(1, …)` display fudge is gone, and `updateQualityCeiling` clamps via the same `normalizedCeiling` path instead of an inline min/max.
5. **Debounced live push.** `AppState.qualitySettings.didSet` used to save + push the ceiling per Stepper tick; each down-push forces an IDR, so stepping 10 → 3 Mbps burst seven keyframes. Save + push are now debounced behind one ~500 ms cancel-and-replace MainActor task.
6. **Real presets, no dead codec case.** `CodecPreference.hevc` was behaviorally identical to `.auto` (both try HEVC first) and is removed — the picker offers Automatic / H.264, and a persisted `"hevc"` blob decodes as `.auto`. Presets now differentiate on a real knob: `encoderQuality` (VT's `Quality` property, delivered via `TAILSCREEN_ENCODER_QUALITY`, clamped to 0.3…1.0, not exposed as its own UI knob). **Low** = 30 fps + 3 Mbps ceiling + 0.6; **Balanced** = 60 fps + no ceiling + 0.7 (bit-identical to the pre-settings default); **High** = 60 fps + no ceiling + 0.85.
7. **Preset is derived, not stored.** `preset` is a computed label: the named preset whose fixed knob combination matches exactly, else `.custom`. The `updating(…)` helpers no longer flip a stored label, persisted blobs no longer carry one (ignored on decode), and the label can never contradict the knobs.
8. **One bitrate formula.** `VideoEncoder.computeBitrate` is internal and is the single source for `w×h×bpp×fps` — the helper's user-ceiling clamp and the server's baseline anchor call it instead of hand-rolling copies.
9. **`decodeField` simplified.** The generic decode-with-fallback helper (whose `decoded ?? fallback` right side was dead) is replaced by per-field `(try? container.decode(…)) ?? default` one-liners.
