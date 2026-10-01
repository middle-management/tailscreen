import TailscreenProtocol
import TailscreenSharer
import XCTest

/// `TailscaleScreenShareServer.invitedPendingToAdmit`: which parked viewers
/// an accepted invite lets in. Too narrow and the invitee hits the gate it
/// was promised to skip; too wide and an invite admits a stranger.
final class InvitedViewerAdmissionTests: XCTestCase {
    private typealias Candidate = TailscaleScreenShareServer.InvitedPendingCandidate

    private func admit(_ parked: [Candidate], ip: String, policies: [String: PeerPolicy] = [:])
        -> [String]
    {
        TailscaleScreenShareServer.invitedPendingToAdmit(parked, ip: ip, policies: policies)
    }

    func testAdmitsTheInviteesParkedViewer() {
        let parked = [
            Candidate(addr: "100.64.0.7:41000", isGuest: false, stableID: nil),
            Candidate(addr: "100.64.0.8:41000", isGuest: false, stableID: nil)
        ]
        XCTAssertEqual(admit(parked, ip: "100.64.0.7"), ["100.64.0.7:41000"])
    }

    func testNothingParkedAdmitsNothing() {
        XCTAssertEqual(admit([], ip: "100.64.0.7"), [])
    }

    func testGuestsAreNeverAdmittedByAnInvite() {
        let parked = [Candidate(addr: "100.64.0.7:41000", isGuest: true, stableID: nil)]
        XCTAssertEqual(admit(parked, ip: "100.64.0.7"), [])
    }

    func testRememberedDenyStillWins() {
        let parked = [Candidate(addr: "100.64.0.7:41000", isGuest: false, stableID: "nBlocked")]
        XCTAssertEqual(admit(parked, ip: "100.64.0.7", policies: ["nBlocked": .deny]), [])
        XCTAssertEqual(
            admit(parked, ip: "100.64.0.7", policies: ["nBlocked": .allow]), ["100.64.0.7:41000"])
    }

    func testIPv6AddressMatchesItsBareIP() {
        let parked = [Candidate(addr: "[fd7a:115c::7]:41000", isGuest: false, stableID: nil)]
        XCTAssertEqual(admit(parked, ip: "fd7a:115c::7"), ["[fd7a:115c::7]:41000"])
    }

    /// A prefix of the invitee's IP is a different machine.
    func testDoesNotMatchAnIPPrefix() {
        let parked = [Candidate(addr: "100.64.0.70:41000", isGuest: false, stableID: nil)]
        XCTAssertEqual(admit(parked, ip: "100.64.0.7"), [])
    }
}
