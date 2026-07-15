import Foundation

/// User-facing quality knobs for the sharing side — frame-rate cap, codec
/// preference, encoder quality, and an optional bandwidth ceiling. The
/// named preset is *derived* from the knobs (a computed label, never
/// stored), so the Settings picker can't contradict the knob values.
/// Persisted as a JSON blob in `UserDefaults` (see `QualitySettingsStore`)
/// and delivered to the capture-helper subprocess as environment variables
/// at spawn time (`helperEnvironment()` / `fromEnvironment(_:)`),
/// following the `TAILSCREEN_FORCE_H264` precedent — the helper owns the
/// SCStream + VideoToolbox pipeline, so the main process never touches
/// encoder state directly.
///
/// Mid-share semantics: the bandwidth ceiling live-applies over the
/// existing `setBitrate` wire message
/// (`TailscaleScreenShareServer.updateQualityCeiling`); fps cap, codec
/// preference, and encoder quality are snapshotted per share session and
/// apply the next time sharing starts.
///
/// `default` reproduces the pre-settings behavior bit-for-bit: 60 fps,
/// automatic codec (HEVC with H.264 fallback), 0.7 encoder quality, no
/// ceiling beyond the encoder's bits-per-pixel formula. Pinned by
/// `QualitySettingsTests`.
struct QualitySettings: Codable, Equatable, Sendable {
    /// Which codec the helper's encoder should prefer. `.auto` tries HEVC
    /// first and falls back to H.264 when VideoToolbox refuses; `.h264`
    /// skips HEVC entirely. A viewer-reported decode failure
    /// (`TAILSCREEN_FORCE_H264`) overrides both — codec fallback is a
    /// correctness mechanism, not a preference. There is deliberately no
    /// `.hevc` case: it would behave identically to `.auto` (both try
    /// HEVC first); a persisted `"hevc"` blob from an older build decodes
    /// as `.auto`.
    enum CodecPreference: String, CaseIterable, Codable, Sendable {
        case auto
        case h264
    }

    /// Named knob combinations the Settings UI offers. Derived from the
    /// knobs via the computed `preset` property — never stored, so the
    /// label can't drift out of sync with the values it names.
    enum Preset: String, CaseIterable, Sendable {
        case low
        case balanced
        case high
        case custom
    }

    /// Frame-rate caps the UI offers, ascending. `normalized()` snaps any
    /// other value down to the nearest member.
    static let allowedFPSCaps = [15, 30, 60]

    /// Bounds for the user bandwidth ceiling. The 1 Mbps lower bound is a
    /// UX floor (the Settings stepper works in whole Mbps); it is
    /// deliberately decoupled from the adaptive sweep's absolute floor
    /// (`TransportTuning.adaptiveFloorMinBps`) but must never sit below
    /// it — asserted in `QualitySettingsTests`.
    static let minCeilingBps = 1_000_000
    static let maxCeilingBps = 50_000_000

    /// Ceiling installed when the user first flips "Limit bandwidth" on.
    static let initialCeilingBps = 10_000_000

    /// Bounds for `encoderQuality` (`kVTCompressionPropertyKey_Quality`).
    /// Below 0.3 VideoToolbox output degrades into blocky unusability;
    /// 1.0 is the property's own maximum.
    static let minEncoderQuality = 0.3
    static let maxEncoderQuality = 1.0

    var fpsCap: Int
    var codecPreference: CodecPreference
    /// `nil` = automatic — the encoder's bits-per-pixel formula alone
    /// bounds the bitrate. Non-nil clamps that computed ceiling.
    var maxBitrateBps: Int?
    /// Perceptual-quality target handed to the encoder
    /// (`kVTCompressionPropertyKey_Quality`). Rate control runs primarily
    /// off this; the bitrate ceiling only bounds the peaks. Not exposed as
    /// its own UI knob — the presets differentiate on it.
    var encoderQuality: Double

    static let `default` = QualitySettings()

    init(
        fpsCap: Int = 60,
        codecPreference: CodecPreference = .auto,
        maxBitrateBps: Int? = nil,
        encoderQuality: Double = EncoderTuning.quality
    ) {
        self.fpsCap = fpsCap
        self.codecPreference = codecPreference
        self.maxBitrateBps = maxBitrateBps
        self.encoderQuality = encoderQuality
    }

    // MARK: - Codable (decode-with-fallback)

    private enum CodingKeys: String, CodingKey {
        case fpsCap
        case codecPreference
        case maxBitrateBps
        case encoderQuality
    }

    /// Decode-with-fallback so an older (or newer) persisted blob never
    /// fails settings load: every missing or unparseable field degrades to
    /// its default instead of throwing. An old blob's stored `"preset"`
    /// key is simply ignored (the preset is derived from the knobs now),
    /// and a legacy `"hevc"` codec preference decodes as `.auto`.
    /// `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fpsCap = (try? container.decode(Int.self, forKey: .fpsCap)) ?? 60
        codecPreference = (try? container.decode(CodecPreference.self, forKey: .codecPreference)) ?? .auto
        maxBitrateBps = try? container.decode(Int.self, forKey: .maxBitrateBps)
        encoderQuality = (try? container.decode(Double.self, forKey: .encoderQuality)) ?? EncoderTuning.quality
    }

    // MARK: - Normalization

    /// Pure clamp: snap `fpsCap` down to the nearest allowed value (values
    /// below the smallest snap up to it), clamp `encoderQuality` to
    /// `minEncoderQuality…maxEncoderQuality`, and clamp + whole-Mbps-round
    /// a non-nil ceiling via `normalizedCeiling`. Idempotent.
    func normalized() -> QualitySettings {
        var out = self
        out.fpsCap = Self.allowedFPSCaps.last { $0 <= fpsCap } ?? Self.allowedFPSCaps[0]
        out.encoderQuality = min(max(encoderQuality, Self.minEncoderQuality), Self.maxEncoderQuality)
        out.maxBitrateBps = Self.normalizedCeiling(maxBitrateBps)
        return out
    }

    /// Clamp a user bandwidth ceiling to `minCeilingBps…maxCeilingBps` and
    /// round it to a whole Mbps — the Settings stepper works in integer
    /// Mbps, so keeping the stored value on the same grid means the
    /// display needs no fudging. `nil` (automatic) passes through. Shared
    /// with `TailscaleScreenShareServer.updateQualityCeiling` so the
    /// live-apply path clamps exactly like persistence does.
    static func normalizedCeiling(_ bps: Int?) -> Int? {
        guard let bps else { return nil }
        let clamped = min(max(bps, minCeilingBps), maxCeilingBps)
        return (clamped + 500_000) / 1_000_000 * 1_000_000
    }

    // MARK: - Presets

    /// The fixed knob combinations behind the named presets. `balanced`
    /// is exactly the pre-settings default behavior (pinned by tests);
    /// `low` trades frame rate, ceiling, and encoder quality for
    /// bandwidth; `high` spends encoder quality for fidelity.
    private static let presetCombos: [Preset: QualitySettings] = [
        .low: QualitySettings(fpsCap: 30, codecPreference: .auto, maxBitrateBps: 3_000_000, encoderQuality: 0.6),
        .balanced: QualitySettings(fpsCap: 60, codecPreference: .auto, maxBitrateBps: nil, encoderQuality: 0.7),
        .high: QualitySettings(fpsCap: 60, codecPreference: .auto, maxBitrateBps: nil, encoderQuality: 0.85)
    ]

    /// Derived preset label: the named preset whose fixed knob combination
    /// matches this value exactly, else `.custom`. Computed (not stored)
    /// so the label can never contradict the knobs.
    var preset: Preset {
        Self.presetCombos.first { $0.value == self }?.key ?? .custom
    }

    /// Pure preset → knob mapping. `custom` returns `base` unchanged (it
    /// names "any other combination", not a combination of its own).
    /// Idempotent for every preset.
    static func applying(preset: Preset, to base: QualitySettings) -> QualitySettings {
        presetCombos[preset] ?? base
    }

    /// Set one knob directly. The derived `preset` re-labels itself:
    /// `.custom` unless the result happens to match a named combination.
    func updating(fpsCap: Int) -> QualitySettings {
        var out = self
        out.fpsCap = fpsCap
        return out.normalized()
    }

    func updating(codecPreference: CodecPreference) -> QualitySettings {
        var out = self
        out.codecPreference = codecPreference
        return out.normalized()
    }

    func updating(maxBitrateBps: Int?) -> QualitySettings {
        var out = self
        out.maxBitrateBps = maxBitrateBps
        return out.normalized()
    }

    // MARK: - Codec resolution

    /// Codec the helper's encoder should try first. `forceH264` is the
    /// viewer-reported decode-failure latch (`TAILSCREEN_FORCE_H264`) and
    /// wins over every preference, or a viewer that can't decode HEVC
    /// would re-black-screen after a helper respawn.
    func preferredVideoCodec(forceH264: Bool) -> VideoCodec {
        if forceH264 { return .h264 }
        switch codecPreference {
        case .h264: return .h264
        case .auto: return .hevc
        }
    }

    // MARK: - Helper environment mapping

    /// Env-var names carrying the spawn-time knobs into the capture-helper.
    /// Env (not the framed `contentFilter` payload) so the wire schema
    /// stays untouched and a crash-restart respawn reuses the same bytes.
    static let fpsCapEnvKey = "TAILSCREEN_FPS_CAP"
    static let codecPrefEnvKey = "TAILSCREEN_CODEC_PREF"
    static let maxBitrateEnvKey = "TAILSCREEN_MAX_BITRATE"
    static let encoderQualityEnvKey = "TAILSCREEN_ENCODER_QUALITY"

    /// Pure projection onto the child-process environment overrides.
    /// Inverse of `fromEnvironment(_:)` for the four knobs (the preset
    /// label itself never travels — it's derived, and the helper doesn't
    /// care).
    func helperEnvironment() -> [String: String] {
        var env = [
            Self.fpsCapEnvKey: String(fpsCap),
            Self.codecPrefEnvKey: codecPreference.rawValue,
            Self.encoderQualityEnvKey: String(encoderQuality)
        ]
        if let ceiling = maxBitrateBps {
            env[Self.maxBitrateEnvKey] = String(ceiling)
        }
        return env
    }

    /// Pure inverse of `helperEnvironment()`, used inside the helper.
    /// Absent or unparseable vars leave the corresponding field at its
    /// default; parsed values are normalized (snapped / clamped).
    static func fromEnvironment(_ env: [String: String]) -> QualitySettings {
        var out = QualitySettings()
        if let raw = env[fpsCapEnvKey], let fps = Int(raw) {
            out.fpsCap = fps
        }
        if let raw = env[codecPrefEnvKey], let pref = CodecPreference(rawValue: raw) {
            out.codecPreference = pref
        }
        if let raw = env[maxBitrateEnvKey], let ceiling = Int(raw) {
            out.maxBitrateBps = ceiling
        }
        if let raw = env[encoderQualityEnvKey], let quality = Double(raw) {
            out.encoderQuality = quality
        }
        return out.normalized()
    }
}

/// Persisted quality settings. Mirrors `ViewerApprovalDefaults` — plain
/// `UserDefaults` so non-SwiftUI call sites (`AppState.init`'s
/// stored-property initialiser) can read the saved value without going
/// through `@AppStorage`. The `defaults` parameter exists for tests, which
/// use a scratch suite instead of `.standard`.
enum QualitySettingsStore {
    static let key = "qualitySettings"

    static func load(from defaults: UserDefaults = .standard) -> QualitySettings {
        guard let data = defaults.data(forKey: key) else { return .default }
        guard let decoded = try? JSONDecoder().decode(QualitySettings.self, from: data) else {
            return .default
        }
        return decoded.normalized()
    }

    static func save(_ settings: QualitySettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
