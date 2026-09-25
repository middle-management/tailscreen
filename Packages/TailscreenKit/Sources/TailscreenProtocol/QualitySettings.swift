import Foundation

/// User-facing quality knobs for the sharing side — frame-rate cap, codec
/// preference, encoder quality, and an optional bandwidth ceiling. The named
/// preset is *derived* from the knobs (computed, never stored), so the
/// Settings picker can't contradict the values. Persisted as JSON in
/// `UserDefaults` (`QualitySettingsStore`) and delivered to the
/// capture-helper as spawn-time env vars (`helperEnvironment()` /
/// `fromEnvironment(_:)`), since the helper owns the SCStream +
/// VideoToolbox pipeline.
///
/// Mid-share: the bandwidth ceiling live-applies over `setBitrate`
/// (`TailscaleScreenShareServer.updateQualityCeiling`); the other three
/// knobs are snapshotted per session and apply next time sharing starts.
///
/// `default` reproduces pre-settings behavior bit-for-bit. Pinned by
/// `QualitySettingsTests`.
public struct QualitySettings: Codable, Equatable, Sendable {
    /// Which codec the helper's encoder should use. `.auto` tries HEVC
    /// first, falling back to H.264 on VideoToolbox refusal or a viewer's
    /// CODEC_NO. `.hevc` is the explicit no-safety-net variant: the sharer
    /// ignores CODEC_NO, so H.264-only viewers simply can't watch. `.h264`
    /// skips HEVC entirely. `TAILSCREEN_FORCE_H264=1` still overrides every
    /// preference. A persisted `"hevc"` blob from oldest builds (when it
    /// meant "prefer") now decodes as this explicit case.
    public enum CodecPreference: String, CaseIterable, Codable, Sendable {
        case auto
        case hevc
        case h264
    }

    /// Named knob combinations the Settings UI offers. Derived from the
    /// knobs via the computed `preset` property — never stored, so the
    /// label can't drift out of sync with the values it names.
    public enum Preset: String, CaseIterable, Sendable {
        case low
        case balanced
        case high
        case custom
    }

    /// Frame-rate caps the UI offers, ascending. `normalized()` snaps any
    /// other value down to the nearest member.
    public static let allowedFPSCaps = [15, 30, 60]

    /// Bounds for the user bandwidth ceiling. The 1 Mbps lower bound is a
    /// UX floor, decoupled from but never below the adaptive sweep's floor
    /// (`TransportTuning.adaptiveFloorMinBps`) — asserted in
    /// `QualitySettingsTests`.
    public static let minCeilingBps = 1_000_000
    public static let maxCeilingBps = 50_000_000

    /// Ceiling installed when the user first flips "Limit bandwidth" on.
    public static let initialCeilingBps = 10_000_000

    /// The ceiling that applies when the user has set none ("automatic").
    ///
    /// Automatic used to mean unbounded: a 6016x3384 capture at 60fps
    /// anchors near 98 Mbps, nearly double `maxCeilingBps` — more than the
    /// UI itself will let anyone request, and video/voice share one socket
    /// (`NetworkConfig.tailscreenPort`), so the overshoot degrades the call
    /// too. Equal to `maxCeilingBps` rather than lower: this is a
    /// consistency bound (automatic ≤ explicit), not a conservative-default
    /// judgement — nothing at/below 4K is affected. Pinned by
    /// `QualitySettingsTests`.
    public static let automaticCeilingBps = maxCeilingBps

    /// Bounds for `encoderQuality` (`kVTCompressionPropertyKey_Quality`).
    /// Below 0.3 VideoToolbox output degrades into blocky unusability;
    /// 1.0 is the property's own maximum.
    public static let minEncoderQuality = 0.3
    public static let maxEncoderQuality = 1.0

    public var fpsCap: Int
    public var codecPreference: CodecPreference
    /// `nil` = automatic — the encoder's bits-per-pixel formula alone
    /// bounds the bitrate. Non-nil clamps that computed ceiling.
    public var maxBitrateBps: Int?
    /// Perceptual-quality target handed to the encoder
    /// (`kVTCompressionPropertyKey_Quality`). Rate control runs primarily
    /// off this; the bitrate ceiling only bounds the peaks. Not exposed as
    /// its own UI knob — the presets differentiate on it.
    public var encoderQuality: Double

    public static let `default` = QualitySettings()

    public init(
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

    /// Decode-with-fallback: every missing or unparseable field degrades to
    /// its default instead of failing settings load. An old blob's stored
    /// `"preset"` key is ignored (derived now). `encode(to:)` stays
    /// synthesized.
    public init(from decoder: Decoder) throws {
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
    public func normalized() -> QualitySettings {
        var out = self
        out.fpsCap = Self.allowedFPSCaps.last { $0 <= fpsCap } ?? Self.allowedFPSCaps[0]
        out.encoderQuality = min(max(encoderQuality, Self.minEncoderQuality), Self.maxEncoderQuality)
        out.maxBitrateBps = Self.normalizedCeiling(maxBitrateBps)
        return out
    }

    /// Clamp a user bandwidth ceiling to `minCeilingBps…maxCeilingBps` and
    /// round to a whole Mbps (matching the Settings stepper's grid). `nil`
    /// passes through. Shared with `updateQualityCeiling` so live-apply
    /// clamps exactly like persistence.
    public static func normalizedCeiling(_ bps: Int?) -> Int? {
        guard let bps else { return nil }
        let clamped = min(max(bps, minCeilingBps), maxCeilingBps)
        return (clamped + 500_000) / 1_000_000 * 1_000_000
    }

    /// What a bits-per-pixel `anchorBps` actually resolves to: the user's
    /// explicit ceiling when they set one, else `automaticCeilingBps`. One
    /// function so the sharer's anchor, the live-apply path, and the
    /// capture helper's `DataRateLimits` clamp can't drift apart.
    public func cappedBitrate(anchorBps: Int) -> Int {
        min(anchorBps, maxBitrateBps ?? Self.automaticCeilingBps)
    }

    // MARK: - Presets

    /// The fixed knob combinations behind the named presets. `balanced` is
    /// the pre-settings default behavior (pinned by tests).
    private static let presetCombos: [Preset: QualitySettings] = [
        .low: QualitySettings(fpsCap: 30, codecPreference: .auto, maxBitrateBps: 3_000_000, encoderQuality: 0.6),
        .balanced: QualitySettings(fpsCap: 60, codecPreference: .auto, maxBitrateBps: nil, encoderQuality: 0.7),
        .high: QualitySettings(fpsCap: 60, codecPreference: .auto, maxBitrateBps: nil, encoderQuality: 0.85)
    ]

    /// Derived preset label: the named preset whose fixed knob combination
    /// matches this value exactly, else `.custom`. Computed (not stored)
    /// so the label can never contradict the knobs.
    public var preset: Preset {
        Self.presetCombos.first { $0.value == self }?.key ?? .custom
    }

    /// Pure preset → knob mapping. `custom` returns `base` unchanged (it
    /// names "any other combination", not a combination of its own).
    /// Idempotent for every preset.
    public static func applying(preset: Preset, to base: QualitySettings) -> QualitySettings {
        presetCombos[preset] ?? base
    }

    /// Set one knob directly. The derived `preset` re-labels itself:
    /// `.custom` unless the result happens to match a named combination.
    public func updating(fpsCap: Int) -> QualitySettings {
        var out = self
        out.fpsCap = fpsCap
        return out.normalized()
    }

    public func updating(codecPreference: CodecPreference) -> QualitySettings {
        var out = self
        out.codecPreference = codecPreference
        return out.normalized()
    }

    public func updating(maxBitrateBps: Int?) -> QualitySettings {
        var out = self
        out.maxBitrateBps = maxBitrateBps
        return out.normalized()
    }

    // MARK: - Codec resolution

    /// Codec the helper's encoder should try first. `forceH264` (the
    /// viewer-reported decode-failure latch) wins over every preference, or
    /// a viewer that can't decode HEVC would re-black-screen after a
    /// helper respawn.
    public func preferredVideoCodec(forceH264: Bool) -> VideoCodec {
        if forceH264 { return .h264 }
        switch codecPreference {
        case .h264: return .h264
        case .auto, .hevc: return .hevc
        }
    }

    // MARK: - Helper environment mapping

    /// Env-var names carrying the spawn-time knobs into the capture-helper.
    /// Env, not the framed `contentFilter` payload, so the wire schema
    /// stays untouched.
    public static let fpsCapEnvKey = "TAILSCREEN_FPS_CAP"
    public static let codecPrefEnvKey = "TAILSCREEN_CODEC_PREF"
    public static let maxBitrateEnvKey = "TAILSCREEN_MAX_BITRATE"
    public static let encoderQualityEnvKey = "TAILSCREEN_ENCODER_QUALITY"

    /// Pure projection onto the child-process environment overrides.
    /// Inverse of `fromEnvironment(_:)` for the four knobs (the preset
    /// label itself never travels — it's derived, and the helper doesn't
    /// care).
    public func helperEnvironment() -> [String: String] {
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
    public static func fromEnvironment(_ env: [String: String]) -> QualitySettings {
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

/// Persisted quality settings. Mirrors `ViewerApprovalPreference` — plain
/// `UserDefaults` so `AppState.init` can read the saved value without
/// `@AppStorage`. `defaults` exists for tests, which use a scratch suite.
public enum QualitySettingsStore {
    public static let key = "qualitySettings"

    public static func load(from defaults: UserDefaults = .standard) -> QualitySettings {
        guard let data = defaults.data(forKey: key) else { return .default }
        guard let decoded = try? JSONDecoder().decode(QualitySettings.self, from: data) else {
            return .default
        }
        return decoded.normalized()
    }

    public static func save(_ settings: QualitySettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
