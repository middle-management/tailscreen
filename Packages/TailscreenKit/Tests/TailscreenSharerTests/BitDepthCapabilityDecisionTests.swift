import TailscreenProtocol
import TailscreenSharer
import XCTest

/// Unit tests for `TailscaleScreenShareServer.tenBitDowngradeNeeded` — the
/// pure gate deciding whether a share that wants 10-bit has to latch back to
/// 8-bit because one of its admitted viewers can't decode 10-bit.
///
/// The live path can't run on CI (it needs a capture helper to respawn and a
/// real viewer to advertise caps), so the decision is covered here. What makes
/// it worth its own suite is that both mistakes are silent: gating too eagerly
/// respawns the capture helper — a visible interruption for everyone watching
/// — on an ordinary 8-bit share where the capability never mattered, and
/// gating too late leaves a libavcodec viewer with a blank window while the
/// sharer's UI happily says "Sharing".
final class BitDepthCapabilityDecisionTests: XCTestCase {
    private let capable: ScreenShareCaps = [.nack, .receiverReport, .fec, .tenBit]
    private let incapable: ScreenShareCaps = [.nack, .receiverReport, .fec]

    // MARK: - The gate itself

    func testViewerWithoutTenBitForcesDowngrade() {
        XCTAssertTrue(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [capable, incapable]))
    }

    func testAllCapableViewersKeepTenBit() {
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [capable, capable]))
    }

    func testLegacyCapabilityLessViewerCountsAsIncapable() {
        // A one-byte HELLO decodes to `[]`. Absence is read as "can't decode
        // 10-bit", never as unknown (TS-CAP-006) — a legacy viewer has no way
        // to say otherwise, and guessing generously is the blank screen this
        // gate exists to prevent.
        XCTAssertTrue(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [[]]))
    }

    // MARK: - The three guards, each of which costs something when wrong

    func testEightBitShareNeverRestartsForCapability() {
        // The common case by far: no 10-bit requested, so a viewer that can't
        // decode it changes nothing. Getting this wrong would respawn the
        // capture helper every time a Linux or Windows viewer joined ANY share.
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: false, alreadyEightBit: false,
                viewerCaps: [incapable, []]))
    }

    func testAlreadyLatchedIsIdempotent() {
        // Second and third incapable viewers must cost nothing: the latch is
        // one-way, and re-firing it would restart capture per arrival.
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: true,
                viewerCaps: [incapable]))
    }

    func testNoViewersIsNotADowngrade() {
        // A share starts before anyone connects. Treating "nobody yet" as
        // "somebody can't" would pin every 10-bit share to 8-bit forever,
        // because the latch never lifts within a share.
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false, viewerCaps: []))
    }

    // MARK: - Ordering

    func testDowngradeIsIndependentOfViewerOrder() {
        // The incapable viewer is found wherever it sits in the roster —
        // dictionary iteration order is not stable, so a first-element-only
        // reading would be a coin flip in production.
        XCTAssertTrue(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [incapable, capable, capable]))
        XCTAssertTrue(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [capable, capable, incapable]))
    }

    // MARK: - The bit is not confused with its neighbours

    func testOtherCapabilitiesDoNotStandInForTenBit() {
        // `.tenBit` is bit 5; the sharer-only bits (3, 4) sit right below it.
        // A viewer that (wrongly) set those but not bit 5 still can't decode
        // 10-bit, and a mask that tested "any high bit" would say otherwise.
        XCTAssertTrue(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [[.remoteControl, .annotations]]))
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [[.tenBit]]))
    }
}
