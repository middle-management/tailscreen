import Foundation

/// User-facing quality knobs for the sharing side — frame-rate cap, codec
/// preference, and an optional bandwidth ceiling — wrapped in a simple
/// preset. Persisted as a JSON blob in `UserDefaults` (see
/// `QualitySettingsStore`) and delivered to the capture-helper subprocess
/// as environment variables at spawn time (`helperEnvironment()` /
/// `fromEnvironment(_:)`), following the `TAILSCREEN_FORCE_H264`
/// precedent — the helper owns the SCStream + VideoToolbox pipeline, so
/// the main process never touches encoder state directly.
///
/// Mid-share semantics: the bandwidth ceiling live-applies over the
/// existing `setBitrate` wire message
/// (`TailscaleScreenShareServer.updateQualityCeiling`); fps cap and codec
/// preference are snapshotted per share session and apply the next time
/// sharing starts.
///
/// `default` reproduces the pre-settings behavior bit-for-bit: 60 fps,
/// automatic codec (HEVC with H.264 fallback), no ceiling beyond the
/// encoder's bits-per-pixel formula. Pinned by `QualitySettingsTests`.
struct QualitySettings: Codable, Equatable, Sendable {
    /// Which codec the helper's encoder should prefer. `.auto` and `.hevc`
    /// both try HEVC first and fall back to H.264 when VideoToolbox
    /// refuses; `.h264` skips HEVC entirely. A viewer-reported decode
    /// failure (`TAILSCREEN_FORCE_H264`) overrides all of these — codec
    /// fallback is a correctness mechanism, not a preference.
    enum CodecPreference: String, CaseIterable, Codable, Sendable {
        case auto
        case hevc
        case h264
    }

    /// Named knob combinations the Settings UI offers. Editing any knob
    /// directly flips the preset to `.custom`.
    enum Preset: String, CaseIterable, Codable, Sendable {
        case low
        case balanced
        case high
        case custom
    }

    /// Frame-rate caps the UI offers, ascending. `normalized()` snaps any
    /// other value down to the nearest member.
    static let allowedFPSCaps = [15, 30, 60]

    /// Bounds for the user bandwidth ceiling. The lower bound matches the
    /// adaptive sweep's absolute floor (`TransportTuning.adaptiveFloorMinBps`)
    /// so a user ceiling can never sit below where the sweep bottoms out.
    static let minCeilingBps = 500_000
    static let maxCeilingBps = 50_000_000

    /// Ceiling installed when the user first flips "Limit bandwidth" on.
    static let initialCeilingBps = 10_000_000

    var preset: Preset
    var fpsCap: Int
    var codecPreference: CodecPreference
    /// `nil` = automatic — the encoder's bits-per-pixel formula alone
    /// bounds the bitrate. Non-nil clamps that computed ceiling.
    var maxBitrateBps: Int?

    static let `default` = QualitySettings()

    init(
        preset: Preset = .balanced,
        fpsCap: Int = 60,
        codecPreference: CodecPreference = .auto,
        maxBitrateBps: Int? = nil
    ) {
        self.preset = preset
        self.fpsCap = fpsCap
        self.codecPreference = codecPreference
        self.maxBitrateBps = maxBitrateBps
    }

    // MARK: - Codable (decode-with-fallback)

    private enum CodingKeys: String, CodingKey {
        case preset
        case fpsCap
        case codecPreference
        case maxBitrateBps
    }

    /// Decode-with-fallback so an older (or newer) persisted blob never
    /// fails settings load: every missing or unparseable field degrades to
    /// its default instead of throwing. `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = Self.decodeField(container, .preset, fallback: .balanced)
        fpsCap = Self.decodeField(container, .fpsCap, fallback: 60)
        codecPreference = Self.decodeField(container, .codecPreference, fallback: .auto)
        maxBitrateBps = (try? container.decodeIfPresent(Int.self, forKey: .maxBitrateBps)) ?? nil
    }

    private static func decodeField<Value: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        fallback: Value
    ) -> Value {
        guard let decoded = try? container.decodeIfPresent(Value.self, forKey: key) else { return fallback }
        return decoded ?? fallback
    }

    // MARK: - Normalization

    /// Pure clamp: snap `fpsCap` down to the nearest allowed value (values
    /// below the smallest snap up to it) and bound a non-nil ceiling to
    /// `minCeilingBps…maxCeilingBps`. Idempotent.
    func normalized() -> QualitySettings {
        var out = self
        out.fpsCap = Self.allowedFPSCaps.last { $0 <= fpsCap } ?? Self.allowedFPSCaps[0]
        if let ceiling = maxBitrateBps {
            out.maxBitrateBps = min(max(ceiling, Self.minCeilingBps), Self.maxCeilingBps)
        }
        return out
    }

    // MARK: - Presets

    /// Pure preset → knob mapping. `balanced` is exactly today's default
    /// behavior; `custom` keeps `base`'s knobs and only relabels the
    /// preset. Idempotent for every preset.
    static func applying(preset: Preset, to base: QualitySettings) -> QualitySettings {
        switch preset {
        case .low:
            return QualitySettings(preset: .low, fpsCap: 15, codecPreference: .auto, maxBitrateBps: 2_000_000)
        case .balanced:
            return QualitySettings(preset: .balanced, fpsCap: 60, codecPreference: .auto, maxBitrateBps: nil)
        case .high:
            return QualitySettings(preset: .high, fpsCap: 60, codecPreference: .hevc, maxBitrateBps: nil)
        case .custom:
            var out = base
            out.preset = .custom
            return out
        }
    }

    /// Set one knob directly. Editing a knob flips the preset to `.custom`
    /// — the named presets are fixed combinations, not live groups.
    func updating(fpsCap: Int) -> QualitySettings {
        var out = self
        out.fpsCap = fpsCap
        out.preset = .custom
        return out.normalized()
    }

    func updating(codecPreference: CodecPreference) -> QualitySettings {
        var out = self
        out.codecPreference = codecPreference
        out.preset = .custom
        return out.normalized()
    }

    func updating(maxBitrateBps: Int?) -> QualitySettings {
        var out = self
        out.maxBitrateBps = maxBitrateBps
        out.preset = .custom
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
        case .auto, .hevc: return .hevc
        }
    }

    // MARK: - Helper environment mapping

    /// Env-var names carrying the spawn-time knobs into the capture-helper.
    /// Env (not the framed `contentFilter` payload) so the wire schema
    /// stays untouched and a crash-restart respawn reuses the same bytes.
    static let fpsCapEnvKey = "TAILSCREEN_FPS_CAP"
    static let codecPrefEnvKey = "TAILSCREEN_CODEC_PREF"
    static let maxBitrateEnvKey = "TAILSCREEN_MAX_BITRATE"

    /// Pure projection onto the child-process environment overrides.
    /// Inverse of `fromEnvironment(_:)` for the three knobs (the preset
    /// label itself never travels — the helper doesn't care).
    func helperEnvironment() -> [String: String] {
        var env = [
            Self.fpsCapEnvKey: String(fpsCap),
            Self.codecPrefEnvKey: codecPreference.rawValue
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
