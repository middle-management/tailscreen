// `SharerLinkSession`, the share-by-token link lifecycle all three hosts
// drive — and, until this suite, the one file in the sharer tier with no
// test naming it at all.
//
// It could not have had one: every method took a real `GuestServerNode`,
// whose `start()` blocks on a DERP handshake over the network, and a real
// `TailscaleScreenShareServer`. Two review rounds on PR #304 found eight
// concurrency bugs in it and its callers; every one was ordering around an
// `await`, and none was reachable by the extract-the-decision pattern the
// rest of this tier uses — there is no pure answer here to extract, only
// *when* the claim is taken, *when* the state is blanked, and *what* is
// closed on the way out.
//
// So what is pinned here is sequence, and the fakes are built for it: an
// armed `Gate` parks the session inside a chosen call, the test runs the
// second caller that used to lose the race, and the release is explicit.
// Nothing sleeps, and nothing races for the window — a suite that raced
// would pass against the bug most runs, which is how these shipped.
//
// Each test below is written against a specific break; the header on each
// section names it. They were checked by MAKING those breaks, one at a
// time, and confirming the test goes red — a test for an ordering rule
// that has never seen the disorder is a green check over nothing.

import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenSharer
import XCTest

final class SharerLinkSessionTests: XCTestCase {

    /// A session whose mints hand back the given nodes in order.
    private func makeSession(
        nodes: [FakeGuestNode]
    ) -> SharerLinkSession {
        let remaining = NodeQueue(nodes)
        return SharerLinkSession(makeNode: { _, _ in try remaining.next() })
    }

    /// Handed to the session's factory: each mint takes the next node.
    private final class NodeQueue: @unchecked Sendable {
        private var nodes: [FakeGuestNode]
        private let lock = NSLock()
        init(_ nodes: [FakeGuestNode]) { self.nodes = nodes }
        func next() throws -> any GuestNodeProviding {
            lock.lock()
            defer { lock.unlock() }
            guard !nodes.isEmpty else { throw LinkTestError(what: "no node left to mint") }
            return nodes.removeFirst()
        }
    }

    // MARK: - Rule 1: close() blanks before it awaits
    //
    // Break: move the `await gs?.close()` above the blanking. The published
    // token and node then stay readable across that suspension, and a
    // `startLinkOnly` landing inside it takes the head guard's early return
    // — handing the replacement share the token of the link being
    // destroyed, with no node behind it.

    func testAStartLandingInsideACloseDoesNotInheritTheDyingToken() async throws {
        let log = EventLog()
        let dying = FakeGuestNode(name: "dying", log: log, mintedToken: "tc-dying", armClose: true)
        let replacement = FakeGuestNode(name: "fresh", log: log, mintedToken: "tc-fresh")
        let session = makeSession(nodes: [dying, replacement])
        let server = FakeLinkServer(log: log)

        let first = try await session.startLinkOnly(on: server, filterData: nil)
        XCTAssertEqual(first, "tc-dying")

        // Park the teardown inside the node's close.
        let teardown = Task { await session.teardown() }
        await dying.closeGate.waitForArrival()

        // The state must already be blank, so this start mints rather than
        // returning the token of the link currently being destroyed.
        let second = try await session.startLinkOnly(on: server, filterData: nil)
        await dying.closeGate.open()
        await teardown.value

        XCTAssertEqual(
            second, "tc-fresh",
            "a start landing inside close() took the head guard's early return and inherited a "
                + "token whose node is being closed")
        let live = await session.token
        XCTAssertEqual(live, "tc-fresh")
    }

    // MARK: - Rule 2: claim ownership
    //
    // Both mints take the next claim BEFORE their first await and verify it
    // before publishing; every teardown takes one, which is what invalidates
    // a mint still in flight. Break: drop either half of the pair — the
    // stale mint then publishes over the winner, leaking a live tunnel
    // nothing holds a reference to, behind a token admitting people to a
    // server nobody references.

    func testAStartSupersededMidBootstrapPublishesNothingAndClosesItsOwnNode() async throws {
        let log = EventLog()
        let stale = FakeGuestNode(name: "stale", log: log, mintedToken: "tc-stale", armToken: true)
        let session = makeSession(nodes: [stale])
        let server = FakeLinkServer(log: log)

        let mint = Task { try await session.startLinkOnly(on: server, filterData: nil) }
        await stale.tokenGate.waitForArrival()

        // The stop takes a claim; the mint parked above no longer holds one.
        await session.teardown()
        await stale.tokenGate.open()

        do {
            _ = try await mint.value
            XCTFail("a superseded mint published instead of throwing")
        } catch let error as SharerLinkError {
            XCTAssertEqual(error, .superseded)
        }

        let live = await session.token
        XCTAssertNil(live, "a superseded mint left a token behind")
        XCTAssertEqual(
            log.count(of: "stale.close"), 1,
            "the superseded mint did not close the node it had already brought up")
        // `startLinkOnly` is all-or-nothing about the server too: the same
        // unwind that closes the node stops the server it was starting.
        XCTAssertEqual(log.count(of: "server.stop"), 1)
    }

    func testEnableSupersededMidBootstrapClosesItsOwnNodeAndThrows() async throws {
        let log = EventLog()
        let stale = FakeGuestNode(name: "stale", log: log, mintedToken: "tc-stale", armToken: true)
        let session = makeSession(nodes: [stale])
        let server = FakeLinkServer(log: log)

        let mint = Task { try await session.enable(on: server) }
        await stale.tokenGate.waitForArrival()
        await session.teardown()
        await stale.tokenGate.open()

        do {
            _ = try await mint.value
            XCTFail("a superseded enable published instead of throwing")
        } catch let error as SharerLinkError {
            XCTAssertEqual(error, .superseded)
        }
        let live = await session.token
        XCTAssertNil(live)
        XCTAssertEqual(log.count(of: "stale.close"), 1)
    }

    // MARK: - Rule 3: teardown(mintedToken:) is scoped
    //
    // How a stale attempt unwinds without collateral. Break: ignore the
    // argument — a share that raced to a stop then tears down the
    // REPLACEMENT share's live link on its way out.

    func testTearingDownWithAnOldTokenClosesNothing() async throws {
        let log = EventLog()
        let first = FakeGuestNode(name: "first", log: log, mintedToken: "tc-first")
        let second = FakeGuestNode(name: "second", log: log, mintedToken: "tc-second")
        let session = makeSession(nodes: [first, second])
        let server = FakeLinkServer(log: log)

        let old = try await session.enable(on: server)
        let new = try await session.rotate(on: server)
        XCTAssertEqual(old, "tc-first")
        XCTAssertEqual(new, "tc-second")

        let closedBefore = log.count(of: "second.close")
        let tore = await session.teardown(mintedToken: old)

        XCTAssertFalse(tore, "a scoped teardown reported closing a link it does not own")
        XCTAssertEqual(
            log.count(of: "second.close"), closedBefore,
            "tearing down with a superseded token closed the replacement link's node")
        let live = await session.token
        XCTAssertEqual(live, "tc-second", "the replacement link's token was cleared by a stale stop")
    }

    func testTearingDownWithTheLiveTokenClosesIt() async throws {
        let log = EventLog()
        let node = FakeGuestNode(name: "only", log: log, mintedToken: "tc-only")
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log)

        let minted = try await session.enable(on: server)
        let tore = await session.teardown(mintedToken: minted)

        XCTAssertTrue(tore)
        XCTAssertEqual(log.count(of: "only.close"), 1)
        let live = await session.token
        XCTAssertNil(live)
    }

    // MARK: - Rule 4: startLinkOnly is all-or-nothing
    //
    // `startGuestOnly` marks the server running and installs its
    // receive/sweep loops BEFORE capture can fail, so a throw after that
    // point leaves a live server whose only reference the caller is about
    // to drop. Break: close the node but not the server.

    func testAFailedLinkOnlyStartStopsTheServerAsWellAsClosingTheNode() async throws {
        let log = EventLog()
        let node = FakeGuestNode(name: "node", log: log, mintedToken: "tc-never")
        let session = makeSession(nodes: [node])
        let boom = LinkTestError(what: "capture backend refused")
        let server = FakeLinkServer(log: log, startGuestOnlyError: boom)

        do {
            _ = try await session.startLinkOnly(on: server, filterData: nil)
            XCTFail("a failed link-only start returned a token")
        } catch let error as LinkTestError {
            XCTAssertEqual(error, boom)
        }

        XCTAssertEqual(
            log.count(of: "server.stop"), 1,
            "a half-started link-only share left the server running")
        XCTAssertEqual(log.count(of: "node.close"), 1, "the guest node outlived the failed start")
        let live = await session.token
        XCTAssertNil(live, "a share that never happened left a live token behind")
    }

    // MARK: - Rule 5: enable unwinds on an attach refusal
    //
    // The share raced to a stop while the node was coming up: nothing
    // adopted the socket. Break: skip either close — the socket or the node
    // then outlives a share that is not there, behind no token that can
    // reach it.

    func testAnAttachRefusalClosesTheListenerAndTheNodeAndLeavesNoToken() async throws {
        let log = EventLog()
        let node = FakeGuestNode(name: "node", log: log, mintedToken: "tc-never")
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log, attachPacketAnswer: false)

        do {
            _ = try await session.enable(on: server)
            XCTFail("a refused attach returned a token")
        } catch let error as SharerLinkError {
            XCTAssertEqual(error, .attachRefused)
        }

        XCTAssertEqual(log.count(of: "node.packetListener.close"), 1, "the socket was not closed")
        XCTAssertEqual(log.count(of: "node.close"), 1, "the guest node was not closed")
        let live = await session.token
        XCTAssertNil(live)
        // The token is never even asked for: a refused attach unwinds before
        // the mint, so no link is minted that nothing can reach.
        XCTAssertEqual(log.count(of: "node.token"), 0)
    }

    // MARK: - Rule 6: disable detaches before closing
    //
    // The detach is what sends each guest HELLO_DENY + SERVER_BYE, and it
    // has to go out through the still-open guest socket. Break: swap the
    // two — the node dies first and every guest sees the link vanish with
    // no word, reading as "the sharer crashed" rather than "sharing off".

    func testDisableDetachesBeforeClosingTheNode() async throws {
        let log = EventLog()
        let node = FakeGuestNode(name: "node", log: log, mintedToken: "tc-live")
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log)

        _ = try await session.enable(on: server)
        await session.disable(on: server)

        let detach = try XCTUnwrap(log.firstIndex(of: "server.detach"), "the server was not detached")
        let close = try XCTUnwrap(log.firstIndex(of: "node.close"), "the guest node was not closed")
        XCTAssertLessThan(
            detach, close,
            "the guest node was closed before the detach, so guests got no HELLO_DENY + SERVER_BYE")
        let live = await session.token
        XCTAssertNil(live)
    }

    func testDisableWithNoLinkTouchesNothing() async throws {
        let log = EventLog()
        let session = makeSession(nodes: [])
        let server = FakeLinkServer(log: log)

        await session.disable(on: server)

        XCTAssertEqual(log.all, [], "disable with no link ran the teardown anyway")
    }

    // MARK: - Rule 7: the TCP control channel is fail-soft
    //
    // A link whose TCP bind failed still carries the video and voice that
    // are the substance of a share. Break: let the throw escape — a bind
    // failure then costs the whole link, which is a worse answer than dead
    // annotations.

    func testATCPBindFailureStillYieldsAWorkingLink() async throws {
        let log = EventLog()
        var failures = FakeGuestNode.Failures()
        failures.listenControl = LinkTestError(what: "TCP bind refused")
        let node = FakeGuestNode(
            name: "node", log: log, mintedToken: "tc-voice-only", failures: failures)
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log)

        let minted = try await session.enable(on: server)

        XCTAssertEqual(minted, "tc-voice-only")
        XCTAssertNotNil(server.attachedPacket, "the UDP half did not survive the TCP failure")
        XCTAssertNil(server.attachedControl, "a failed control channel was attached anyway")
        let live = await session.token
        XCTAssertEqual(live, "tc-voice-only")
    }

    func testATCPBindFailureStillYieldsAWorkingLinkOnlyShare() async throws {
        let log = EventLog()
        var failures = FakeGuestNode.Failures()
        failures.listenControl = LinkTestError(what: "TCP bind refused")
        let node = FakeGuestNode(
            name: "node", log: log, mintedToken: "tc-link-only", failures: failures)
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log)

        let minted = try await session.startLinkOnly(on: server, filterData: nil)

        XCTAssertEqual(minted, "tc-link-only")
        XCTAssertEqual(log.count(of: "server.startGuestOnly"), 1)
        XCTAssertNil(server.attachedControl)
        XCTAssertEqual(log.count(of: "server.stop"), 0, "a fail-soft leg unwound the whole share")
    }

    /// A refused control attach is the session's to clean up — the server
    /// said it kept no reference, so nothing else will ever stop it.
    func testARefusedControlAttachStopsTheChannelAndKeepsTheLink() async throws {
        let log = EventLog()
        let node = FakeGuestNode(name: "node", log: log, mintedToken: "tc-live")
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log, attachControlAnswer: false)

        let minted = try await session.enable(on: server)

        XCTAssertEqual(minted, "tc-live")
        XCTAssertEqual(log.count(of: "node.control.stop"), 1, "the unadopted channel was leaked")
        XCTAssertNotNil(server.attachedPacket)
    }

    // MARK: - Idempotence and the eviction mapping

    func testEnableOnALiveLinkReturnsTheSameTokenWithoutMintingASecondNode() async throws {
        let log = EventLog()
        let node = FakeGuestNode(name: "only", log: log, mintedToken: "tc-live")
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log)

        let first = try await session.enable(on: server)
        let second = try await session.enable(on: server)

        XCTAssertEqual(first, second)
        // The queue holds one node; a second mint would have thrown.
        XCTAssertEqual(log.count(of: "only.start"), 1)
    }

    func testEvictMapsATunnelIPBackToItsNodeKey() async throws {
        let log = EventLog()
        let peer = try makeGuestPeer(key: "nodekey:9c8d4f21", addr: "fd7a::5")
        let node = FakeGuestNode(
            name: "node", log: log, mintedToken: "tc-live", guestPeers: [peer])
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log)

        _ = try await session.enable(on: server)
        await session.evict(ip: "fd7a::5")

        XCTAssertEqual(node.evictedKeys, ["nodekey:9c8d4f21"])
        let remaining = await session.peersByIP
        XCTAssertNil(remaining["fd7a::5"], "the evicted peer stayed in the map")
    }

    func testEvictWithNoLinkIsANoOp() async throws {
        let log = EventLog()
        let session = makeSession(nodes: [])

        await session.evict(ip: "fd7a::5")

        XCTAssertEqual(log.all, [])
    }

    func testFingerprintRefreshesThePeerMapOnAMiss() async throws {
        let log = EventLog()
        let peer = try makeGuestPeer(key: "nodekey:9c8d4f21", addr: "fd7a::5")
        let node = FakeGuestNode(
            name: "node", log: log, mintedToken: "tc-live", guestPeers: [peer])
        let session = makeSession(nodes: [node])
        let server = FakeLinkServer(log: log)

        _ = try await session.enable(on: server)
        let fingerprint = await session.fingerprint(forIP: "fd7a::5")

        XCTAssertEqual(fingerprint, ShareLinkFormat.keyFingerprint("nodekey:9c8d4f21"))
        let missing = await session.fingerprint(forIP: "fd7a::9")
        XCTAssertNil(missing, "an unknown IP produced a fingerprint out of nothing")
    }
}
