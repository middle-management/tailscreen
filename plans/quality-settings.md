# Quality settings pane — promote hardcoded encoder/transport constants to user-configurable

> Status: shipped (macOS only). `QualitySettings` + `TransportTuning`/`EncoderTuning`
> landed, wired end to end, with a "Review fixes" round applied after code
> review (section below — where it contradicts the original design, it wins).

## Problem

Every quality/performance knob (encoder quality, bpp ceilings, fps, keyframe
interval, in-flight cap, transport timeouts) was a hardcoded literal spread
across encoder, server and client files — including a bug: the server
re-derived the encoder's bitrate formula with a **hardcoded 60.0 fps**, which
would have silently diverged the day the helper's fps became configurable.
Goal: expose bitrate ceiling / fps cap / codec preference behind a preset
picker, and centralize the rest as constants with no UI, with `.default`
reproducing prior behavior bit-for-bit.

## Key design decisions

- **Session-quality snapshot taken at share start, not read live.** A
  `sessionQuality` guards fps/codec choice against a mid-share Settings edit
  leaking into a crash-restart — but it's a `OSAllocatedUnfairLock`-guarded
  value, not a plain `let`, because the *bitrate ceiling* is meant to
  live-apply (including surviving a helper crash-restart), while fps/codec
  stay frozen until the next share. The server keeps the raw
  `anchoredBaselineBitrate` (unclamped `w×h×bpp×fps`) alongside the effective
  clamped baseline so raising/removing the ceiling mid-share can recompute
  without waiting for the next encoder reinit.
- **Ceiling delivered two ways**: fps/codec/quality via helper spawn-time env
  (`TAILSCREEN_FPS_CAP` etc., following the `TAILSCREEN_FORCE_H264`
  precedent — `Process.environment` *replaces* the child's env, so it must be
  seeded from the parent's first or auth/instance vars vanish); the bitrate
  ceiling via the existing `InType.setBitrate` wire message, reusing
  `applyAdaptiveBitrate`'s down-push bookkeeping (forced keyframe, hysteresis)
  rather than a hand-rolled push. A raised ceiling isn't pushed immediately —
  the adaptive sweep recovers toward it at its normal pace.
- **`forceH264` always overrides `codecPreference`** — codec fallback is a
  correctness mechanism (a peer that can't decode HEVC), not a preference,
  and must win regardless of what the user picked.
- **One bitrate formula.** `VideoEncoder.computeBitrate` (`w×h×bpp×fps`) is
  the single source; both the helper's ceiling clamp and the server's
  baseline anchor call it — no hand-rolled copies.
- **Preset is derived, not stored.** `preset` is computed as "the named
  preset whose knobs match exactly, else `.custom`" rather than a persisted
  label — a stored label could otherwise silently contradict its knobs.
  Presets differentiate on fps + ceiling + VT `encoderQuality` (not exposed
  as its own UI control): Low = 30fps/3Mbps/0.6, Balanced = 60fps/none/0.7
  (bit-identical to pre-settings default), High = 60fps/none/0.85.
  `CodecPreference.hevc` was dropped as behaviorally identical to `.auto`
  (both try HEVC first); a persisted `"hevc"` blob decodes as `.auto`.
- **Anchor stability fix (review).** The server used to reset the adaptive
  sweep's bitrate state on *every* parameter-set emit, and parameter sets
  re-emit on every IDR (~2s under PLI-driven keyframes) — wiping sweep state
  every keyframe. Fixed by anchoring only on a change to the actual anchor
  inputs (width/height/codec/fpsCap/ceiling), recorded per helper spawn.
- **Self-heal when current bitrate exceeds a newly-lowered baseline** — a race
  between a ceiling drop and an in-flight sweep apply could otherwise strand
  `currentBitrate` above baseline forever on a loss-free link; the decision
  function now clamps down immediately in that case, no hysteresis.
- **Debounced live push** — Settings originally saved+pushed per Stepper
  tick, forcing an IDR per tick; now debounced behind one ~500ms
  cancel-and-replace task.
- **Values that fail to parse fall back to defaults; values that parse but
  are out of range get `normalized()`-clamped** (fps snaps down to nearest of
  {15,30,60}; ceiling clamps to a Mbps-rounded range) — a deliberate
  distinction between garbage and merely-out-of-bounds input.

## Non-goals (kept)

No per-viewer settings (one global config); no UI for internal timeouts/
in-flight cap/keyframe interval; no wire-protocol additions (codec is
auto-detected from RTP PT, no negotiation needed); no `TailscaleKit` changes.

## Pointers

- Type + store: `Apps/macOS/Sources/QualitySettings.swift` (presets,
  `normalized()`, `helperEnvironment()`/`fromEnvironment(_:)`,
  `preferredVideoCodec(forceH264:)`, injectable-`UserDefaults` store).
- Constants: `Apps/macOS/Sources/TransportTuning.swift`,
  `EncoderTuning` in `VideoEncoder.swift`.
- Wiring: `AppState.swift` (`@Published qualitySettings`, debounced push),
  `TailscaleScreenShareServer.swift` (`sessionQuality`, `AnchorInputs`,
  `updateQualityCeiling`), `CaptureHelperMain.swift` /
  `HelperScreenCapture.swift` (env plumbing), `SettingsView.swift` (Quality
  section).
- Tests: `Tests/TailscreenTests/QualitySettingsTests.swift`,
  `AdaptiveBitrateTests` (clamp-down arm, ceiling-fed baseline).

## Risks still worth remembering

- `Process.environment` replaces, never merges — always seed from
  `ProcessInfo.processInfo.environment` first.
- Session-snapshot semantics only hold if the server/helper never reads
  `UserDefaults` directly mid-share — always go through the snapshot.
- Codec must be cached (`onParameterSets`) before the first baseline anchor
  reads it (`onEncoderResolution`), or an H.264 session's first anchor uses
  HEVC's bits-per-pixel by default — the dispatch order is a real ordering
  invariant, not incidental.
