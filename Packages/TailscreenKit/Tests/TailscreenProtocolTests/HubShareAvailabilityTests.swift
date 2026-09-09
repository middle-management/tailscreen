import XCTest

@testable import TailscreenProtocol

/// Unit tests for `HubShareAvailability.decide` — the gate the GTK and WinUI
/// share cards put in front of their Start button.
///
/// Worth a suite because both failure directions are silent in their own way.
/// Offering too eagerly is what shipped: the GTK hub sent people into "Share
/// failed: Tailscale isn't up yet" and the WinUI hub's button did nothing at
/// all, both from a window that otherwise looked ready. Withholding too eagerly
/// is worse and quieter still — a machine that can share, showing no way to.
final class HubShareAvailabilityTests: XCTestCase {
    func testBothPreconditionsHoldOffersTheButton() {
        XCTAssertEqual(
            HubShareAvailability.decide(captureAvailable: true, nodeIsUp: true), .available)
        XCTAssertTrue(
            HubShareAvailability.decide(captureAvailable: true, nodeIsUp: true).canStartShare)
    }

    func testNoNodeYetWithholdsIt() {
        let availability = HubShareAvailability.decide(captureAvailable: true, nodeIsUp: false)
        XCTAssertEqual(availability, .waitingForNode)
        XCTAssertFalse(availability.canStartShare)
    }

    func testNoCaptureBackendWithholdsIt() {
        let availability = HubShareAvailability.decide(captureAvailable: false, nodeIsUp: true)
        XCTAssertEqual(availability, .captureUnavailable)
        XCTAssertFalse(availability.canStartShare)
    }

    /// The asymmetric case, and the reason `decide` is ordered rather than a
    /// pair of independent flags: with neither precondition met the permanent
    /// reason has to win. "Available once Tailscale is up" on a machine with no
    /// capture backend is a promise nothing will ever keep.
    func testCaptureUnavailableOutranksWaitingForNode() {
        XCTAssertEqual(
            HubShareAvailability.decide(captureAvailable: false, nodeIsUp: false),
            .captureUnavailable)
    }

    /// Only `.available` may open the gate — asserted over every case rather
    /// than the three above, so a case added later fails here instead of
    /// quietly defaulting to letting people through.
    func testOnlyAvailableCanStartShare() {
        for availability in HubShareAvailability.allCases {
            XCTAssertEqual(
                availability.canStartShare, availability == .available,
                "\(availability) disagrees with .available about starting a share")
        }
    }
}
