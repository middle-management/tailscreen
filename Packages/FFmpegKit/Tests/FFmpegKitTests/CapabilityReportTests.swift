import XCTest

@testable import FFmpegKit

/// Prints what the FFmpeg build under test actually carries, and asserts the
/// floor the viewer depends on.
///
/// The printing is the point, and it is deliberately in a test rather than a
/// tool: `swift test --package-path Packages/FFmpegKit` already runs in the
/// Windows `ffmpeg` job and the `linux-ffmpeg` job, so this reaches both
/// platforms' logs with no workflow change and no new target to keep staged.
///
/// It exists because "does our FFmpeg have NVENC / VAAPI / D3D11VA" was
/// answerable only by guessing. CI links BtbN's **LGPL** Windows build — the
/// same licensing choice that excludes libx264 and leaves libopenh264 doing the
/// encoding — and distro libavcodec on Linux, and neither announces its enabled
/// set anywhere we would see it. Every hardware-acceleration decision depends
/// on that answer, so it should be a line in a log we already produce.
///
/// Grep `FFMPEG_CAPS` in a job log.
final class CapabilityReportTests: XCTestCase {

    func testReportTheBuildsCapabilities() {
        let report = FFmpeg.capabilityReport()
        print(report)
        // Assert something, so this can't rot into a print that stopped being
        // reached. The report always names all five lines.
        XCTAssertEqual(
            report.split(separator: "\n").count, 5,
            "capability report should carry encoders, decoders and hw device types")
    }

    /// The floor: software H.264 and HEVC decode. Everything hardware is a
    /// bonus, but a build missing these cannot play a Tailscreen stream at all,
    /// and the failure would otherwise surface as a blank viewer rather than as
    /// a build problem.
    func testSoftwareDecodersForBothWireCodecsArePresent() {
        XCTAssertTrue(FFmpeg.isDecoderAvailable(.h264), "PT 96 would be undecodable")
        XCTAssertTrue(FFmpeg.isDecoderAvailable(.hevc), "PT 97 would be undecodable")
    }

    /// At least one H.264 encoder, since the Linux and Windows sharers both
    /// need one and both ladders are H.264-first. Named rather than counted so
    /// a failure says which build is short.
    func testAtLeastOneH264EncoderIsPresent() {
        let found = FFmpeg.Capabilities.h264Encoders.filter(FFmpeg.isEncoderAvailable)
        XCTAssertFalse(
            found.isEmpty,
            "no H.264 encoder in this build — the sharer cannot start a share")
    }
}
