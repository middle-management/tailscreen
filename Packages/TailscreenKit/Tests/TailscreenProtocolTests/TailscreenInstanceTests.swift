import XCTest

@testable import TailscreenProtocol

final class TailscreenInstanceTests: XCTestCase {
    func testServerHostnameMatches() {
        XCTAssertTrue(TailscreenInstance.isTailscreenServerHostname("tailscreen-wisp"))
        XCTAssertTrue(TailscreenInstance.isTailscreenServerHostname("tailscreen-fredriks-macbook-pro-2"))
        XCTAssertTrue(TailscreenInstance.isTailscreenServerHostname("tailscreen-"))
    }

    func testClientHostnameIsExcluded() {
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("tailscreen-client-abc123"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("tailscreen-client-"))
    }

    func testViewerHostnameIsExcluded() {
        // The portable viewer (Packages/TailscreenLinuxBackends) registers under viewerHostnamePrefix;
        // it must not appear as a connectable screen in peer discovery.
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("tailscreen-client-viewer-1a2b3c4d"))
        XCTAssertFalse(
            TailscreenInstance.isTailscreenServerHostname(TailscreenInstance.viewerHostnamePrefix + "deadbeef"))
        // The exclusion relies on the viewer prefix being built on the client
        // prefix — lock that invariant so a rename can't silently re-leak it.
        XCTAssertTrue(TailscreenInstance.viewerHostnamePrefix.hasPrefix(TailscreenInstance.clientHostnamePrefix))
    }

    func testUnrelatedHostnameIsRejected() {
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("departmentpi"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("iphone181"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("snow"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname(""))
    }

    func testPrefixIsCaseSensitive() {
        // Tailscale normalizes to lowercase; everything we register is
        // already lowercase. Don't accept variants that could collide
        // with non-Tailscreen nodes the user named themselves.
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("Tailscreen-wisp"))
        XCTAssertFalse(TailscreenInstance.isTailscreenServerHostname("TAILSCREEN-wisp"))
    }

    // MARK: - displayName

    func testDisplayNameStripsTheServerPrefix() {
        XCTAssertEqual(TailscreenInstance.displayName(fromHostname: "tailscreen-wisp"), "wisp")
        XCTAssertEqual(
            TailscreenInstance.displayName(fromHostname: "tailscreen-fredriks-macbook-pro"),
            "fredriks-macbook-pro")
    }

    func testDisplayNameKeepsTheInstanceSuffix() {
        // `TAILSCREEN_INSTANCE=2` is the ONLY thing telling two local test
        // instances apart in a list — stripping it would merge them visually.
        XCTAssertEqual(TailscreenInstance.displayName(fromHostname: "tailscreen-wisp-2"), "wisp-2")
    }

    func testDisplayNameStripsTheClientAndViewerPrefixes() {
        // Longest-prefix-first: the viewer prefix is built on the client
        // prefix, so a naive server-prefix-only strip would leave "client-…".
        XCTAssertEqual(
            TailscreenInstance.displayName(fromHostname: "tailscreen-client-1a2b3c4d"), "1a2b3c4d")
        XCTAssertEqual(
            TailscreenInstance.displayName(fromHostname: "tailscreen-client-viewer-1a2b3c4d"),
            "1a2b3c4d")
    }

    func testDisplayNameLeavesUnprefixedNamesAlone() {
        // A direct-connect target typed by hand, or a row seeded by
        // `--ui-preview`, is already a bare name.
        XCTAssertEqual(TailscreenInstance.displayName(fromHostname: "wisp"), "wisp")
        XCTAssertEqual(TailscreenInstance.displayName(fromHostname: "100.64.0.7"), "100.64.0.7")
        // Case-sensitive like the discovery filter it mirrors: everything we
        // register is lowercase, and a name the user chose stays theirs.
        XCTAssertEqual(
            TailscreenInstance.displayName(fromHostname: "Tailscreen-wisp"), "Tailscreen-wisp")
    }

    func testDisplayNameOfAPrefixOnlyHostnameFallsBackToItself() {
        // An empty row is worse than a redundant one.
        XCTAssertEqual(TailscreenInstance.displayName(fromHostname: "tailscreen-"), "tailscreen-")
        XCTAssertEqual(
            TailscreenInstance.displayName(fromHostname: "tailscreen-client-"), "tailscreen-client-")
        XCTAssertEqual(TailscreenInstance.displayName(fromHostname: ""), "")
    }

    // MARK: - nodeLabel

    func testNodeLabelLowercasesAndMapsPunctuation() {
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "Robert's PC", fallback: "x"), "robert-s-pc")
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "lab_box.local", fallback: "x"), "lab-box-local")
    }

    func testNodeLabelTrimsLeadingAndTrailingHyphens() {
        // A COMPUTERNAME of "-lab-box" used to register an illegal DNS label
        // on Windows (labels may not begin with a hyphen).
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "-lab-box", fallback: "x"), "lab-box")
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "box-", fallback: "x"), "box")
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "((box))", fallback: "x"), "box")
    }

    func testNodeLabelCapsLengthAndStaysLegalAfterTheCut() {
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: long, fallback: "x").count, 48)
        // A name whose 48th character lands on a hyphen must not keep it —
        // a trailing hyphen is as illegal as a leading one.
        let hyphenAtCut = String(repeating: "a", count: 47) + "-zzz"
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: hyphenAtCut, fallback: "x").count, 47)
        XCTAssertFalse(TailscreenInstance.nodeLabel(from: hyphenAtCut, fallback: "x").hasSuffix("-"))
    }

    func testNodeLabelIsASCIIStrict() {
        // `isLetter` would admit é/ü/漢 — all illegal in a DNS label. They
        // map to hyphens like any other disallowed scalar.
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "café", fallback: "x"), "caf")
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "漢字", fallback: "x"), "x")
    }

    func testNodeLabelFallsBackWhenNothingSurvives() {
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "", fallback: "linux"), "linux")
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "---", fallback: "windows"), "windows")
        XCTAssertEqual(TailscreenInstance.nodeLabel(from: "!!!", fallback: "windows"), "windows")
    }
}
