import XCTest

@testable import TailscreenProtocol

/// `WindowsToastPayload` — the XML a Windows sharer notice is posted as, the
/// activation string a button press comes back as, and the tag it is later
/// withdrawn by.
///
/// Everything here fails *silently* on a real desktop, which is why it is
/// pinned on Linux CI instead. An unescaped character makes the platform reject
/// the payload and post nothing; an over-long tag makes it reject the
/// notification and post nothing; an unrecognized `scenario` makes it reject the
/// document and post nothing. Three different mistakes, one symptom: the toast
/// that never appeared, for one peer, on somebody else's machine.
///
/// There is no Windows runner in this loop and there does not need to be — the
/// document is a string, and a string is testable anywhere.
final class WindowsToastPayloadTests: XCTestCase {

    private let approve = WindowsToastPayload.Button(key: "approve", label: "Accept")
    private let deny = WindowsToastPayload.Button(key: "deny", label: "Deny")

    // MARK: - Escaping

    /// The one that actually bites: a peer's name is a hostname it chose
    /// itself, and an `&` in it makes the whole payload fail to parse.
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

    /// A quote closes the attribute it sits in, so the three "obvious" escapes
    /// are not enough — the payload puts caller text inside `content="…"` and
    /// `launch="…"`.
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

    /// An empty second line renders as a gap under the title rather than as
    /// nothing, so it is omitted instead of emitted blank.
    func testEmptyBodyEmitsOneTextElement() {
        let xml = WindowsToastPayload.xml(
            summary: "wisp is waiting to be let in.", body: "", buttons: [],
            scenario: .reminder, identity: "100.64.0.1")

        XCTAssertEqual(xml.components(separatedBy: "<text>").count - 1, 1)
    }

    /// A report has nothing to answer, so it gets no `<actions>` block at all —
    /// an empty one is still an element the schema has opinions about.
    func testNoButtonsMeansNoActionsElement() {
        let xml = WindowsToastPayload.xml(
            summary: "Viewer left", body: "wisp stopped watching.", buttons: [],
            scenario: .standard, identity: "100.64.0.1:51820")

        XCTAssertFalse(xml.contains("<actions>"))
    }

    /// Sharer-facing posts are silent, matching the decision macOS already
    /// shipped: with system-audio sharing on, a notification ding comes from
    /// another process and `excludesCurrentProcessAudio` does not drop it, so
    /// viewers hear every notification the sharer gets.
    func testPayloadIsSilent() {
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b", buttons: [approve], scenario: .urgent, identity: "id")

        XCTAssertTrue(xml.contains("<audio silent=\"true\"/>"))
    }

    /// Clicking the toast body must reach the app as something that is not an
    /// answer. Reading a notification is not a decision about a peer.
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

    /// `standard` is the absence of the attribute, not the string "standard" —
    /// which the schema does not know and would reject.
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

    /// Only the two mid-share asks break through Focus Assist. The exemption is
    /// revoked per app, so an invitation that arrives while the machine is idle
    /// must not spend it.
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

    /// Windows 10 knows `reminder` and not `urgent`. The half that survives is
    /// "wait for an answer" — losing that too would leave a worse notice than
    /// this platform can render.
    func testWindows10DowngradesUrgentToReminderRatherThanStandard() {
        XCTAssertEqual(
            WindowsToastPayload.scenario(
                blocksSomeone: true, actionable: true, supportsUrgent: false),
            .reminder)
    }

    /// A report expires like any other banner: there is nothing to wait for.
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

    /// The reason both halves are percent-encoded: an identity carrying the
    /// field separator would otherwise split into a third field and take the
    /// rest of the identity with it.
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

    /// An identity that survives XML escaping *and* percent encoding, in that
    /// order, is the one a real hostname produces.
    func testArgumentsSurviveTheXMLLayerToo() {
        let identity = "black & white <lab>"
        let xml = WindowsToastPayload.xml(
            summary: "s", body: "b", buttons: [approve], scenario: .urgent, identity: identity)

        // The escaped attribute is what Windows unescapes back into the raw
        // argument string, so unescaping it must land exactly on the encoding.
        let encoded = WindowsToastPayload.arguments(action: "approve", identity: identity)
        XCTAssertTrue(xml.contains("arguments=\"\(WindowsToastPayload.escaped(encoded))\""))
        XCTAssertEqual(WindowsToastPayload.decodeArguments(encoded)?.identity, identity)
    }

    /// Windows hands us whatever posted the activation. A launch we did not
    /// write must not be answered as if a viewer were waiting on it.
    func testForeignArgumentsDecodeToNil() {
        XCTAssertNil(WindowsToastPayload.decodeArguments(""))
        XCTAssertNil(WindowsToastPayload.decodeArguments("hello"))
        XCTAssertNil(WindowsToastPayload.decodeArguments("id=100.64.0.1"))
        XCTAssertNil(WindowsToastPayload.decodeArguments("action=approve"))
        XCTAssertNil(WindowsToastPayload.decodeArguments("action=&id=x"))
    }

    /// A truncated or non-hex escape decodes to nil rather than to mangled
    /// bytes — an identity that decoded to *something else* would answer the
    /// wrong peer.
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

    /// The cap is a refusal, not a truncation: an over-long tag posts nothing
    /// and withdraws nothing.
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

    /// The case the hash suffix exists for: two long hostnames sharing a
    /// prefix. A collision here withdraws the wrong person's prompt.
    func testLongIdentitiesSharingAPrefixGetDistinctTags() {
        let shared = "viewerPending:" + String(repeating: "host", count: 20)
        let first = WindowsToastPayload.tag(for: shared + "-one.ts.net")
        let second = WindowsToastPayload.tag(for: shared + "-two.ts.net")

        XCTAssertNotEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, WindowsToastPayload.maxTagLength)
        XCTAssertLessThanOrEqual(second.count, WindowsToastPayload.maxTagLength)
    }

    /// Reposting under the same tag REPLACES the banner rather than stacking a
    /// second one, and withdrawing needs the tag the post used — so the tag has
    /// to be a pure function of the identity, stable across process launches.
    ///
    /// Pinned as a literal rather than by calling it twice, which is the only
    /// version of this test that means anything: `Hasher` is salted per LAUNCH
    /// and would satisfy a same-process comparison perfectly while posting a
    /// second banner on every restart and never withdrawing the one the
    /// previous run left behind.
    func testTagIsStableAcrossLaunches() {
        let identity = "viewerPending:" + String(repeating: "x", count: 90)
        XCTAssertEqual(
            WindowsToastPayload.tag(for: identity),
            "viewerPending:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-1daf589a0b758e36")
        XCTAssertEqual(
            WindowsToastPayload.tag(for: ""), "-14650fb0739d0383")
    }

    /// Non-ASCII and whitespace fold rather than travelling into the tag.
    func testUnsafeCharactersAreFolded() {
        let tag = WindowsToastPayload.tag(for: "viewer pending:wisp—ü")

        XCTAssertLessThanOrEqual(tag.count, WindowsToastPayload.maxTagLength)
        XCTAssertTrue(tag.allSatisfy { $0.isASCII })
        XCTAssertFalse(tag.contains(" "))
    }

    /// An empty identity should not produce an empty tag: `AppNotification`
    /// treats an empty tag as "no tag", which silently disables both replacing
    /// and withdrawing.
    func testEmptyIdentityStillProducesATag() {
        XCTAssertFalse(WindowsToastPayload.tag(for: "").isEmpty)
    }

    /// One group for the whole app, so teardown can clear our toasts without
    /// touching anybody else's.
    func testGroupIsConstantAndTagSafe() {
        XCTAssertEqual(
            WindowsToastPayload.tag(for: WindowsToastPayload.group), WindowsToastPayload.group)
    }
}
