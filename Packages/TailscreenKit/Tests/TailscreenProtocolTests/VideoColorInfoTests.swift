import TailscreenProtocol
import XCTest

/// `VideoColorInfo` — the colour description riding with a decoded frame.
/// `limited` must be the default: H.264 and HEVC both define an absent
/// `video_full_range_flag` that way, and the repo's limited-range sharers
/// (X11, portal, WGC) depend on it.
final class VideoColorInfoTests: XCTestCase {
    func testDefaultIsLimitedRangeAndSaysNothingElse() {
        let info = VideoColorInfo.unspecifiedLimited
        XCTAssertEqual(info.range, .limited)
        XCTAssertEqual(info.primaries, .unspecified)
        XCTAssertEqual(info.transfer, .unspecified)
        XCTAssertEqual(VideoColorInfo(), info)
    }

    // MARK: - The overlay label

    func testLabelPrintsRangeAloneWhenNothingElseIsSignalled() {
        // A plain BT.709 stream tags no primaries; inventing "BT.709" would claim what the stream never said.
        XCTAssertEqual(VideoColorInfo.unspecifiedLimited.shortLabel, "limited")
        XCTAssertEqual(VideoColorInfo(range: .full).shortLabel, "full")
    }

    func testLabelNamesPrimariesAndRange() {
        XCTAssertEqual(
            VideoColorInfo(range: .full, primaries: .displayP3).shortLabel,
            "P3 · full")
        XCTAssertEqual(
            VideoColorInfo(range: .limited, primaries: .bt2020, transfer: .pq).shortLabel,
            "BT.2020 · PQ · limited")
    }

    func testLabelOmitsABT709TransferAsRedundant() {
        // Nearly every SDR stream carries transfer = BT.709; printing it beside
        // BT.709 primaries would add noise. A non-709 transfer is kept.
        XCTAssertEqual(
            VideoColorInfo(range: .limited, primaries: .bt709, transfer: .bt709).shortLabel,
            "BT.709 · limited")
        XCTAssertEqual(
            VideoColorInfo(range: .limited, primaries: .bt709, transfer: .hlg).shortLabel,
            "BT.709 · HLG · limited")
    }

    func testUnrecognisedCodesKeepTheirNumberRatherThanBecomingBT709() {
        // Reporting an unknown primary as BT.709 would hide a colour bug in the readout meant to diagnose it.
        XCTAssertEqual(VideoColorPrimaries.other(22).shortLabel, "code 22")
        XCTAssertEqual(VideoTransferFunction.other(18).shortLabel, "code 18")
        XCTAssertEqual(
            VideoColorInfo(range: .limited, primaries: .other(22)).shortLabel,
            "code 22 · limited")
    }

    func testRangeLabelsAreTheWordsTheOverlayPrints() {
        XCTAssertEqual(VideoColorRange.limited.shortLabel, "limited")
        XCTAssertEqual(VideoColorRange.full.shortLabel, "full")
        XCTAssertEqual(VideoColorRange.allCases.count, 2)
    }
}
