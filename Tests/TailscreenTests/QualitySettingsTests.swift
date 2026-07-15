import XCTest

@testable import Tailscreen

/// CI-able unit tests for the quality-settings model (no tsnet, no SCK):
/// preset → knob mapping, normalization clamps, helper-environment
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
        // Defaults are already normalized — a fresh install changes nothing.
        XCTAssertEqual(defaults, defaults.normalized())
    }

    func testEncoderTuningPinsLegacyLiterals() {
        XCTAssertEqual(EncoderTuning.quality, 0.7)
        XCTAssertEqual(EncoderTuning.maxInFlight, 2)
        XCTAssertEqual(EncoderTuning.keyframeIntervalMultiplier, 10)
        XCTAssertEqual(EncoderTuning.dataRateBurstFactor, 1.75)
        XCTAssertEqual(EncoderTuning.dataRateWindowSeconds, 0.5)
        XCTAssertEqual(VideoEncoder.defaultBitsPerPixel(for: .hevc), 0.08)
        XCTAssertEqual(VideoEncoder.defaultBitsPerPixel(for: .h264), 0.10)
    }

    func testTransportTuningPinsLegacyLiterals() {
        XCTAssertEqual(TransportTuning.viewerIdleTimeoutNs, 15_000_000_000)
        XCTAssertEqual(TransportTuning.keepaliveIntervalNs, 500_000_000)
        XCTAssertEqual(TransportTuning.pendingApprovalTimeoutNs, 60_000_000_000)
        XCTAssertEqual(TransportTuning.helperLivenessTimeoutNs, 15_000_000_000)
        XCTAssertEqual(TransportTuning.maxQueuedVideoFramesPerViewer, 4)
        XCTAssertEqual(TransportTuning.helperCrashWindowNs, 30_000_000_000)
        XCTAssertEqual(TransportTuning.maxHelperCrashesPerWindow, 3)
        XCTAssertEqual(TransportTuning.adaptiveFloorMinBps, 500_000)
    }

    func testClientIdleDisconnectMatchesServerIdleSweep() {
        // The coupling documented in TailscaleScreenShareClient.receiveLoop
        // and TailscaleScreenShareServer.viewerIdleTimeoutNs: both ends must
        // time out together.
        XCTAssertEqual(TransportTuning.clientIdleDisconnectNs, TransportTuning.viewerIdleTimeoutNs)
    }

    func testAdaptiveBitrateFloorMath() {
        // 30 % of baseline…
        XCTAssertEqual(TransportTuning.adaptiveBitrateFloor(baseline: 10_000_000), 3_000_000)
        // …but never below the 500 kbps absolute floor.
        XCTAssertEqual(TransportTuning.adaptiveBitrateFloor(baseline: 1_000_000), 500_000)
    }

    func testUserCeilingLowerBoundMatchesAdaptiveFloor() {
        // A user ceiling can never sit below where the sweep bottoms out.
        XCTAssertEqual(QualitySettings.minCeilingBps, TransportTuning.adaptiveFloorMinBps)
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

    func testNormalizedClampsCeiling() {
        XCTAssertEqual(QualitySettings(maxBitrateBps: 100_000).normalized().maxBitrateBps, 500_000)
        XCTAssertEqual(QualitySettings(maxBitrateBps: 999_000_000).normalized().maxBitrateBps, 50_000_000)
        XCTAssertEqual(QualitySettings(maxBitrateBps: 2_000_000).normalized().maxBitrateBps, 2_000_000)
        XCTAssertNil(QualitySettings(maxBitrateBps: nil).normalized().maxBitrateBps)
    }

    func testNormalizedIsIdempotent() {
        let weird = QualitySettings(preset: .custom, fpsCap: 47, codecPreference: .h264, maxBitrateBps: 3)
        XCTAssertEqual(weird.normalized(), weird.normalized().normalized())
    }

    // MARK: - Preset → knob mapping

    func testPresetKnobMapping() {
        let low = QualitySettings.applying(preset: .low, to: .default)
        XCTAssertEqual(low.preset, .low)
        XCTAssertEqual(low.fpsCap, 15)
        XCTAssertEqual(low.codecPreference, .auto)
        XCTAssertEqual(low.maxBitrateBps, 2_000_000)

        // Balanced IS today's exact behavior.
        XCTAssertEqual(QualitySettings.applying(preset: .balanced, to: low), .default)

        let high = QualitySettings.applying(preset: .high, to: low)
        XCTAssertEqual(high.preset, .high)
        XCTAssertEqual(high.fpsCap, 60)
        XCTAssertEqual(high.codecPreference, .hevc)
        XCTAssertNil(high.maxBitrateBps)
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
        let custom = QualitySettings.applying(preset: .custom, to: low)
        XCTAssertEqual(custom.preset, .custom)
        XCTAssertEqual(custom.fpsCap, low.fpsCap)
        XCTAssertEqual(custom.codecPreference, low.codecPreference)
        XCTAssertEqual(custom.maxBitrateBps, low.maxBitrateBps)
    }

    func testEditingAnyKnobFlipsPresetToCustom() {
        XCTAssertEqual(QualitySettings.default.updating(fpsCap: 30).preset, .custom)
        XCTAssertEqual(QualitySettings.default.updating(codecPreference: .h264).preset, .custom)
        XCTAssertEqual(QualitySettings.default.updating(maxBitrateBps: 5_000_000).preset, .custom)
    }

    func testUpdatingNormalizesTheNewKnob() {
        XCTAssertEqual(QualitySettings.default.updating(fpsCap: 45).fpsCap, 30)
        XCTAssertEqual(QualitySettings.default.updating(maxBitrateBps: 1).maxBitrateBps, 500_000)
        XCTAssertNil(QualitySettings.default.updating(maxBitrateBps: nil).maxBitrateBps)
    }

    // MARK: - Codec preference → encoder codec

    func testPreferredVideoCodec() {
        XCTAssertEqual(QualitySettings(codecPreference: .auto).preferredVideoCodec(forceH264: false), .hevc)
        XCTAssertEqual(QualitySettings(codecPreference: .hevc).preferredVideoCodec(forceH264: false), .hevc)
        XCTAssertEqual(QualitySettings(codecPreference: .h264).preferredVideoCodec(forceH264: false), .h264)
    }

    func testForceH264OverridesEveryPreference() {
        // Codec fallback is a correctness mechanism — a viewer that can't
        // decode HEVC must win over the user's preference.
        for preference in QualitySettings.CodecPreference.allCases {
            XCTAssertEqual(
                QualitySettings(codecPreference: preference).preferredVideoCodec(forceH264: true),
                .h264)
        }
    }

    // MARK: - Helper-environment round-trip

    func testHelperEnvironmentRoundTrip() {
        let settings = QualitySettings(
            preset: .custom, fpsCap: 30, codecPreference: .h264, maxBitrateBps: 2_000_000)
        let round = QualitySettings.fromEnvironment(settings.helperEnvironment())
        XCTAssertEqual(round.fpsCap, 30)
        XCTAssertEqual(round.codecPreference, .h264)
        XCTAssertEqual(round.maxBitrateBps, 2_000_000)
    }

    func testHelperEnvironmentOmitsCeilingWhenAutomatic() {
        let env = QualitySettings.default.helperEnvironment()
        XCTAssertEqual(env["TAILSCREEN_FPS_CAP"], "60")
        XCTAssertEqual(env["TAILSCREEN_CODEC_PREF"], "auto")
        XCTAssertNil(env["TAILSCREEN_MAX_BITRATE"])
    }

    func testFromEnvironmentWithNoVarsIsDefault() {
        XCTAssertEqual(QualitySettings.fromEnvironment([:]), .default)
    }

    func testFromEnvironmentIgnoresGarbageValues() {
        let settings = QualitySettings.fromEnvironment([
            "TAILSCREEN_FPS_CAP": "fast",
            "TAILSCREEN_CODEC_PREF": "av1",
            "TAILSCREEN_MAX_BITRATE": "lots"
        ])
        XCTAssertEqual(settings, .default)
    }

    func testFromEnvironmentNormalizesParsedValues() {
        let settings = QualitySettings.fromEnvironment([
            "TAILSCREEN_FPS_CAP": "45",
            "TAILSCREEN_MAX_BITRATE": "1"
        ])
        XCTAssertEqual(settings.fpsCap, 30)
        XCTAssertEqual(settings.maxBitrateBps, 500_000)
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
                preset: .custom, fpsCap: 30, codecPreference: .hevc, maxBitrateBps: 8_000_000)
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

    func testDecodeToleratesUnknownAndMissingFields() throws {
        // A blob from a future version (unknown enum value, missing keys)
        // degrades field-by-field to defaults instead of failing the load.
        let blob = Data(#"{"preset":"ultra","fpsCap":30}"#.utf8)
        let decoded = try JSONDecoder().decode(QualitySettings.self, from: blob)
        XCTAssertEqual(decoded.preset, .balanced)
        XCTAssertEqual(decoded.fpsCap, 30)
        XCTAssertEqual(decoded.codecPreference, .auto)
        XCTAssertNil(decoded.maxBitrateBps)
    }
}
