import XCTest

@testable import TailscreenProtocol

/// CI-able unit tests for the quality-settings model (no tsnet, no SCK):
/// preset ↔ knob derivation, normalization clamps, helper-environment
/// round-trip, `UserDefaults` persistence with decode-with-fallback — plus
/// pins for the centralized `TransportTuning` / `EncoderTuning` constants,
/// which must keep reproducing the literals they replaced (including the
/// client/server idle-timeout invariant).
final class QualitySettingsTests: XCTestCase {

    // MARK: - Defaults pin today's behavior

    func testDefaultReproducesLegacyBehavior() {
        let defaults = QualitySettings.default
        XCTAssertEqual(defaults.preset, .balanced)
        XCTAssertEqual(defaults.fpsCap, 60)
        XCTAssertEqual(defaults.codecPreference, .auto)
        XCTAssertNil(defaults.maxBitrateBps)
        XCTAssertEqual(defaults.encoderQuality, 0.7)
        XCTAssertEqual(defaults, defaults.normalized())
    }

    func testEncoderTuningPinsLegacyLiterals() {
        XCTAssertEqual(EncoderTuning.quality, 0.7)
        XCTAssertEqual(EncoderTuning.maxInFlight, 2)
        XCTAssertEqual(EncoderTuning.keyframeIntervalMultiplier, 10)
        XCTAssertEqual(EncoderTuning.dataRateBurstFactor, 1.75)
        XCTAssertEqual(EncoderTuning.dataRateWindowSeconds, 0.5)
        XCTAssertEqual(EncoderTuning.defaultBitsPerPixel(for: .hevc), 0.08)
        XCTAssertEqual(EncoderTuning.defaultBitsPerPixel(for: .h264), 0.10)
    }

    func testTransportTuningPinsLegacyLiterals() {
        XCTAssertEqual(TransportTuning.viewerIdleTimeoutNs, 15_000_000_000)
        XCTAssertEqual(TransportTuning.keepaliveIntervalNs, 500_000_000)
        XCTAssertEqual(TransportTuning.pendingApprovalTimeoutNs, 60_000_000_000)
        XCTAssertEqual(TransportTuning.helperLivenessTimeoutNs, 15_000_000_000)
        XCTAssertEqual(TransportTuning.maxQueuedVideoFramesPerViewer, 4)
        XCTAssertEqual(TransportTuning.maxQueuedAudioPacketsPerViewer, 24)
        XCTAssertEqual(TransportTuning.helperCrashWindowNs, 30_000_000_000)
        XCTAssertEqual(TransportTuning.maxHelperCrashesPerWindow, 3)
        XCTAssertEqual(TransportTuning.adaptiveFloorMinBps, 500_000)
    }

    /// Both ends must time out together (see receiveLoop/viewerIdleTimeoutNs).
    func testClientIdleDisconnectMatchesServerIdleSweep() {
        XCTAssertEqual(TransportTuning.clientIdleDisconnectNs, TransportTuning.viewerIdleTimeoutNs)
    }

    func testAdaptiveBitrateFloorMath() {
        XCTAssertEqual(TransportTuning.adaptiveBitrateFloor(baseline: 10_000_000), 3_000_000)  // 30%
        XCTAssertEqual(TransportTuning.adaptiveBitrateFloor(baseline: 1_000_000), 500_000)  // absolute floor
    }

    /// A user ceiling must never sit below where the adaptive sweep bottoms out.
    func testCeilingBoundsPins() {
        XCTAssertEqual(QualitySettings.minCeilingBps, 1_000_000)
        XCTAssertEqual(QualitySettings.maxCeilingBps, 50_000_000)
        XCTAssertGreaterThanOrEqual(QualitySettings.minCeilingBps, TransportTuning.adaptiveFloorMinBps)
    }

    // MARK: - cappedBitrate (the "automatic" ceiling)

    /// `automaticCeilingBps` must never exceed what the stepper grants on
    /// request — only true while it equals `maxCeilingBps`.
    func testAutomaticCeilingMatchesTheHighestExplicitCeiling() {
        XCTAssertEqual(QualitySettings.automaticCeilingBps, QualitySettings.maxCeilingBps)
    }

    /// A 6016x3384 HEVC retina capture anchors near 98 Mbps — roughly twice
    /// the most a user can ask for — because "automatic" used to fall back
    /// to the formula's own output.
    func testAutomaticCapsAnOversizedRetinaAnchor() {
        let anchor = EncoderTuning.computeBitrate(
            width: 6016, height: 3384, fps: 60,
            bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: .hevc))
        XCTAssertGreaterThan(anchor, QualitySettings.maxCeilingBps)
        let automatic = QualitySettings(maxBitrateBps: nil)
        XCTAssertEqual(automatic.cappedBitrate(anchorBps: anchor), QualitySettings.automaticCeilingBps)
    }

    /// Everything at or below 4K already anchored under the automatic
    /// ceiling, so the cap must be invisible there.
    func testAutomaticLeavesAnchorsAtOrBelow4KUntouched() {
        let automatic = QualitySettings(maxBitrateBps: nil)
        for (w, h) in [(1920, 1080), (2560, 1440), (3840, 2160)] {
            let anchor = EncoderTuning.computeBitrate(
                width: w, height: h, fps: 60,
                bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: .hevc))
            XCTAssertLessThan(anchor, QualitySettings.automaticCeilingBps, "\(w)x\(h)")
            XCTAssertEqual(automatic.cappedBitrate(anchorBps: anchor), anchor, "\(w)x\(h)")
        }
    }

    func testExplicitCeilingStillDecidesWhenItIsSet() {
        let capped = QualitySettings(maxBitrateBps: 3_000_000)
        XCTAssertEqual(capped.cappedBitrate(anchorBps: 40_000_000), 3_000_000)
        XCTAssertEqual(capped.cappedBitrate(anchorBps: 1_000_000), 1_000_000)
    }

    func testNoSettingsValueResolvesAboveTheAutomaticCeiling() {
        let huge = Int.max / 2
        for ceiling in [nil, 999_000_000, 50_000_000, 1_000] as [Int?] {
            let quality = QualitySettings(maxBitrateBps: ceiling).normalized()
            XCTAssertLessThanOrEqual(
                quality.cappedBitrate(anchorBps: huge), QualitySettings.automaticCeilingBps,
                "ceiling \(String(describing: ceiling))")
        }
    }

    // MARK: - normalized()

    func testNormalizedSnapsFPSDownToNearestAllowed() {
        XCTAssertEqual(QualitySettings(fpsCap: 45).normalized().fpsCap, 30)
        XCTAssertEqual(QualitySettings(fpsCap: 60).normalized().fpsCap, 60)
        XCTAssertEqual(QualitySettings(fpsCap: 240).normalized().fpsCap, 60)
        XCTAssertEqual(QualitySettings(fpsCap: 29).normalized().fpsCap, 15)
        XCTAssertEqual(QualitySettings(fpsCap: 1).normalized().fpsCap, 15)
        XCTAssertEqual(QualitySettings(fpsCap: -5).normalized().fpsCap, 15)
    }

    func testNormalizedClampsAndRoundsCeiling() {
        XCTAssertEqual(QualitySettings(maxBitrateBps: 100_000).normalized().maxBitrateBps, 1_000_000)
        XCTAssertEqual(QualitySettings(maxBitrateBps: 999_000_000).normalized().maxBitrateBps, 50_000_000)
        XCTAssertEqual(QualitySettings(maxBitrateBps: 2_000_000).normalized().maxBitrateBps, 2_000_000)
        // Rounds to a whole Mbps for the stepper's integer display.
        XCTAssertEqual(QualitySettings(maxBitrateBps: 2_400_000).normalized().maxBitrateBps, 2_000_000)
        XCTAssertEqual(QualitySettings(maxBitrateBps: 2_500_000).normalized().maxBitrateBps, 3_000_000)
        XCTAssertNil(QualitySettings(maxBitrateBps: nil).normalized().maxBitrateBps)
    }

    func testNormalizedClampsEncoderQuality() {
        XCTAssertEqual(QualitySettings(encoderQuality: 0.1).normalized().encoderQuality, 0.3)
        XCTAssertEqual(QualitySettings(encoderQuality: 1.5).normalized().encoderQuality, 1.0)
        XCTAssertEqual(QualitySettings(encoderQuality: 0.85).normalized().encoderQuality, 0.85)
    }

    func testNormalizedIsIdempotent() {
        let weird = QualitySettings(fpsCap: 47, codecPreference: .h264, maxBitrateBps: 1_700_000, encoderQuality: 7)
        XCTAssertEqual(weird.normalized(), weird.normalized().normalized())
    }

    // MARK: - Preset ↔ knob derivation

    func testPresetKnobMapping() {
        let low = QualitySettings.applying(preset: .low, to: .default)
        XCTAssertEqual(low.fpsCap, 30)
        XCTAssertEqual(low.codecPreference, .auto)
        XCTAssertEqual(low.maxBitrateBps, 3_000_000)
        XCTAssertEqual(low.encoderQuality, 0.6)

        XCTAssertEqual(QualitySettings.applying(preset: .balanced, to: low), .default)

        let high = QualitySettings.applying(preset: .high, to: low)
        XCTAssertEqual(high.fpsCap, 60)
        XCTAssertEqual(high.codecPreference, .auto)
        XCTAssertNil(high.maxBitrateBps)
        XCTAssertEqual(high.encoderQuality, 0.85)
    }

    func testPresetIsDerivedFromKnobs() {
        XCTAssertEqual(QualitySettings.default.preset, .balanced)
        for preset in [QualitySettings.Preset.low, .balanced, .high] {
            XCTAssertEqual(QualitySettings.applying(preset: preset, to: .default).preset, preset)
        }
    }

    func testApplyingPresetIsIdempotent() {
        for preset in QualitySettings.Preset.allCases {
            let once = QualitySettings.applying(preset: preset, to: .default)
            let twice = QualitySettings.applying(preset: preset, to: once)
            XCTAssertEqual(once, twice, "applying \(preset) twice diverged")
        }
    }

    func testApplyingCustomKeepsKnobs() {
        let low = QualitySettings.applying(preset: .low, to: .default)
        XCTAssertEqual(QualitySettings.applying(preset: .custom, to: low), low)
    }

    func testEditingAnyKnobDerivesCustom() {
        XCTAssertEqual(QualitySettings.default.updating(fpsCap: 15).preset, .custom)
        XCTAssertEqual(QualitySettings.default.updating(codecPreference: .h264).preset, .custom)
        XCTAssertEqual(QualitySettings.default.updating(maxBitrateBps: 5_000_000).preset, .custom)
        // Editing back to a named combination re-derives its label.
        XCTAssertEqual(QualitySettings.default.updating(fpsCap: 15).updating(fpsCap: 60).preset, .balanced)
    }

    func testUpdatingNormalizesTheNewKnob() {
        XCTAssertEqual(QualitySettings.default.updating(fpsCap: 45).fpsCap, 30)
        XCTAssertEqual(QualitySettings.default.updating(maxBitrateBps: 1).maxBitrateBps, 1_000_000)
        XCTAssertNil(QualitySettings.default.updating(maxBitrateBps: nil).maxBitrateBps)
    }

    // MARK: - Codec preference → encoder codec

    func testPreferredVideoCodec() {
        XCTAssertEqual(QualitySettings(codecPreference: .auto).preferredVideoCodec(forceH264: false), .hevc)
        XCTAssertEqual(QualitySettings(codecPreference: .hevc).preferredVideoCodec(forceH264: false), .hevc)
        XCTAssertEqual(QualitySettings(codecPreference: .h264).preferredVideoCodec(forceH264: false), .h264)
    }

    /// Codec fallback is correctness: a viewer that can't decode HEVC must
    /// win over the user's preference.
    func testForceH264OverridesEveryPreference() {
        for preference in QualitySettings.CodecPreference.allCases {
            XCTAssertEqual(
                QualitySettings(codecPreference: preference).preferredVideoCodec(forceH264: true),
                .h264)
        }
    }

    // MARK: - Helper-environment round-trip

    func testHelperEnvironmentRoundTrip() {
        let settings = QualitySettings(
            fpsCap: 30, codecPreference: .h264, maxBitrateBps: 2_000_000, encoderQuality: 0.6)
        XCTAssertEqual(QualitySettings.fromEnvironment(settings.helperEnvironment()), settings)

        // The helper must see the strict HEVC preference, not degrade it to auto.
        let strict = QualitySettings(codecPreference: .hevc)
        XCTAssertEqual(
            QualitySettings.fromEnvironment(strict.helperEnvironment()).codecPreference, .hevc)
    }

    func testHelperEnvironmentOmitsCeilingWhenAutomatic() {
        let env = QualitySettings.default.helperEnvironment()
        XCTAssertEqual(env["TAILSCREEN_FPS_CAP"], "60")
        XCTAssertEqual(env["TAILSCREEN_CODEC_PREF"], "auto")
        XCTAssertEqual(env["TAILSCREEN_ENCODER_QUALITY"], "0.7")
        XCTAssertNil(env["TAILSCREEN_MAX_BITRATE"])
    }

    func testFromEnvironmentWithNoVarsIsDefault() {
        XCTAssertEqual(QualitySettings.fromEnvironment([:]), .default)
    }

    func testFromEnvironmentIgnoresGarbageValues() {
        let settings = QualitySettings.fromEnvironment([
            "TAILSCREEN_FPS_CAP": "fast",
            "TAILSCREEN_CODEC_PREF": "av1",
            "TAILSCREEN_MAX_BITRATE": "lots",
            "TAILSCREEN_ENCODER_QUALITY": "high"
        ])
        XCTAssertEqual(settings, .default)
    }

    func testFromEnvironmentNormalizesParsedValues() {
        let settings = QualitySettings.fromEnvironment([
            "TAILSCREEN_FPS_CAP": "45",
            "TAILSCREEN_MAX_BITRATE": "1",
            "TAILSCREEN_ENCODER_QUALITY": "9.9"
        ])
        XCTAssertEqual(settings.fpsCap, 30)
        XCTAssertEqual(settings.maxBitrateBps, 1_000_000)
        XCTAssertEqual(settings.encoderQuality, 1.0)
    }

    // MARK: - Store persistence

    private func withScratchDefaults(_ body: (UserDefaults) -> Void) throws {
        let suite = "QualitySettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testStoreMissingKeyLoadsDefault() throws {
        try withScratchDefaults { defaults in
            XCTAssertEqual(QualitySettingsStore.load(from: defaults), .default)
        }
    }

    func testStoreRoundTrip() throws {
        try withScratchDefaults { defaults in
            let settings = QualitySettings(
                fpsCap: 30, codecPreference: .h264, maxBitrateBps: 8_000_000, encoderQuality: 0.85)
            QualitySettingsStore.save(settings, to: defaults)
            XCTAssertEqual(QualitySettingsStore.load(from: defaults), settings)
        }
    }

    func testStoreSurvivesCorruptBlob() throws {
        try withScratchDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: QualitySettingsStore.key)
            XCTAssertEqual(QualitySettingsStore.load(from: defaults), .default)
        }
    }

    /// A blob from another version degrades field-by-field to defaults
    /// instead of failing the load.
    func testDecodeToleratesUnknownAndMissingFields() throws {
        let blob = Data(#"{"preset":"ultra","fpsCap":30}"#.utf8)
        let decoded = try JSONDecoder().decode(QualitySettings.self, from: blob)
        XCTAssertEqual(decoded.fpsCap, 30)
        XCTAssertEqual(decoded.codecPreference, .auto)
        XCTAssertNil(decoded.maxBitrateBps)
        XCTAssertEqual(decoded.encoderQuality, 0.7)
        // The stored preset label is ignored; preset derives from the knobs.
        XCTAssertEqual(decoded.preset, .custom)
    }

    /// "hevc" is a first-class (explicit, no-H.264-fallback) preference. A
    /// blob from the oldest builds, where it meant "prefer", decodes to the
    /// strict case instead — the closest match to what those users expressed.
    func testDecodePreservesExplicitHEVCPreference() throws {
        let blob = Data(#"{"codecPreference":"hevc"}"#.utf8)
        let decoded = try JSONDecoder().decode(QualitySettings.self, from: blob)
        XCTAssertEqual(decoded.codecPreference, .hevc)
    }
}
