import TailscreenProtocol
import TailscreenSharer
import XCTest

/// Unit tests for `TailscaleScreenShareServer.tenBitDowngradeNeeded` — the
/// pure gate deciding whether a 10-bit share must latch back to 8-bit because
/// an admitted viewer can't decode 10-bit. Can't run live on CI (needs a
/// capture-helper respawn + a real viewer advertising caps); both mistakes
/// here are silent (spurious respawn vs. a blank window on a live share).
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
        // A one-byte HELLO decodes to `[]`; absence reads as "can't decode
        // 10-bit", never as unknown (TS-CAP-006).
        XCTAssertTrue(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false,
                viewerCaps: [[]]))
    }

    // MARK: - The three guards, each of which costs something when wrong

    func testEightBitShareNeverRestartsForCapability() {
        // No 10-bit requested: an incapable viewer must change nothing, or
        // capture would respawn for every Linux/Windows viewer on any share.
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: false, alreadyEightBit: false,
                viewerCaps: [incapable, []]))
    }

    func testAlreadyLatchedIsIdempotent() {
        // The latch is one-way; re-firing would restart capture per arrival.
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: true,
                viewerCaps: [incapable]))
    }

    func testNoViewersIsNotADowngrade() {
        // "Nobody yet" must not read as "somebody can't" — the latch never
        // lifts within a share, so this would pin every share to 8-bit.
        XCTAssertFalse(
            TailscaleScreenShareServer.tenBitDowngradeNeeded(
                tenBitRequested: true, alreadyEightBit: false, viewerCaps: []))
    }

    // MARK: - Ordering

    func testDowngradeIsIndependentOfViewerOrder() {
        // Dictionary iteration order isn't stable; must not depend on it.
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
        // `.tenBit` is bit 5, adjacent to sharer-only bits 3/4 — must not
        // be confused with "any high bit set".
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
