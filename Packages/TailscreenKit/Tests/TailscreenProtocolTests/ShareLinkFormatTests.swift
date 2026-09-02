import XCTest

@testable import TailscreenProtocol

/// Pins the share-by-token link shape and the paste-field parsing —
/// cross-host wire-adjacent formatting: a link "Copy Link" produces on any
/// host must round-trip through any other host's join field.
final class ShareLinkFormatTests: XCTestCase {
    private let token = "tc" + String(repeating: "aB3-_9", count: 8)

    func testLinkRoundTripsThroughParser() {
        let link = ShareLinkFormat.link(token: token)
        XCTAssertEqual(link, "tailscreen://join?token=\(token)")
        XCTAssertEqual(ShareLinkFormat.token(fromUserInput: link), token)
    }

    func testBareTokenAccepted() {
        XCTAssertEqual(ShareLinkFormat.token(fromUserInput: token), token)
        // Pastes arrive with stray whitespace from chat apps.
        XCTAssertEqual(ShareLinkFormat.token(fromUserInput: "  \(token)\n"), token)
    }

    func testSchemeVariantsAccepted() {
        // The no-slashes form a hand-typed URL produces.
        XCTAssertEqual(
            ShareLinkFormat.token(fromUserInput: "tailscreen:join?token=\(token)"), token)
        // Scheme is case-insensitive per RFC 3986.
        XCTAssertEqual(
            ShareLinkFormat.token(fromUserInput: "TAILSCREEN://join?token=\(token)"), token)
    }

    func testNonTokensRejected() {
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: ""))
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "hello world"))
        // Wrong scheme: never treat arbitrary URLs as tokens. (An http(s) URL
        // carrying a token IS a web link — see testWebLinkFromAnyHostAndQueryFormAccepted.)
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "ftp://example.com?token=\(token)"))
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "mailto:someone@example.com?token=\(token)"))
        // A web URL with no token in it is not a link either.
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "https://example.com/?ref=\(token)"))
        // Token-shaped but too short to be one.
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "tcabc"))
        // Right prefix, illegal charset (base64url has no "+").
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "tcabcdef+ghijklmn"))
        // A join URL carrying a non-token.
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "tailscreen://join?token=nope"))
    }

    func testWebLinkRoundTripsThroughParser() {
        let token = "tcomFwWCAkZttNC8pzkXTrWzFv4N3sLGmOQF4jaVRlXtm3A2vqSGFyg"
        let link = ShareLinkFormat.webLink(token: token)
        XCTAssertEqual(link, "https://tailscreen.dev/view/#\(token)")
        XCTAssertEqual(ShareLinkFormat.token(fromUserInput: link), token)
        // The token rides the fragment so it never reaches the page's host.
        XCTAssertFalse(link.contains("?"))
    }

    func testWebLinkFromAnyHostAndQueryFormAccepted() {
        let token = "tcomFwWCAkZttNC8pzkXTrWzFv4N3sLGmOQF4jaVRlXtm3A2vqSGFyg"
        XCTAssertEqual(ShareLinkFormat.token(fromUserInput: "https://screens.example/viewer/#\(token)"), token)
        XCTAssertEqual(ShareLinkFormat.token(fromUserInput: "http://localhost:8080/index.html?token=\(token)"), token)
        XCTAssertEqual(ShareLinkFormat.token(fromUserInput: "  https://tailscreen.dev/view/#\(token)\n"), token)
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "https://tailscreen.dev/view/#not-a-token"))
        XCTAssertNil(ShareLinkFormat.token(fromUserInput: "https://tailscreen.dev/view/"))
    }

    func testKeyFingerprint() {
        XCTAssertEqual(
            ShareLinkFormat.keyFingerprint("nodekey:9c8d0123456789abcdef4f21"), "9c8d…4f21")
        XCTAssertEqual(ShareLinkFormat.keyFingerprint("9c8d0123456789abcdef4f21"), "9c8d…4f21")
        // Too short to elide: shown as-is rather than mangled.
        XCTAssertEqual(ShareLinkFormat.keyFingerprint("nodekey:abcd"), "abcd")
    }
}
