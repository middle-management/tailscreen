import Foundation
import TailscaleKit
import os

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
final class TailscreenControlListener: @unchecked Sendable {
    private let port: UInt16
    private let logger: TSLogger
    private var listener: Listener?
    private var isRunning = false
    private let connections = OSAllocatedUnfairLock<[UUID: IncomingConnection]>(initialState: [:])

    /// Fires for every `.annotation` message. Argument is the op plus the
    /// `UUID` of the connection it arrived on (so the sharer can avoid
    /// echoing the op back to its origin).
    var onAnnotation: ((AnnotationOp, UUID) -> Void)?

    /// Fires for every `.requestToShare` message. Argument is the
    /// requesting peer's friendly hostname (as sent in the payload).
    var onRequestToShare: ((String) -> Void)?

    /// Fires when an accepted TCP connection closes. Argument is the
    /// connection's stable `UUID`. Used by the share server to retire
    /// per-viewer annotation state.
    var onConnectionClosed: ((UUID) -> Void)?

    init(port: UInt16 = NetworkConfig.tailscreenPort) {
        self.port = port
        self.logger = TSLogger()
    }

    /// Bind the listener on `node`'s tailnet interface and start the accept
    /// loop. Idempotent — calling twice is a no-op.
    func start(node: TailscaleNode) async throws {
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
    func stop() async {
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
    func send(_ message: ScreenShareMessage, to connectionID: UUID) async {
        guard let conn = connections.withLock({ $0[connectionID] }) else { return }
        try? await conn.send(message.encode())
    }

    /// Send a framed message to every connection except (optionally) one.
    /// Used by the share server's annotation fan-out so viewer A's stroke
    /// reaches viewer B without bouncing back to A.
    func broadcast(_ message: ScreenShareMessage, excluding: UUID? = nil) async {
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
            } catch {
                // accept-timeout or transient — loop and retry
                continue
            }
        }
    }

    private func receiveLoop(connection: IncomingConnection, id: UUID) async {
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
                    dispatch(message, connectionID: id)
                }
            } catch TailscaleError.readFailed {
                if !isRunning { return }
                continue  // poll timeout — keep reading
            } catch {
                return
            }
        }
    }

    private func dispatch(_ message: ScreenShareMessage, connectionID: UUID) {
        switch message {
        case .annotation(let op):
            onAnnotation?(op, connectionID)
        case .requestToShare(let from):
            onRequestToShare?(from)
        }
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) {
        if message.hasPrefix("Listening for ") { return }
        print("[ControlListener] \(message)")
    }
}
