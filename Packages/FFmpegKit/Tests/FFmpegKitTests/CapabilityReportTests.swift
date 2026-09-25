import XCTest

@testable import FFmpegKit

/// Prints what the FFmpeg build under test actually carries, and asserts the
/// floor the viewer depends on. Deliberately a test, not a tool, so it reaches
/// both platforms' job logs with no workflow change. Grep `FFMPEG_CAPS`.
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
