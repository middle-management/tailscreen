import Foundation
import TailscaleKit
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// The share-by-token link lifecycle, driven through a fake guest node.
///
/// This suite exists because two rounds of review found eight ordering bugs
/// here and nothing in the repo could have caught one of them: every method
/// took a live `GuestServerNode`, whose `start()` is a relay handshake, so
/// there was nothing to drive. The decisions were never wrong — what was
/// wrong, every time, was what another caller could do during an `await`.
///
/// So these cases are about interleaving, not arithmetic. Each holds the
/// bootstrap open at a suspension point the live node also has, runs a stop
/// (or a whole second share) while it is parked, and asserts what survived.
///
/// **The suite is mutation-checked.** Eleven deliberate breaks were made in
/// `SharerLinkSession`, one at a time, and each one goes red here: `close()`
/// awaiting before it blanks; `close()` taking no claim; either mint
/// publishing without verifying its claim; `teardown(mintedToken:)` ignoring
/// its argument; a failed link-only start that leaves the server running; an
/// attach refusal that leaks the socket, or the node (checked separately —
/// one assertion covering both would pass with either leak); a disable that
/// closes before it detaches; either fail-soft control leg losing its
/// `catch`; and a refused control attach that leaks the channel.
///
/// Two of those found nothing when first run, which is why the note is here
/// rather than in a commit message. `enable` and `startLinkOnly` each have
/// their OWN fail-soft `do`/`catch` around the control route, and only the
/// link-only one was covered; and a refused control attach had no case at
/// all — the fake server could not even express the refusal. Both are
/// covered now. If you add a rule to `SharerLinkSession`, break it on
/// purpose before you believe the test you wrote for it.
final class SharerLinkSessionTests: XCTestCase {

    /// Build a session whose nodes are fakes, handing back the journal and a
    /// way to reach each node by the id its token carries.
    private func makeSession(
        journal: Journal
    ) -> (SharerLinkSession, @Sendable (String) -> FakeGuestNode?) {
        let box = NodeBox()
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in box.next(journal: journal) })
        return (session, { id in box.node(id) })
    }

    /// Hands out `n1`, `n2`, … so a test can name the attempt it means.
    private final class NodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String: FakeGuestNode] = [:]
        private var counter = 0

        func next(journal: Journal) -> FakeGuestNode {
            lock.withLock {
                counter += 1
                let node = FakeGuestNode(id: "n\(counter)", journal: journal)
                made["n\(counter)"] = node
                return node
            }
        }

        func node(_ id: String) -> FakeGuestNode? { lock.withLock { made[id] } }

        /// The session makes its node inside the call, so a test that wants
        /// to reach one has to wait for the call to get that far.
        func awaitNode(_ id: String) async -> FakeGuestNode? {
            for _ in 0..<1000 {
                if let found = node(id) { return found }
                await Task.yield()
            }
            return nil
        }
    }

    // MARK: - The ordinary paths, so the interleaving ones mean something

    func testStartLinkOnlyBringsTheNodeUpBeforeTheServer() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)

        let token = try await session.startLinkOnly(on: server, filterData: nil)

        XCTAssertEqual(token, "tc-n1")
        let probe1 = await session.token
        XCTAssertEqual(probe1, "tc-n1")
        // The whole reason this path exists: the guest node IS the transport,
        // so it has to be up and bound before the server can take it as its
        // only socket.
        let entries = await journal.entries
        let nodeUp = try XCTUnwrap(entries.firstIndex(of: "node.start(n1)"))
        let bound = try XCTUnwrap(entries.firstIndex(of: "node.packet(n1)"))
        let serverUp = try XCTUnwrap(entries.firstIndex(of: "server.startGuestOnly(srv)"))
        XCTAssertLessThan(nodeUp, bound)
        XCTAssertLessThan(bound, serverUp)
    }

    func testEnableAttachesToARunningServer() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)

        let token = try await session.enable(on: server)

        XCTAssertEqual(token, "tc-n1")
        XCTAssertTrue(server.packetAttached)
    }

    /// A link whose TCP bind failed still carries video and voice, which are
    /// the substance of a share — the control channel is annotations and
    /// remote control, and losing them is not losing the share.
    func testAControlChannelThatFailsToBindStillYieldsALink() async throws {
        let journal = Journal()
        let box = NodeBox()
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in
                let node = box.next(journal: journal)
                node.controlFails = true
                return node
            })
        let server = FakeLinkServer(journal: journal)

        let token = try await session.startLinkOnly(on: server, filterData: nil)
        XCTAssertEqual(token, "tc-n1")
    }

    /// A refused attach means the share stopped underneath the bootstrap.
    /// Nothing adopted the socket, so the session closes both ends itself
    /// rather than leaving a live tunnel behind a share that is not there.
    /// `enable` has its OWN fail-soft `do`/`catch` around the control route,
    /// separate from `startLinkOnly`'s. The case above covers the link-only
    /// one; deleting this one's `catch` leaves every test in this file green,
    /// which is how it was found. Two blocks, two cases.
    func testAControlChannelThatFailsToBindStillYieldsALinkOnEnable() async throws {
        let journal = Journal()
        let box = NodeBox()
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in
                let node = box.next(journal: journal)
                node.controlFails = true
                return node
            })
        let server = FakeLinkServer(journal: journal)

        let token = try await session.enable(on: server)

        XCTAssertEqual(token, "tc-n1", "a TCP bind failure cost the whole link")
        XCTAssertTrue(server.packetAttached, "the UDP half did not survive the TCP failure")
    }

    /// A refused control attach is the session's to clean up: the server said
    /// it kept no reference, so nothing else will ever stop that channel. The
    /// link itself survives — a share with no annotations still carries the
    /// video and voice that are the substance of it.
    func testARefusedControlAttachStopsTheChannelAndKeepsTheLink() async throws {
        let journal = Journal()
        let box = NodeBox()
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in box.next(journal: journal) })
        let server = FakeLinkServer(journal: journal)
        server.refuseControlAttach()

        let token = try await session.enable(on: server)

        XCTAssertEqual(token, "tc-n1")
        let stopped = await journal.contains("control.stop(n1)")
        XCTAssertTrue(stopped, "the unadopted control channel was leaked")
        XCTAssertTrue(server.packetAttached)
    }

    func testARefusedAttachClosesTheSocketAndTheNode() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)
        server.refuseAttach()

        do {
            _ = try await session.enable(on: server)
            XCTFail("expected attachRefused")
        } catch SharerLinkError.attachRefused {
            // expected
        }
        let probe4 = await journal.contains("packet.close(n1)")
        XCTAssertTrue(probe4)
        let probe5 = await journal.contains("node.close(n1)")
        XCTAssertTrue(probe5)
        let probe11 = await session.token
        XCTAssertNil(probe11)
    }

    /// `startGuestOnly` marks the server running and installs its loops
    /// before capture can fail, so a throw after that point leaves a live
    /// server the caller is about to drop its only reference to. The unwind
    /// is all-or-nothing: the node closes AND the server stops.
    func testAGuestOnlyStartThatFailsStopsTheServerToo() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)
        server.failGuestOnly(with: SharerLinkError.attachRefused)

        do {
            _ = try await session.startLinkOnly(on: server, filterData: nil)
            XCTFail("expected the start to throw")
        } catch {
            // expected
        }
        XCTAssertTrue(server.stopped)
        let probe6 = await journal.contains("node.close(n1)")
        XCTAssertTrue(probe6)
        let probe12 = await session.token
        XCTAssertNil(probe12)
    }

    /// Detach BEFORE close, so each guest gets HELLO_DENY + SERVER_BYE
    /// through the still-open socket instead of timing out against a tunnel
    /// that vanished.
    func testDisableDetachesBeforeClosingTheNode() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)
        _ = try await session.enable(on: server)

        await session.disable(on: server)

        let entries = await journal.entries
        let detach = try XCTUnwrap(entries.firstIndex(of: "server.detach(srv)"))
        let close = try XCTUnwrap(entries.firstIndex(of: "node.close(n1)"))
        XCTAssertLessThan(detach, close)
        let probe13 = await session.token
        XCTAssertNil(probe13)
    }

    // MARK: - The interleavings, which is what this fake is for

    /// The bug: `close()` awaited the node's close before clearing `token`
    /// and `guestServer`, so both stayed readable across that suspension —
    /// and a `startLinkOnly` landing there took the head guard's early
    /// return, handing a replacement share the token of the link being
    /// destroyed, with no node behind it.
    func testAStartDuringATeardownDoesNotInheritTheDyingToken() async throws {
        let journal = Journal()
        let (session, node) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)
        _ = try await session.startLinkOnly(on: server, filterData: nil)

        // Park the teardown inside the node's close — the exact window.
        let first = try XCTUnwrap(node("n1"))
        first.closeGate.hold()
        let teardown = Task { await session.teardown() }
        await first.closeGate.waitUntilParked()

        // A replacement share starts while the old node is still closing.
        let replacement = FakeLinkServer(id: "srv2", journal: journal)
        let minted = try await session.startLinkOnly(on: replacement, filterData: nil)

        first.closeGate.release()
        await teardown.value

        // It must be a NEW link, not the dying one handed back.
        XCTAssertEqual(minted, "tc-n2")
        let probe7 = await journal.contains("server.startGuestOnly(srv2)")
        XCTAssertTrue(probe7)
    }

    /// The bug: nothing owned a mint in flight. `guestServer` is written
    /// last, so a stop landing mid-bootstrap found nothing to tear down, and
    /// the mint then published a token and a live node onto an idle app.
    func testAStopDuringABootstrapSupersedesTheMint() async throws {
        let journal = Journal()
        let box = NodeBox()
        // Armed at creation, before the session can run: a hold issued after
        // the call has started is a race the test loses by hanging.
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in
                let node = box.next(journal: journal)
                node.tokenGate.hold()
                return node
            })
        let server = FakeLinkServer(journal: journal)

        let start = Task { try await session.startLinkOnly(on: server, filterData: nil) }
        // Let the bootstrap reach the token step, then stop the share.
        let found = await box.awaitNode("n1")
        let first = try XCTUnwrap(found)
        await first.tokenGate.waitUntilParked()
        await session.teardown()
        first.tokenGate.release()

        do {
            _ = try await start.value
            XCTFail("expected the superseded mint to throw")
        } catch SharerLinkError.superseded {
            // expected
        }
        // Nothing published, and the node it built is closed rather than
        // left running behind a token nobody can reach.
        let probe14 = await session.token
        XCTAssertNil(probe14)
        let probe8 = await journal.contains("node.close(n1)")
        XCTAssertTrue(probe8)
    }

    /// The same rule on the mid-share path: a stop landing after `enable`
    /// attached its listener used to publish a token onto an idle app.
    func testAStopDuringEnableSupersedesTheMint() async throws {
        let journal = Journal()
        let box = NodeBox()
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in
                let node = box.next(journal: journal)
                node.tokenGate.hold()
                return node
            })
        let server = FakeLinkServer(journal: journal)

        let enable = Task { try await session.enable(on: server) }
        let found = await box.awaitNode("n1")
        let first = try XCTUnwrap(found)
        await first.tokenGate.waitUntilParked()
        await session.teardown()
        first.tokenGate.release()

        do {
            _ = try await enable.value
            XCTFail("expected the superseded mint to throw")
        } catch SharerLinkError.superseded {
            // expected
        }
        let probe15 = await session.token
        XCTAssertNil(probe15)
        let probe9 = await journal.contains("node.close(n1)")
        XCTAssertTrue(probe9)
    }

    /// The bug: a stale attempt tore down "the link", not its own — so an
    /// engine unwinding a superseded share closed the replacement's node.
    func testTeardownScopedToATokenLeavesAReplacementLinkAlone() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let first = FakeLinkServer(journal: journal)
        let stale = try await session.startLinkOnly(on: first, filterData: nil)
        await session.teardown()

        let second = FakeLinkServer(id: "srv2", journal: journal)
        let live = try await session.startLinkOnly(on: second, filterData: nil)

        // The stale attempt unwinding, late, with the token it minted.
        let closed = await session.teardown(mintedToken: stale)

        XCTAssertFalse(closed)
        let probe2 = await session.token
        XCTAssertEqual(probe2, live)
        // n2's node was never closed — one close for n1, none for n2.
        let probe3 = await journal.count(of: "node.close(n2)")
        XCTAssertEqual(probe3, 0)
    }

    /// …and the same call with the LIVE token does close it, so the scoping
    /// cannot pass by refusing to do anything.
    func testTeardownWithTheLiveTokenClosesIt() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)
        let token = try await session.startLinkOnly(on: server, filterData: nil)

        let closed = await session.teardown(mintedToken: token)

        XCTAssertTrue(closed)
        let probe16 = await session.token
        XCTAssertNil(probe16)
        let probe10 = await journal.contains("node.close(n1)")
        XCTAssertTrue(probe10)
    }

    /// The bug: the head guard returned the stored token for ANY server. Both
    /// engines publish their stopped state before the teardown task reaches
    /// this actor, so a replacement arrives here with the old link still
    /// stored — and used to be handed that token, with no server behind it,
    /// which the delayed teardown then closed underneath it.
    func testAReplacementServerIsNotHandedTheOldLinksToken() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let first = FakeLinkServer(journal: journal)
        let stale = try await session.startLinkOnly(on: first, filterData: nil)

        // No teardown in between: exactly the window where the engine has
        // published idle but the teardown task has not landed.
        let second = FakeLinkServer(id: "srv2", journal: journal)
        let minted = try await session.startLinkOnly(on: second, filterData: nil)

        XCTAssertNotEqual(minted, stale)
        // …and the replacement's server really was started, rather than the
        // call short-circuiting on the stored token.
        let started = await journal.contains("server.startGuestOnly(srv2)")
        XCTAssertTrue(started)
        // The abandoned node is closed rather than leaked.
        let closedOld = await journal.contains("node.close(n1)")
        XCTAssertTrue(closedOld)
    }

    /// …while the SAME server asking twice still gets the same link back:
    /// the idempotence is what stops a second toggle minting a second node.
    func testTheOwningServerAskingTwiceGetsTheSameLink() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)

        let first = try await session.enable(on: server)
        let second = try await session.enable(on: server)

        XCTAssertEqual(first, second)
        let secondNode = await journal.contains("node.start(n2)")
        XCTAssertFalse(secondNode)
    }

    /// The bug: a stop with no token yet scheduled no teardown at all, on the
    /// reasoning that a start unwinds itself — true of the engines'
    /// `beginShare`, false of their mid-share link toggle, which has no
    /// generation check. Passing the server invalidates the claim that
    /// server's mint holds, before any token exists.
    func testAStopWithNoTokenYetStillInvalidatesItsOwnMint() async throws {
        let journal = Journal()
        let box = NodeBox()
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in
                let node = box.next(journal: journal)
                node.tokenGate.hold()
                return node
            })
        let server = FakeLinkServer(journal: journal)

        let enable = Task { try await session.enable(on: server) }
        let found = await box.awaitNode("n1")
        let first = try XCTUnwrap(found)
        await first.tokenGate.waitUntilParked()
        // The stop the engine performs: no token to scope by, only the server.
        await session.teardown(for: server)
        first.tokenGate.release()

        do {
            _ = try await enable.value
            XCTFail("expected the superseded mint to throw")
        } catch SharerLinkError.superseded {
            // expected
        }
        let live = await session.token
        XCTAssertNil(live)
    }

    /// …and that invalidation is scoped: a stale share stopping must not
    /// invalidate the mint a REPLACEMENT share has in flight.
    func testStoppingOneShareLeavesAnotherSharesMintAlone() async throws {
        let journal = Journal()
        let box = NodeBox()
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in
                let node = box.next(journal: journal)
                node.tokenGate.hold()
                return node
            })
        let replacement = FakeLinkServer(id: "srv2", journal: journal)
        let stale = FakeLinkServer(id: "srv1", journal: journal)

        let mint = Task { try await session.startLinkOnly(on: replacement, filterData: nil) }
        let found = await box.awaitNode("n1")
        let node = try XCTUnwrap(found)
        await node.tokenGate.waitUntilParked()
        // The OTHER share's stop lands while this bootstrap is suspended.
        await session.teardown(for: stale)
        node.tokenGate.release()

        let minted = try await mint.value
        XCTAssertEqual(minted, "tc-n1")
        let live = await session.token
        XCTAssertEqual(live, minted)
    }

    /// Eviction maps a denied guest's tunnel IP back to its node key — the
    /// deny reports an IP, the tunnel wants the key.
    func testEvictLooksUpTheNodeKeyForATunnelIP() async throws {
        let journal = Journal()
        let (session, node) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)
        _ = try await session.startLinkOnly(on: server, filterData: nil)
        let made = try XCTUnwrap(node("n1"))
        made.setPeers([try Self.peer(key: "nodekey:abc", addr: "100.100.0.2")])

        await session.evict(ip: "100.100.0.2")

        XCTAssertEqual(made.evicted, ["nodekey:abc"])
        // Gone from the mirror, so a second deny for the same IP is quiet.
        let probe17 = await session.peersByIP["100.100.0.2"]
        XCTAssertNil(probe17)
    }

    /// `GuestPeer`'s memberwise init is internal to TailscaleKit, so the
    /// fixture goes through its `Codable` conformance rather than reaching
    /// into the fork to widen a type for a test's convenience.
    private static func peer(key: String, addr: String) throws -> GuestPeer {
        let json = #"{"key":"\#(key)","addr":"\#(addr)"}"#
        return try JSONDecoder().decode(GuestPeer.self, from: Data(json.utf8))
    }
}
