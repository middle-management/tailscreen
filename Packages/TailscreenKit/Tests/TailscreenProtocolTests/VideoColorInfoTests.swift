import TailscreenProtocol
import XCTest

/// Unit tests for `VideoColorInfo` — the colour description that rides with a
/// decoded frame, and the one field in it a renderer must act on.
///
/// Small type, but the defaults are load-bearing in a way that is invisible at
/// the call site: every frame built by a caller that predates the field, and
/// every stream whose bitstream says nothing about range, resolves through
/// them. Getting `limited` as that default is not a preference — H.264 and
/// HEVC both define an absent `video_full_range_flag` that way, and the
/// repo's own limited-range sharers (X11, portal, WGC) depend on it.
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
        // A plain BT.709 stream tags no primaries; "— · limited" would be
        // noise, and inventing "BT.709" would be a claim the stream never made.
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
        // Nearly every SDR stream carries transfer = BT.709, so printing it
        // beside BT.709 primaries would add a word to every viewer's overlay
        // and distinguish nothing. A NON-709 transfer is exactly the case
        // worth seeing, so it is kept.
        XCTAssertEqual(
            VideoColorInfo(range: .limited, primaries: .bt709, transfer: .bt709).shortLabel,
            "BT.709 · limited")
        XCTAssertEqual(
            VideoColorInfo(range: .limited, primaries: .bt709, transfer: .hlg).shortLabel,
            "BT.709 · HLG · limited")
    }

    func testUnrecognisedCodesKeepTheirNumberRatherThanBecomingBT709() {
        // Reporting an unknown primary as BT.709 would make a colour bug look
        // like correct behaviour in the one readout meant to diagnose it.
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
