import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsRedaction` — what never reaches a bundle, and what deliberately
/// does.
///
/// Worth pinning harder than most pure logic, because the two failure
/// directions are both silent and both bad. Under-redacting puts a live share
/// token in a file somebody pastes into a chat — the token is a bearer
/// credential, so the reader can join the share. Over-redacting quietly
/// destroys the thing the bundle was made for: a timeline with every address
/// replaced by `<redacted>` cannot be merged, because merging is exactly the
/// act of matching the addresses up.
final class DiagnosticsRedactionTests: XCTestCase {

    // MARK: - Capabilities go

    /// The share token is the sharp one: possession is permission.
    func testShareTokenIsFingerprintedNotPassedThrough() {
        let token = "tcABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        let scrubbed = DiagnosticsRedaction.scrub("joining \(token) now")

        XCTAssertFalse(scrubbed.contains(token))
        XCTAssertTrue(scrubbed.hasPrefix("joining tc:"))
        XCTAssertTrue(scrubbed.hasSuffix(" now"), "surrounding text must survive")
    }

    /// A fingerprint has to be stable, or the two sides of a merged bundle
    /// cannot be shown to have used the same link — which is the only reason
    /// it is a fingerprint rather than a flat `<redacted>`.
    func testFingerprintIsStableAndDistinguishing() {
        let a = DiagnosticsRedaction.fingerprint("tcAAAA1111BBBB2222")
        let b = DiagnosticsRedaction.fingerprint("tcAAAA1111BBBB2222")
        let c = DiagnosticsRedaction.fingerprint("tcCCCC3333DDDD4444")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 12)
    }

    /// Auth keys keep their kind and lose their secret. Which kind of key was
    /// in play is a real answer ("they were using a reusable ephemeral key");
    /// the key itself is the tailnet.
    func testAuthKeyKeepsItsKindAndLosesItsSecret() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "up failed with tskey-auth-kSecRetVaLue123456")

        XCTAssertFalse(scrubbed.contains("kSecRetVaLue123456"))
        XCTAssertTrue(scrubbed.contains("tskey-auth-"))
    }

    /// A sign-in URL's secret path goes; its origin stays, because which
    /// control server was in use is a genuine troubleshooting answer and is
    /// not itself the credential.
    func testSignInURLKeepsOriginAndDropsSecretPath() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "open https://login.tailscale.com/a/1a2b3c4d5e6f7a8b to continue")

        XCTAssertFalse(scrubbed.contains("1a2b3c4d5e6f7a8b"))
        XCTAssertTrue(scrubbed.contains("https://login.tailscale.com/"))
        XCTAssertTrue(scrubbed.contains("to continue"))
    }

    /// Self-hosted control servers are the case a hostname allowlist would
    /// miss — so the shape is matched, not the host.
    func testSelfHostedControlURLIsRedactedToo() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "visit https://headscale.example.org/a/deadbeefcafe1234")
        XCTAssertFalse(scrubbed.contains("deadbeefcafe1234"))
        XCTAssertTrue(scrubbed.contains("headscale.example.org"))
    }

    /// Punctuation after a secret must not save it. "…token=tcABC." is how a
    /// credential actually appears in a sentence-shaped log line.
    func testTrailingPunctuationDoesNotDefeatRedaction() {
        let token = "tcQQQQ1111WWWW2222EEEE"
        for suffix in [".", ",", ")", "\"", "!"] {
            let scrubbed = DiagnosticsRedaction.scrub("used \(token)\(suffix)")
            XCTAssertFalse(scrubbed.contains(token), "survived a trailing \(suffix)")
            XCTAssertTrue(scrubbed.hasSuffix(suffix), "punctuation was eaten")
        }
    }

    // MARK: - Identifiers stay

    /// Tailnet addresses are kept on purpose. They are what makes a bundle
    /// legible and what the two sides are merged on; redacting them would
    /// leave a file that cannot answer "which viewer went black".
    func testTailnetAddressesAndHostnamesSurvive() {
        let text = "viewer 100.64.0.3 (roberts-mac) admitted"
        XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
    }

    /// A node-key fingerprint is already a fingerprint — it is the guest
    /// roster's only human-readable identity, and mangling it would make the
    /// guest rows anonymous.
    func testNodeKeyFingerprintSurvives() {
        let text = "guest 9c8d…4f21 joined"
        XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
    }

    /// Ordinary prose costs nothing and comes back byte-identical — the
    /// cheap pre-filter must not mangle the overwhelmingly common case.
    func testOrdinaryTextIsUntouched() {
        for text in [
            "capture restarted after helper exit",
            "decode failed: parameter sets missing",
            "share stopped by user",
            ""
        ] {
            XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
        }
    }

    /// The docs links the app itself shows are not secrets and must not be
    /// turned into noise.
    func testWellKnownPublicLinksSurvive() {
        let text = "see https://tailscreen.dev/troubleshooting for help"
        XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
    }

    // MARK: - Field-set behaviour

    /// Keys are instrumentation-authored and must never be scrubbed: the
    /// merge joins on them.
    func testFieldKeysAreNeverScrubbed() {
        let fields: [String: DiagnosticValue] = [
            "tskey-auth-looking-key": .string("tcAAAABBBBCCCCDDDD")
        ]
        let scrubbed = DiagnosticsRedaction.scrub(fields)
        XCTAssertNotNil(scrubbed["tskey-auth-looking-key"])
    }

    /// Non-string values pass through untouched — an SSRC is not a secret and
    /// re-boxing every integer would cost an allocation per event.
    func testNonStringValuesArePreserved() {
        let fields: [String: DiagnosticValue] = [
            "ssrc": .int(7), "ok": .bool(true), "ms": .double(1.5)
        ]
        XCTAssertEqual(DiagnosticsRedaction.scrub(fields), fields)
    }
}
