import Foundation
import Synchronization
import TailscaleKit
import TailscreenProtocol

/// Long-lived TCP listener on port 7447 that demultiplexes the framed
/// control protocol (`ScreenShareMessage`) across multiple consumers.
///
/// The listener binds when the local tsnet node first comes up and stays
/// alive for the process lifetime. Two independent message types ride the
/// same wire:
///
///   - `.annotation` — viewer→sharer drawing ops. Only meaningful while
///     this process is actively sharing; `TailscaleScreenShareServer`
///     registers / clears its handler around the share's lifetime.
///   - `.requestToShare` — peer-to-peer "please share with me" prompts.
///     Has to work whether or not we're sharing, so the handler is
///     installed once at startup by `AppState`.
///
/// Each accepted TCP connection gets a stable `UUID` so handlers can fan
/// outgoing messages back to specific viewers (annotation broadcasts) or
/// detect connection close (the receive loop fires
/// `onConnectionClosed` so the sharer can clean up per-viewer
/// annotation state).
public final class TailscreenControlListener: @unchecked Sendable {
    private let port: UInt16
    private let logger: PrintLogSink
    private var listener: Listener?
    private var isRunning = false
    // `Mutex` (not `OSAllocatedUnfairLock`) keeps this file portable.
    private let connections = Mutex<[UUID: IncomingConnection]>([:])

    /// Fires for every `.annotation` message. Arguments are the op, the
    /// `UUID` of the connection it arrived on (so the sharer can avoid
    /// echoing the op back to its origin), and the connection's remote
    /// tailnet address (`ip:port`, nil if libtailscale couldn't report it)
    /// so the sharer can gate annotations to *admitted* viewers only — the
    /// TCP back-channel otherwise accepts ops from any peer that can dial
    /// port 7447, including pending/denied ones.
    public var onAnnotation: ((AnnotationOp, UUID, String?) -> Void)?

    /// Fires for every `.requestToShare` message. Arguments are the
    /// requesting peer's friendly hostname (as sent in the payload), the
    /// `UUID` of the TCP connection it arrived on (so the handler can send
    /// the eventual `.shareResponse` back on the *same* connection — no
    /// dial-back, so the answer provably reaches the actual requester), and
    /// the connection's remote tailnet address (`ip:port`, nil if
    /// unreported) so the handler can dedupe by source identity rather than
    /// the spoofable wire-claimed hostname.
    public var onRequestToShare: ((String, UUID, String?) -> Void)?

    /// Fires for every `.controlRequest` message (viewer→sharer "please grant
    /// me remote control"). Arguments are the connection's stable `UUID` (the
    /// handle the grant + input-event gate key on) and its remote tailnet
    /// address (`ip:port`, nil if unreported) so the sharer can confirm the
    /// requester is an admitted viewer and label the request row.
    public var onControlRequest: ((UUID, String?) -> Void)?

    /// Fires for every `.inputEvent` message (viewer→sharer mouse/scroll/key).
    /// Arguments are the event, the connection's `UUID` (checked against the
    /// live grant — events from any non-grantee connection are dropped
    /// server-side), and the remote address. Fires off the connection's
    /// receive task, which is single-threaded per connection so per-connection
    /// event order is preserved.
    public var onInputEvent: ((InputEvent, UUID, String?) -> Void)?

    /// Fires for a `.controlReleased` message (grantee viewer→sharer "I'm
    /// done controlling"). Argument is the connection's `UUID`; the sharer
    /// revokes the grant if this connection holds it, so the sharer UI and
    /// the gate release in lockstep with the viewer leaving control mode.
    public var onControlReleased: ((UUID) -> Void)?

    /// Fires for every `.metadataRequest` message (peer→peer "describe
    /// yourself" — drives the requester's sharing-status filter). Argument
    /// is the connection's stable `UUID`; the handler answers with
    /// `.metadataResponse` on the SAME connection via `send(_:to:)` (no
    /// dial-back, like `.shareResponse`).
    public var onMetadataRequest: ((UUID) -> Void)?

    /// Fires when an accepted TCP connection closes. Argument is the
    /// connection's stable `UUID`. Used by the share server to retire
    /// per-viewer annotation state.
    public var onConnectionClosed: ((UUID) -> Void)?

    public init(port: UInt16 = NetworkConfig.tailscreenPort) {
        self.port = port
        self.logger = PrintLogSink(prefix: "ControlListener", dropListeningNoise: true)
    }

    /// Bind the listener on `node`'s tailnet interface and start the accept
    /// loop. Idempotent — calling twice is a no-op.
    public func start(node: TailscaleNode) async throws {
        guard !isRunning else { return }
        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        let l = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(port)",
            logger: logger
        )
        self.listener = l
        self.isRunning = true
        logger.log("Control listener bound on :\(port)")
        Task { [weak self] in await self?.acceptLoop() }
    }

    /// Close the listener and any in-flight connections. After `stop()`,
    /// `start(node:)` can be called again with a fresh node.
    public func stop() async {
        isRunning = false
        let conns = connections.withLock { state -> [IncomingConnection] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        await withTaskGroup(of: Void.self) { group in
            for conn in conns { group.addTask { await conn.close() } }
        }
        await listener?.close()
        listener = nil
        logger.log("Control listener stopped")
    }

    /// Send a framed message back to a specific connection (e.g. relaying
    /// an annotation to a viewer). Best-effort; errors are swallowed
    /// because the receive task on the same connection will tear down a
    /// dead socket on its own.
    public func send(_ message: ScreenShareMessage, to connectionID: UUID) async {
        guard let conn = connections.withLock({ $0[connectionID] }) else { return }
        try? await conn.send(message.encode())
    }

    /// Close and deregister a single accepted connection by ID. Used by the
    /// share server to sever an expelled viewer's annotation back-channel so
    /// a blocked peer loses it along with its video. The connection's own
    /// receive loop then unwinds and fires `onConnectionClosed`, retiring the
    /// peer's tracked strokes on every canvas.
    public func close(connectionID: UUID) async {
        guard let conn = connections.withLock({ $0.removeValue(forKey: connectionID) }) else { return }
        await conn.close()
    }

    /// Send a framed message to every connection except (optionally) one.
    /// Used by the share server's annotation fan-out so viewer A's stroke
    /// reaches viewer B without bouncing back to A.
    public func broadcast(_ message: ScreenShareMessage, excluding: UUID? = nil) async {
        let data = message.encode()
        let conns = connections.withLock { state -> [IncomingConnection] in
            state.compactMap { (id, conn) in id == excluding ? nil : conn }
        }
        guard !conns.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for conn in conns {
                group.addTask {
                    try? await conn.send(data)
                }
            }
        }
    }

    private func acceptLoop() async {
        guard let listener else { return }
        while isRunning {
            do {
                let conn = try await listener.accept(timeout: 1.0)
                let id = UUID()
                connections.withLock { $0[id] = conn }
                Task { [weak self] in await self?.receiveLoop(connection: conn, id: id) }
            } catch TailscaleError.readFailed {
                // Plain poll timeout (see Listener.swift) — listener is
                // still healthy, loop and retry.
                continue
            } catch {
                // Non-timeout errors mean the listener closed itself
                // (Listener.swift closes the fd on any non-timeout poll
                // failure), so we can't recover by retrying — log loudly
                // and break instead of tight-looping on EBADF.
                logger.log("acceptLoop fatal: \(error). Listener stopped.")
                isRunning = false
                return
            }
        }
    }

    private func receiveLoop(connection: IncomingConnection, id: UUID) async {
        // Capture the peer address once: it's constant for the connection's
        // lifetime, and `remoteAddress` is actor-isolated so it can only be
        // read with `await` — doing it per message would needlessly hop the
        // actor on every frame.
        let peerAddress = await connection.remoteAddress
        defer {
            connections.withLock { _ = $0.removeValue(forKey: id) }
            onConnectionClosed?(id)
            Task { await connection.close() }
        }
        var parser = ScreenShareMessageParser()
        while isRunning {
            do {
                let chunk = try await connection.receive(maximumLength: 16 * 1024, timeout: 5_000)
                if chunk.isEmpty { return }  // EOF
                parser.append(chunk)
                while let message = parser.next() {
                    dispatch(message, connectionID: id, peerAddress: peerAddress)
                }
                // A peer that framed an oversized (bogus) length poisons the
                // parser; the stream can't resync, so drop the connection.
                if parser.isCorrupt {
                    logger.log("Control connection sent an oversized frame — closing")
                    return
                }
            } catch TailscaleError.readFailed {
                if !isRunning { return }
                continue  // poll timeout — keep reading
            } catch {
                return
            }
        }
    }

    private func dispatch(_ message: ScreenShareMessage, connectionID: UUID, peerAddress: String?) {
        switch message {
        case .annotation(let op):
            onAnnotation?(op, connectionID, peerAddress)
        case .requestToShare(let from):
            onRequestToShare?(from, connectionID, peerAddress)
        case .controlRequest:
            onControlRequest?(connectionID, peerAddress)
        case .inputEvent(let event):
            onInputEvent?(event, connectionID, peerAddress)
        case .controlReleased:
            onControlReleased?(connectionID)
        case .metadataRequest:
            onMetadataRequest?(connectionID)
        case .shareResponse, .controlGranted, .controlRevoked, .metadataResponse:
            // `.shareResponse` / `.metadataResponse` ride the requester's own
            // outgoing connection, read inline (see
            // `TailscreenMetadataService.awaitShareResponse` /
            // `TailscreenMetadataClient.fetchMetadata`).
            // `.controlGranted` / `.controlRevoked` are sharer→viewer only —
            // a viewer sending them to us is confused or malicious; drop.
            break
        }
    }
}
