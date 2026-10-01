import XCTest

@testable import TailscreenProtocol

/// Wire-format tests for `.inviteToView` (0x0F), spec §13.3. The answer is
/// the existing `.shareResponse`, covered by `ShareResponseProtocolTests`.
final class InviteToViewProtocolTests: XCTestCase {

    func testInviteToViewRoundTrip() throws {
        var parser = ScreenShareMessageParser()
        parser.append(ScreenShareMessage.inviteToView(fromHostname: "studio-imac").encode())
        let decoded = try XCTUnwrap(parser.next())
        guard case .inviteToView(let hostname) = decoded else {
            return XCTFail("expected .inviteToView, got \(decoded)")
        }
        XCTAssertEqual(hostname, "studio-imac")
        XCTAssertNil(parser.next())
    }

    func testInviteToViewUsesTypeByte0x0F() {
        let bytes = ScreenShareMessage.inviteToView(fromHostname: "x").encode()
        XCTAssertEqual(bytes.first, 0x0F)
    }

    func testInviteToViewClampsHostname() throws {
        var parser = ScreenShareMessageParser()
        parser.append(
            ScreenShareMessage.inviteToView(fromHostname: String(repeating: "h", count: 500)).encode())
        guard case .inviteToView(let hostname)? = parser.next() else {
            return XCTFail("expected .inviteToView")
        }
        XCTAssertEqual(hostname.count, InviteToViewPayload.maxHostnameLength)
    }

    /// An undecodable invite is dropped without disturbing the next frame
    /// (TS-TCP-008).
    func testMalformedInviteIsSkipped() throws {
        var bogus = Data([0x0F, 0, 0, 0, 2])
        bogus.append(contentsOf: Array("{}".utf8))
        var parser = ScreenShareMessageParser()
        parser.append(bogus)
        parser.append(ScreenShareMessage.shareResponse(accepted: true).encode())
        guard case .shareResponse(true)? = parser.next() else {
            return XCTFail("expected .shareResponse(true) after the malformed invite")
        }
    }
}
