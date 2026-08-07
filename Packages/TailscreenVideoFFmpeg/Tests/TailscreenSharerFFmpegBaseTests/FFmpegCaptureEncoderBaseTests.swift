import TailscreenProtocol
import XCTest

@testable import TailscreenSharerFFmpegBase

/// The base's pure decisions: the encoder-attempt ladder, the source-gone
/// failure budget, the bitrate anchor, the start-time quality decode, the
/// pacing math, and the shared error texts. These used to live — three
/// times over — inside the X11, WGC and portal backends' capture files,
/// where none of them had a deterministic test.
final class FFmpegCaptureEncoderBaseTests: XCTestCase {
    private typealias Base = FFmpegCaptureEncoderBase

    private struct OpenFailure: Error, CustomStringConvertible {
        let name: String
        var description: String { "boom(\(name))" }
    }

    // MARK: Encoder ladder

    func testLadderTriesNamesInOrderAndStopsAtFirstSuccess() {
        var opened: [String] = []
        let result = Base.firstOpenableEncoder(
            names: ["a", "b", "c"],
            isAvailable: { _ in true },
            open: { name -> String in
                opened.append(name)
                if name == "b" { return "encoder-b" }
                throw OpenFailure(name: name)
            })
        XCTAssertEqual(result.encoder, "encoder-b")
        // "c" must never be tried once "b" opened.
        XCTAssertEqual(opened, ["a", "b"])
        // Only the genuine failure is an attempt; the success is not.
        XCTAssertEqual(result.attempts, ["a: boom(a)"])
    }

    func testLadderSkipsUnavailableNamesWithoutAnAttemptEntry() {
        var opened: [String] = []
        let result = Base.firstOpenableEncoder(
            names: ["absent", "present"],
            isAvailable: { $0 == "present" },
            open: { name -> String in
                opened.append(name)
                return "encoder"
            })
        XCTAssertEqual(result.encoder, "encoder")
        // Presence and usability are different questions: an absent encoder
        // is skipped silently (never opened), exactly as the original
        // `where FFmpeg.isEncoderAvailable(name)` loops behaved.
        XCTAssertEqual(opened, ["present"])
        XCTAssertEqual(result.attempts, [])
    }

    func testLadderCollectsEveryFailureWhenNothingOpens() {
        let result = Base.firstOpenableEncoder(
            names: ["a", "b"],
            isAvailable: { _ in true },
            open: { name -> String in throw OpenFailure(name: name) })
        XCTAssertNil(result.encoder)
        XCTAssertEqual(result.attempts, ["a: boom(a)", "b: boom(b)"])
    }

    func testEncoderUnavailableDetailTexts() {
        // No attempts means nothing was even present in this libavcodec
        // build — the message says so, naming the whole ladder.
        XCTAssertEqual(
            Base.encoderUnavailableDetail(names: ["libx264", "libopenh264"], attempts: []),
            "none of [\"libx264\", \"libopenh264\"] present in this libavcodec build")
        // With attempts, the message is the attempts, joined.
        XCTAssertEqual(
            Base.encoderUnavailableDetail(
                names: ["libx264"], attempts: ["libx264: boom", "libopenh264: bust"]),
            "libx264: boom; libopenh264: bust")
    }

    func testDefaultEncoderLaddersAreSoftwareOnly() {
        // The hardware names (h264_vaapi, h264_nvenc, h264_qsv, h264_amf,
        // hevc_*) consume hardware frames this path never allocates — listing
        // one would pick an encoder that fails avcodec_open2 on any machine
        // without the device. See the rationale on the properties.
        XCTAssertEqual(Base.defaultH264Encoders, ["libx264", "libopenh264"])
        XCTAssertEqual(Base.defaultHEVCEncoders, ["libx265"])
        for name in Base.defaultH264Encoders + Base.defaultHEVCEncoders {
            XCTAssertTrue(name.hasPrefix("lib"), "\(name) is not a software encoder")
        }
    }

    // MARK: Failure budget

    func testSourceGoneBudgetExhaustsAtLimitWithTheExactMessage() {
        var budget = Base.SourceGoneBudget()
        let error = OpenFailure(name: "grab")
        for _ in 1..<Base.SourceGoneBudget.defaultLimit {
            XCTAssertNil(budget.noteFailure(subject: "X11 capture", error: error))
        }
        // The 30th consecutive failure trips it, with the message each
        // backend always emitted (subject differs per platform).
        XCTAssertEqual(
            budget.noteFailure(subject: "X11 capture", error: error),
            "source-gone: X11 capture failed 30x: boom(grab)")
    }

    func testSourceGoneBudgetResetsOnSuccess() {
        var budget = Base.SourceGoneBudget()
        let error = OpenFailure(name: "grab")
        for _ in 1..<Base.SourceGoneBudget.defaultLimit {
            XCTAssertNil(budget.noteFailure(subject: "capture", error: error))
        }
        // One healthy frame forgives everything — a transient failure run
        // (the screen resized under us) must not accumulate toward teardown.
        budget.noteSuccess()
        XCTAssertNil(budget.noteFailure(subject: "capture", error: error))
        XCTAssertEqual(budget.consecutiveFailures, 1)
    }

    // MARK: Bitrate anchor

    func testAnchoredBitrateMatchesTheSharedFormula() {
        let formula = EncoderTuning.computeBitrate(
            width: 1920, height: 1080, fps: 30,
            bitsPerPixel: EncoderTuning.defaultBitsPerPixel(for: .h264))
        XCTAssertEqual(
            Base.anchoredBitrate(width: 1920, height: 1080, fps: 30, wantHEVC: false, ceiling: nil),
            formula)
    }

    func testAnchoredBitrateClampsToTheCeiling() {
        let unclamped = Base.anchoredBitrate(
            width: 1920, height: 1080, fps: 30, wantHEVC: false, ceiling: nil)
        let ceiling = unclamped / 2
        XCTAssertEqual(
            Base.anchoredBitrate(
                width: 1920, height: 1080, fps: 30, wantHEVC: false, ceiling: ceiling),
            ceiling)
        // A ceiling above the formula changes nothing.
        XCTAssertEqual(
            Base.anchoredBitrate(
                width: 1920, height: 1080, fps: 30, wantHEVC: false, ceiling: unclamped * 2),
            unclamped)
    }

    func testAnchoredBitrateUsesTheCodecsOwnBitsPerPixel() {
        // HEVC's default bits-per-pixel differs from H.264's, so the same
        // pixels anchor at a different budget — the anchor must follow the
        // codec actually chosen, not a hard-coded figure.
        let h264 = Base.anchoredBitrate(
            width: 1920, height: 1080, fps: 30, wantHEVC: false, ceiling: nil)
        let hevc = Base.anchoredBitrate(
            width: 1920, height: 1080, fps: 30, wantHEVC: true, ceiling: nil)
        XCTAssertNotEqual(h264, hevc)
    }

    // MARK: Start-time quality decode

    func testEncodeSettingsDefaults() {
        let settings = Base.EncodeSettings(forceH264: false, qualityEnv: [:])
        XCTAssertEqual(settings.fps, 30)
        XCTAssertFalse(settings.wantHEVC)
        XCTAssertNil(settings.bitrateCeiling)
    }

    func testEncodeSettingsReadsTheQualityEnv() {
        let settings = Base.EncodeSettings(
            forceH264: false,
            qualityEnv: [
                QualitySettings.fpsCapEnvKey: "60",
                QualitySettings.codecPrefEnvKey: VideoCodec.hevc.rawValue,
                QualitySettings.maxBitrateEnvKey: "4000000"
            ])
        XCTAssertEqual(settings.fps, 60)
        XCTAssertTrue(settings.wantHEVC)
        XCTAssertEqual(settings.bitrateCeiling, 4_000_000)
    }

    func testForceH264LatchBeatsTheHEVCPreference() {
        // The CODEC_NO fallback latch must win over the stored preference.
        let settings = Base.EncodeSettings(
            forceH264: true,
            qualityEnv: [QualitySettings.codecPrefEnvKey: VideoCodec.hevc.rawValue])
        XCTAssertFalse(settings.wantHEVC)
    }

    func testEncodeSettingsIgnoresGarbageValues() {
        let settings = Base.EncodeSettings(
            forceH264: false,
            qualityEnv: [
                QualitySettings.fpsCapEnvKey: "fast",
                QualitySettings.maxBitrateEnvKey: "lots"
            ])
        XCTAssertEqual(settings.fps, 30)
        XCTAssertNil(settings.bitrateCeiling)
    }

    // MARK: Pacing

    func testFrameSleepIsTheRemainderOfTheInterval() {
        // 30 fps = 33_333_333 ns per frame; 10 ms of work leaves the rest.
        let sleep = Base.frameSleepSeconds(elapsedNs: 10_000_000, fps: 30)
        XCTAssertEqual(sleep ?? -1, Double(33_333_333 - 10_000_000) / 1_000_000_000, accuracy: 1e-9)
    }

    func testAnOverrunFrameDoesNotSleep() {
        XCTAssertNil(Base.frameSleepSeconds(elapsedNs: 40_000_000, fps: 30))
        // Exactly at the interval is also no sleep.
        XCTAssertNil(Base.frameSleepSeconds(elapsedNs: 33_333_333, fps: 30))
    }

    func testPacingClampsANonPositiveFPS() {
        // max(1, fps) — a zero fps must not divide by zero; it paces at 1 fps.
        XCTAssertEqual(
            Base.frameSleepSeconds(elapsedNs: 0, fps: 0) ?? -1, 1.0, accuracy: 1e-9)
    }

    // MARK: Error texts

    func testStartErrorSharedDescriptions() {
        // The two texts that were byte-identical across all three backends
        // live in the shared enum; a probe or a person greps for these.
        XCTAssertEqual(
            "\(Base.StartError.malformedSelection)",
            "could not decode the picker selection")
        XCTAssertEqual(
            "\(Base.StartError.encoderUnavailable("libx264: boom"))",
            "no usable video encoder: libx264: boom")
        // The per-backend cases carry their full sentence unchanged.
        XCTAssertEqual(
            "\(Base.StartError.captureUnavailable("X11 capture unavailable: no display"))",
            "X11 capture unavailable: no display")
    }
}
