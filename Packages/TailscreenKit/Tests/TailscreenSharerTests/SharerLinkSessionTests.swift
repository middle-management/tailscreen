import Foundation
import TailscaleKit
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// The share-by-token link lifecycle, driven through a fake guest node.
///
/// This suite exists because a live `GuestServerNode` (whose `start()` is a
/// relay handshake) gives nothing to drive concurrent-interleaving cases
/// with. Each case holds the bootstrap open at a suspension point the live
/// node also has, runs a stop (or a second share) while it's parked, and
/// asserts what survived.
///
/// Mutation-checked: eleven deliberate breaks in `SharerLinkSession` each go
/// red here (early-clearing `close()`, unclaimed mints, ignored
/// `teardown(mintedToken:)`, leaked sockets/nodes/channels on refusal, a
/// disable ordering bug, lost fail-soft `catch`es). If you add a rule to
/// `SharerLinkSession`, break it on purpose before trusting the test for it.
final class SharerLinkSessionTests: XCTestCase {

    /// Builds a session with fake nodes, plus a way to reach each node by
    /// the id its token carries.
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

        /// Waits until the session's call has created its node.
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
        // The guest node IS the transport, so it must be up and bound before
        // the server can take it as its only socket.
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

    /// A link whose TCP (control) bind failed still carries video and voice
    /// — losing annotations/remote-control is not losing the share.
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

    /// `enable` has its OWN fail-soft `do`/`catch` around the control route,
    /// separate from `startLinkOnly`'s — the case above alone doesn't cover it.
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

    /// A refused control attach is the session's to clean up — the server
    /// kept no reference, so nothing else stops that channel.
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

    /// A throw after `startGuestOnly` marks the server running must still
    /// unwind all-or-nothing: node closes AND server stops.
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

    /// Detach before close, so each guest gets HELLO_DENY + SERVER_BYE
    /// through the still-open socket instead of timing out.
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

    /// The bug: `close()` awaited the node's close before clearing `token`,
    /// so a `startLinkOnly` landing there could inherit the dying link's
    /// token with no node behind it.
    func testAStartDuringATeardownDoesNotInheritTheDyingToken() async throws {
        let journal = Journal()
        let (session, node) = makeSession(journal: journal)
        let server = FakeLinkServer(journal: journal)
        _ = try await session.startLinkOnly(on: server, filterData: nil)

        let first = try XCTUnwrap(node("n1"))
        first.closeGate.hold()
        let teardown = Task { await session.teardown() }
        await first.closeGate.waitUntilParked()

        let replacement = FakeLinkServer(id: "srv2", journal: journal)
        let minted = try await session.startLinkOnly(on: replacement, filterData: nil)

        first.closeGate.release()
        await teardown.value

        XCTAssertEqual(minted, "tc-n2")
        let probe7 = await journal.contains("server.startGuestOnly(srv2)")
        XCTAssertTrue(probe7)
    }

    /// The bug: `guestServer` is written last, so a stop landing
    /// mid-bootstrap found nothing to tear down, and the mint then
    /// published a token and a live node onto an idle app.
    func testAStopDuringABootstrapSupersedesTheMint() async throws {
        let journal = Journal()
        let box = NodeBox()
        // Armed at creation — a hold issued after start is a race the test
        // loses by hanging.
        let session = SharerLinkSession(
            logger: nil,
            makeNode: { _, _ in
                let node = box.next(journal: journal)
                node.tokenGate.hold()
                return node
            })
        let server = FakeLinkServer(journal: journal)

        let start = Task { try await session.startLinkOnly(on: server, filterData: nil) }
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
        let probe14 = await session.token
        XCTAssertNil(probe14)
        let probe8 = await journal.contains("node.close(n1)")
        XCTAssertTrue(probe8)
    }

    /// Same rule, mid-share: a stop after `enable` attached its listener
    /// used to publish a token onto an idle app.
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

    /// The bug: a stale attempt tore down "the link", not its own, so
    /// unwinding a superseded share closed the replacement's node.
    func testTeardownScopedToATokenLeavesAReplacementLinkAlone() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let first = FakeLinkServer(journal: journal)
        let stale = try await session.startLinkOnly(on: first, filterData: nil)
        await session.teardown()

        let second = FakeLinkServer(id: "srv2", journal: journal)
        let live = try await session.startLinkOnly(on: second, filterData: nil)

        let closed = await session.teardown(mintedToken: stale)

        XCTAssertFalse(closed)
        let probe2 = await session.token
        XCTAssertEqual(probe2, live)
        let probe3 = await journal.count(of: "node.close(n2)")
        XCTAssertEqual(probe3, 0)
    }

    /// The same call with the live token does close it, so the scoping
    /// can't pass by refusing to do anything.
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

    /// The bug: the head guard returned the stored token for ANY server —
    /// a replacement arriving before the stale teardown task landed used to
    /// be handed the old link's token, then had it closed underneath it.
    func testAReplacementServerIsNotHandedTheOldLinksToken() async throws {
        let journal = Journal()
        let (session, _) = makeSession(journal: journal)
        let first = FakeLinkServer(journal: journal)
        let stale = try await session.startLinkOnly(on: first, filterData: nil)

        let second = FakeLinkServer(id: "srv2", journal: journal)
        let minted = try await session.startLinkOnly(on: second, filterData: nil)

        XCTAssertNotEqual(minted, stale)
        let started = await journal.contains("server.startGuestOnly(srv2)")
        XCTAssertTrue(started)
        let closedOld = await journal.contains("node.close(n1)")
        XCTAssertTrue(closedOld)
    }

    /// The same server asking twice gets the same link back — idempotence
    /// stops a second toggle minting a second node.
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

    /// The bug: a stop with no token yet scheduled no teardown at all,
    /// reasoning a start unwinds itself — true of `beginShare`, false of a
    /// mid-share link toggle with no generation check.
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

    /// That invalidation is scoped: a stale share stopping must not
    /// invalidate a replacement share's mint in flight.
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
