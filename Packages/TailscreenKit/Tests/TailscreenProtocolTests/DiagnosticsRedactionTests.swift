import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsRedaction` — what never reaches a bundle, and what
/// deliberately does. Both failure directions are silent: under-redacting
/// leaks a bearer-credential share token; over-redacting destroys the
/// addresses that merging needs to match sides up.
final class DiagnosticsRedactionTests: XCTestCase {

    // MARK: - Capabilities go

    /// Possession of the share token is permission.
    func testShareTokenIsFingerprintedNotPassedThrough() {
        let token = "tcABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        let scrubbed = DiagnosticsRedaction.scrub("joining \(token) now")

        XCTAssertFalse(scrubbed.contains(token))
        XCTAssertTrue(scrubbed.hasPrefix("joining tc:"))
        XCTAssertTrue(scrubbed.hasSuffix(" now"), "surrounding text must survive")
    }

    /// A bare token is the rare case — what really reaches a log line is a
    /// key/value pair, JSON fragment, or URL; testing only whole-word tokens
    /// let all of these pass through.
    func testEmbeddedTokensAreRedactedInEveryCarrierShape() {
        let token = "tcAAAABBBBCCCCDDDDEEEEFFFF"
        let carriers = [
            "token=\(token)",
            "{\"token\":\"\(token)\"}",
            "tailscreen://join?token=\(token)",
            "https://tailscreen.dev/view/#\(token)",
            "joining with token=\(token) now",
            "?token=\(token)&retry=1"
        ]
        for carrier in carriers {
            let scrubbed = DiagnosticsRedaction.scrub(carrier)
            XCTAssertFalse(
                scrubbed.contains(token),
                "token survived in \(carrier.debugDescription) → \(scrubbed)")
            XCTAssertTrue(
                scrubbed.contains("tc:"),
                "expected a fingerprint in \(scrubbed)")
        }
    }

    /// Surrounding text survives so a reader can tell WHICH thing was
    /// redacted — `token=tc:9f21…` is diagnostic, a bare `<redacted>` is not.
    func testSurroundingTextSurvivesEmbeddedRedaction() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "guest joined with token=tcQQQQ1111WWWW2222EEEE and was approved")
        XCTAssertTrue(scrubbed.hasPrefix("guest joined with token=tc:"))
        XCTAssertTrue(scrubbed.hasSuffix(" and was approved"))
    }

    /// The same token fingerprints identically wherever it appears, so a
    /// merged bundle can show both sides used one link.
    func testSameTokenFingerprintsIdenticallyWhereverItAppears() {
        let token = "tcZZZZ9999YYYY8888XXXX"
        let bare = DiagnosticsRedaction.scrub(token)
        let embedded = DiagnosticsRedaction.scrub("token=\(token)")
        XCTAssertTrue(embedded.hasSuffix(bare), "\(embedded) vs \(bare)")
    }

    /// A token is only recognised at a word boundary or after a real
    /// delimiter, so prose and paths keep their shape.
    func testOrdinaryWordsContainingTCAreNotRedacted() {
        for text in [
            "watch the patch land",
            "matched 3 of 4 packets",
            "/etc/os-release could not be read"
        ] {
            XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
        }
    }

    /// A fingerprint has to be stable, or the merge can't show two sides
    /// used the same link.
    func testFingerprintIsStableAndDistinguishing() {
        let a = DiagnosticsRedaction.fingerprint("tcAAAA1111BBBB2222")
        let b = DiagnosticsRedaction.fingerprint("tcAAAA1111BBBB2222")
        let c = DiagnosticsRedaction.fingerprint("tcCCCC3333DDDD4444")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 12)
    }

    /// Auth keys keep their kind and lose their secret.
    func testAuthKeyKeepsItsKindAndLosesItsSecret() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "up failed with tskey-auth-kSecRetVaLue123456")

        XCTAssertFalse(scrubbed.contains("kSecRetVaLue123456"))
        XCTAssertTrue(scrubbed.contains("tskey-auth-"))
    }

    /// The bare two-segment `tskey-<secret>` form was leaking the secret
    /// verbatim (appended as `tskey-<secret>-<redacted>`); only the
    /// three-segment form was tested before.
    func testBareAuthKeyDoesNotLeakItsSecret() {
        let scrubbed = DiagnosticsRedaction.scrub("up failed with tskey-SECRETVALUE123456")
        XCTAssertFalse(scrubbed.contains("SECRETVALUE123456"), scrubbed)
        XCTAssertTrue(scrubbed.contains("tskey-"), scrubbed)
    }

    /// An unrecognised kind is treated as a secret, not a kind.
    func testUnknownAuthKeyKindIsRedactedWholesale() {
        let scrubbed = DiagnosticsRedaction.scrub("tskey-somethingnew-SECRET99999")
        XCTAssertFalse(scrubbed.contains("SECRET99999"), scrubbed)
        XCTAssertFalse(scrubbed.contains("somethingnew"), scrubbed)
    }

    func testKnownAuthKeyKindsAreKept() {
        for kind in ["auth", "client", "api"] {
            let scrubbed = DiagnosticsRedaction.scrub("tskey-\(kind)-SECRETABCDEF")
            XCTAssertFalse(scrubbed.contains("SECRETABCDEF"), scrubbed)
            XCTAssertTrue(scrubbed.contains("tskey-\(kind)-"), scrubbed)
        }
    }

    func testEmbeddedAuthKeysAreRedacted() {
        for carrier in [
            "authKey=tskey-auth-SECRETABCDEF",
            "{\"authKey\":\"tskey-auth-SECRETABCDEF\"}",
            "start failed (tskey-auth-SECRETABCDEF)"
        ] {
            let scrubbed = DiagnosticsRedaction.scrub(carrier)
            XCTAssertFalse(scrubbed.contains("SECRETABCDEF"), "\(carrier) → \(scrubbed)")
        }
    }

    /// A sign-in URL's secret path goes; its origin stays.
    func testSignInURLKeepsOriginAndDropsSecretPath() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "open https://login.tailscale.com/a/1a2b3c4d5e6f7a8b to continue")

        XCTAssertFalse(scrubbed.contains("1a2b3c4d5e6f7a8b"))
        XCTAssertTrue(scrubbed.contains("https://login.tailscale.com/"))
        XCTAssertTrue(scrubbed.contains("to continue"))
    }

    /// The shape is matched, not the host — self-hosted control servers
    /// would defeat a hostname allowlist.
    func testSelfHostedControlURLIsRedactedToo() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "visit https://headscale.example.org/a/deadbeefcafe1234")
        XCTAssertFalse(scrubbed.contains("deadbeefcafe1234"))
        XCTAssertTrue(scrubbed.contains("headscale.example.org"))
    }

    /// Punctuation after a secret must not save it.
    func testTrailingPunctuationDoesNotDefeatRedaction() {
        let token = "tcQQQQ1111WWWW2222EEEE"
        for suffix in [".", ",", ")", "\"", "!"] {
            let scrubbed = DiagnosticsRedaction.scrub("used \(token)\(suffix)")
            XCTAssertFalse(scrubbed.contains(token), "survived a trailing \(suffix)")
            XCTAssertTrue(scrubbed.hasSuffix(suffix), "punctuation was eaten")
        }
    }

    // MARK: - Identifiers stay

    /// Tailnet addresses are kept on purpose — what makes a bundle legible
    /// and what the two sides are merged on.
    func testTailnetAddressesAndHostnamesSurvive() {
        let text = "viewer 100.64.0.3 (roberts-mac) admitted"
        XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
    }

    /// A node-key fingerprint is already a fingerprint — the guest roster's
    /// only human-readable identity.
    func testNodeKeyFingerprintSurvives() {
        let text = "guest 9c8d…4f21 joined"
        XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
    }

    /// The cheap pre-filter must not mangle the overwhelmingly common case.
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

    func testWellKnownPublicLinksSurvive() {
        let text = "see https://tailscreen.dev/troubleshooting for help"
        XCTAssertEqual(DiagnosticsRedaction.scrub(text), text)
    }

    /// A URL the origin-keeping branch leaves WHOLE still must go through
    /// the auth-key scan — an exempt docs path used to return early and
    /// leak an embedded `?authKey=…`.
    func testExemptURLStillLosesAnEmbeddedAuthKey() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "opened https://tailscreen.dev/install?authKey=tskey-auth-kSECRETVALUE1234")

        XCTAssertFalse(scrubbed.contains("kSECRETVALUE1234"), scrubbed)
        XCTAssertTrue(scrubbed.contains("tailscreen.dev/install"), scrubbed)
    }

    /// Same hole, reached the other way: a URL with no path never finds a
    /// slash to split on.
    func testOriginOnlyURLStillLosesAnEmbeddedAuthKey() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "control=https://login.tailscale.com?authKey=tskey-auth-zSECRET99")

        XCTAssertFalse(scrubbed.contains("zSECRET99"), scrubbed)
        XCTAssertTrue(scrubbed.contains("login.tailscale.com"), scrubbed)
    }

    /// `redactCore` used to return on the first match, so a value carrying
    /// both a share token and an auth key kept the second verbatim.
    func testBothCredentialsInOneValueAreRedacted() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "join?token=tcAAAABBBBCCCCDDDD&authKey=tskey-auth-SECRETABCDEF")

        XCTAssertFalse(scrubbed.contains("tcAAAABBBBCCCCDDDD"), scrubbed)
        XCTAssertFalse(scrubbed.contains("SECRETABCDEF"), scrubbed)
        XCTAssertTrue(scrubbed.contains("tc:"), "the token's fingerprint is still useful")
        XCTAssertTrue(scrubbed.contains("tskey-auth-"), "the key's kind is still useful")
    }

    /// A login URL that ALSO carries a token loses both the opaque path and
    /// the token.
    func testLoginURLCarryingATokenLosesBoth() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "https://login.tailscale.com/a/f00dcafedeadbeef?token=tcAAAABBBBCCCCDDDD")

        XCTAssertFalse(scrubbed.contains("f00dcafedeadbeef"), scrubbed)
        XCTAssertFalse(scrubbed.contains("tcAAAABBBBCCCCDDDD"), scrubbed)
        XCTAssertTrue(scrubbed.hasPrefix("https://login.tailscale.com/"), scrubbed)
    }

    /// The share link's path is long only because the fingerprint is in it —
    /// measuring path length after token redaction would replace the whole thing.
    func testShareLinkKeepsItsFingerprintRatherThanLosingItsWholePath() {
        let scrubbed = DiagnosticsRedaction.scrub(
            "https://tailscreen.dev/view/#tcAAAABBBBCCCCDDDDEEEEFFFF")

        XCTAssertTrue(scrubbed.hasPrefix("https://tailscreen.dev/view/#tc:"), scrubbed)
        XCTAssertFalse(scrubbed.contains(DiagnosticsRedaction.placeholder), scrubbed)
    }

    // MARK: - Field-set behaviour

    /// Keys are instrumentation-authored and must never be scrubbed — the
    /// merge joins on them.
    func testFieldKeysAreNeverScrubbed() {
        let fields: [String: DiagnosticValue] = [
            "tskey-auth-looking-key": .string("tcAAAABBBBCCCCDDDD")
        ]
        let scrubbed = DiagnosticsRedaction.scrub(fields)
        XCTAssertNotNil(scrubbed["tskey-auth-looking-key"])
    }

    func testNonStringValuesArePreserved() {
        let fields: [String: DiagnosticValue] = [
            "ssrc": .int(7), "ok": .bool(true), "ms": .double(1.5)
        ]
        XCTAssertEqual(DiagnosticsRedaction.scrub(fields), fields)
    }
}
