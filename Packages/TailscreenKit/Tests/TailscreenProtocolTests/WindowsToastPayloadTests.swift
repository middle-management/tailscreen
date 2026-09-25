import XCTest

@testable import TailscreenProtocol

/// `WindowsToastPayload` — the XML a Windows sharer notice is posted as, the
/// activation string a button press comes back as, and the tag it is later
/// withdrawn by. Everything here fails *silently* on a real desktop (an
/// unescaped character, an over-long tag, or an unrecognized `scenario` all
/// just post nothing), which is why it's pinned on Linux CI instead — the
/// document is a string, and a string is testable anywhere.
final class WindowsToastPayloadTests: XCTestCase {

    private let approve = WindowsToastPayload.Button(key: "approve", label: "Accept")
    private let deny = WindowsToastPayload.Button(key: "deny", label: "Deny")

    // MARK: - Escaping

    /// A peer's self-chosen hostname carrying `&` would make the whole
    /// payload fail to parse.
    func testAmpersandInLabelIsEscaped() {
        let xml = WindowsToastPayload.xml(
            summary: "Someone wants to watch",
            body: "black & white is waiting to be let in.",
            buttons: [],
            scenario: .urgent,
            identity: "100.64.0.1")

        XCTAssertTrue(xml.contains("black &amp; white"))
        XCTAssertFalse(xml.contains("black & white"))
    }

    /// A quote closes the attribute it sits in, so the three "obvious"
    /// escapes aren't enough — caller text sits inside `content="…"`.
    func testQuoteAndApostropheAreEscapedInAttributes() {
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b",
            buttons: [WindowsToastPayload.Button(key: "approve", label: "It's \"fine\"")],
            scenario: .standard,
            identity: "id")

        XCTAssertTrue(xml.contains("content=\"It&apos;s &quot;fine&quot;\""))
    }

    func testEscapesEveryMetacharacter() {
        XCTAssertEqual(
            WindowsToastPayload.escaped("&<>\"'"),
            "&amp;&lt;&gt;&quot;&apos;")
    }

    func testEscapingLeavesOrdinaryTextAlone() {
        XCTAssertEqual(WindowsToastPayload.escaped("wisp — 100.64.0.1"), "wisp — 100.64.0.1")
    }

    // MARK: - Payload shape

    func testPayloadCarriesSummaryBodyAndButtons() {
        let xml = WindowsToastPayload.xml(
            summary: "Control requested",
            body: "wisp wants to control this machine.",
            buttons: [approve, deny],
            scenario: .urgent,
            identity: "100.64.0.1")

        XCTAssertTrue(xml.hasPrefix("<toast "))
        XCTAssertTrue(xml.hasSuffix("</toast>"))
        XCTAssertTrue(xml.contains("<text>Control requested</text>"))
        XCTAssertTrue(xml.contains("<text>wisp wants to control this machine.</text>"))
        XCTAssertTrue(xml.contains("content=\"Accept\""))
        XCTAssertTrue(xml.contains("content=\"Deny\""))
        XCTAssertTrue(xml.contains("activationType=\"foreground\""))
    }

    /// An empty second line renders as a gap under the title, so it's
    /// omitted instead of emitted blank.
    func testEmptyBodyEmitsOneTextElement() {
        let xml = WindowsToastPayload.xml(
            summary: "wisp is waiting to be let in.", body: "", buttons: [],
            scenario: .reminder, identity: "100.64.0.1")

        XCTAssertEqual(xml.components(separatedBy: "<text>").count - 1, 1)
    }

    /// A report gets no `<actions>` block at all — an empty one is still
    /// an element the schema has opinions about.
    func testNoButtonsMeansNoActionsElement() {
        let xml = WindowsToastPayload.xml(
            summary: "Viewer left", body: "wisp stopped watching.", buttons: [],
            scenario: .standard, identity: "100.64.0.1:51820")

        XCTAssertFalse(xml.contains("<actions>"))
    }

    /// Matches macOS: a notification ding comes from another process, so
    /// `excludesCurrentProcessAudio` wouldn't drop it — viewers would hear
    /// every notification the sharer gets.
    func testPayloadIsSilent() {
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b", buttons: [approve], scenario: .urgent, identity: "id")

        XCTAssertTrue(xml.contains("<audio silent=\"true\"/>"))
    }

    /// Reading a notification is not a decision about a peer.
    func testToastBodyLaunchesWithTheOpenAction() {
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b", buttons: [approve, deny],
            scenario: .urgent, identity: "100.64.0.1")

        let launch = WindowsToastPayload.arguments(
            action: WindowsToastPayload.openActionKey, identity: "100.64.0.1")
        XCTAssertTrue(xml.contains("launch=\"\(WindowsToastPayload.escaped(launch))\""))
        XCTAssertNotEqual(WindowsToastPayload.openActionKey, "deny")
        XCTAssertNotEqual(WindowsToastPayload.openActionKey, "approve")
    }

    // MARK: - Scenario

    /// `standard` is the absence of the attribute, not the literal string,
    /// which the schema doesn't know and would reject.
    func testStandardScenarioEmitsNoAttribute() {
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b", buttons: [], scenario: .standard, identity: "id")

        XCTAssertFalse(xml.contains("scenario="))
        XCTAssertFalse(xml.contains("standard"))
    }

    func testUrgentScenarioIsEmitted() {
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b", buttons: [approve], scenario: .urgent, identity: "id")

        XCTAssertTrue(xml.contains("scenario=\"urgent\""))
    }

    /// Only the two mid-share asks break through Focus Assist — the
    /// exemption is revoked per app, so an idle-time invitation must not
    /// spend it.
    func testOnlyBlockingNoticesGetUrgent() {
        XCTAssertEqual(
            WindowsToastPayload.scenario(
                blocksSomeone: true, actionable: true, supportsUrgent: true),
            .urgent)
        XCTAssertEqual(
            WindowsToastPayload.scenario(
                blocksSomeone: false, actionable: true, supportsUrgent: true),
            .reminder)
    }

    /// Windows 10 knows `reminder`, not `urgent` — "wait for an answer" is
    /// the half that survives.
    func testWindows10DowngradesUrgentToReminderRatherThanStandard() {
        XCTAssertEqual(
            WindowsToastPayload.scenario(
                blocksSomeone: true, actionable: true, supportsUrgent: false),
            .reminder)
    }

    func testReportsGetNoScenario() {
        for urgent in [true, false] {
            XCTAssertEqual(
                WindowsToastPayload.scenario(
                    blocksSomeone: false, actionable: false, supportsUrgent: urgent),
                .standard)
            XCTAssertEqual(
                WindowsToastPayload.scenario(
                    blocksSomeone: true, actionable: false, supportsUrgent: urgent),
                .standard)
        }
    }

    // MARK: - Activation arguments

    func testArgumentsRoundTrip() {
        let encoded = WindowsToastPayload.arguments(action: "approve", identity: "100.64.0.1")
        let decoded = WindowsToastPayload.decodeArguments(encoded)

        XCTAssertEqual(decoded?.action, "approve")
        XCTAssertEqual(decoded?.identity, "100.64.0.1")
    }

    /// Both halves are percent-encoded so an identity carrying the field
    /// separator can't split into a third field.
    func testArgumentsRoundTripAnIdentityCarryingTheSeparators() {
        for identity in ["a&b", "a=b", "a%20b", "a b", "wisp&id=other", "wisp—ü", "%", "&&&"] {
            let encoded = WindowsToastPayload.arguments(action: "deny", identity: identity)
            XCTAssertFalse(
                encoded.dropFirst("action=deny&id=".count).contains("&"),
                "separator leaked for \(identity)")
            let decoded = WindowsToastPayload.decodeArguments(encoded)
            XCTAssertEqual(decoded?.identity, identity, "round trip failed for \(identity)")
            XCTAssertEqual(decoded?.action, "deny")
        }
    }

    /// Must survive XML escaping AND percent encoding, in that order.
    func testArgumentsSurviveTheXMLLayerToo() {
        let identity = "black & white <lab>"
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b", buttons: [approve], scenario: .urgent, identity: identity)

        let encoded = WindowsToastPayload.arguments(action: "approve", identity: identity)
        XCTAssertTrue(xml.contains("arguments=\"\(WindowsToastPayload.escaped(encoded))\""))
        XCTAssertEqual(WindowsToastPayload.decodeArguments(encoded)?.identity, identity)
    }

    /// A launch we did not write must not be answered as if a viewer were
    /// waiting on it.
    func testForeignArgumentsDecodeToNil() {
        XCTAssertNil(WindowsToastPayload.decodeArguments(""))
        XCTAssertNil(WindowsToastPayload.decodeArguments("hello"))
        XCTAssertNil(WindowsToastPayload.decodeArguments("id=100.64.0.1"))
        XCTAssertNil(WindowsToastPayload.decodeArguments("action=approve"))
        XCTAssertNil(WindowsToastPayload.decodeArguments("action=&id=x"))
    }

    /// A truncated or non-hex escape decodes to nil rather than mangled
    /// bytes that would answer the wrong peer.
    func testMalformedPercentEscapeDecodesToNil() {
        XCTAssertNil(WindowsToastPayload.percentDecoded("%"))
        XCTAssertNil(WindowsToastPayload.percentDecoded("%2"))
        XCTAssertNil(WindowsToastPayload.percentDecoded("%zz"))
        XCTAssertNil(WindowsToastPayload.decodeArguments("action=approve&id=%2"))
    }

    func testPercentEncodingLeavesUnreservedCharactersAlone() {
        XCTAssertEqual(
            WindowsToastPayload.percentEncoded("aZ09-._~"),
            "aZ09-._~")
        XCTAssertEqual(WindowsToastPayload.percentEncoded("a b"), "a%20b")
        XCTAssertEqual(WindowsToastPayload.percentEncoded("&"), "%26")
        XCTAssertEqual(WindowsToastPayload.percentEncoded("="), "%3D")
    }

    // MARK: - Tag

    func testShortSafeIdentityIsUsedVerbatim() {
        XCTAssertEqual(
            WindowsToastPayload.tag(for: "viewerPending:100.64.0.1"),
            "viewerPending:100.64.0.1")
    }

    /// The cap is a refusal, not a truncation.
    func testTagNeverExceedsTheLimit() {
        let long = "controlRequested:" + String(repeating: "a", count: 200) + ".ts.net"
        let tag = WindowsToastPayload.tag(for: long)

        XCTAssertLessThanOrEqual(tag.count, WindowsToastPayload.maxTagLength)
        XCTAssertFalse(tag.isEmpty)
    }

    func testIdentityExactlyAtTheLimitIsStillVerbatim() {
        let identity = String(repeating: "a", count: WindowsToastPayload.maxTagLength)
        XCTAssertEqual(WindowsToastPayload.tag(for: identity), identity)

        let overBy1 = String(repeating: "a", count: WindowsToastPayload.maxTagLength + 1)
        XCTAssertNotEqual(WindowsToastPayload.tag(for: overBy1), overBy1)
        XCTAssertEqual(WindowsToastPayload.tag(for: overBy1).count, WindowsToastPayload.maxTagLength)
    }

    /// A collision here withdraws the wrong person's prompt.
    func testLongIdentitiesSharingAPrefixGetDistinctTags() {
        let shared = "viewerPending:" + String(repeating: "host", count: 20)
        let first = WindowsToastPayload.tag(for: shared + "-one.ts.net")
        let second = WindowsToastPayload.tag(for: shared + "-two.ts.net")

        XCTAssertNotEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, WindowsToastPayload.maxTagLength)
        XCTAssertLessThanOrEqual(second.count, WindowsToastPayload.maxTagLength)
    }

    /// The tag must be a pure function of the identity, stable across
    /// process launches. Pinned as a literal, not by calling it twice —
    /// `Hasher` is salted per launch and would pass a same-process
    /// comparison while never withdrawing the previous run's banner.
    func testTagIsStableAcrossLaunches() {
        let identity = "viewerPending:" + String(repeating: "x", count: 90)
        XCTAssertEqual(
            WindowsToastPayload.tag(for: identity),
            "viewerPending:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-1daf589a0b758e36")
        XCTAssertEqual(
            WindowsToastPayload.tag(for: ""), "-14650fb0739d0383")
    }

    func testUnsafeCharactersAreFolded() {
        let tag = WindowsToastPayload.tag(for: "viewer pending:wisp—ü")

        XCTAssertLessThanOrEqual(tag.count, WindowsToastPayload.maxTagLength)
        XCTAssertTrue(tag.allSatisfy { $0.isASCII })
        XCTAssertFalse(tag.contains(" "))
    }

    /// `AppNotification` treats an empty tag as "no tag", silently disabling
    /// both replacing and withdrawing.
    func testEmptyIdentityStillProducesATag() {
        XCTAssertFalse(WindowsToastPayload.tag(for: "").isEmpty)
    }

    func testGroupIsConstantAndTagSafe() {
        XCTAssertEqual(
            WindowsToastPayload.tag(for: WindowsToastPayload.group), WindowsToastPayload.group)
    }
}
