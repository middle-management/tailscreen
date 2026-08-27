import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

/// Viewer-side outbound TCP back-channel to the sharer — the portable
/// counterpart of the macOS client's annotation/control channel
/// (`TailscaleScreenShareClient.runAnnotationChannel`). It dials
/// `sharer:7447` over the tailnet, frames `ScreenShareMessage`s outbound
/// (annotation ops, remote-control request / release, input events), and
/// drains the sharer's fan-out inbound (relayed strokes + control grant /
/// revoke), reconnecting with capped backoff if the connection drops
/// mid-session.
///
/// This closes the porting plan's named "last gap before shippable": the
/// UDP path is receive-only, so without this a Linux viewer could watch but
/// never draw, request control, or send input. The wire format is identical
/// to the mac client's — `ScreenShareMessage.encode()` / `Parser` — so a
/// Linux viewer's strokes land on a mac sharer's overlay unchanged.
///
/// **Live tsnet is local-only** (the repo's documented constraint), so this
/// is compile-gated by CI; a live run needs a real Mac sharer + tailnet.
/// The framing/parse logic it drives is the same CI-tested code the sharer
/// uses (`ScreenShareProtocolTests`, `WireByteRegistryTests`).
public actor ViewerBackChannel {
    /// Inbound-message handlers. Set once before `start`; invoked on the
    /// back-channel's own task. `@Sendable` because the host (the GTK app)
    /// marshals onto its UI thread inside these closures.
    public struct Handlers: Sendable {
        /// A stroke the sharer painted, or another viewer's stroke the sharer
        /// relayed to us.
        public var onAnnotation: (@Sendable (AnnotationOp) -> Void)?
        /// The sharer granted this viewer remote control.
        public var onControlGranted: (@Sendable () -> Void)?
        /// The sharer revoked (or declined) control, with a short reason.
        public var onControlRevoked: (@Sendable (String) -> Void)?

        public init(
            onAnnotation: (@Sendable (AnnotationOp) -> Void)? = nil,
            onControlGranted: (@Sendable () -> Void)? = nil,
            onControlRevoked: (@Sendable (String) -> Void)? = nil
        ) {
            self.onAnnotation = onAnnotation
            self.onControlGranted = onControlGranted
            self.onControlRevoked = onControlRevoked
        }
    }

    /// Which tunnel the channel dials through. An enum rather than an
    /// injected dial closure so nothing non-Sendable crosses the actor
    /// boundary — both payloads already do (the handle crossed the old
    /// init; `GuestClientNode` is an actor).
    private enum Wire {
        /// The tailnet: dial `target` ("host:port") over the tsnet node.
        case tailnet(TailscaleHandle, target: String)
        /// A share-by-token tunnel: dial `port` on the sharer's guest node.
        case guest(GuestClientNode, port: UInt16)
    }

    private let wire: Wire
    /// Human-readable name of the dial target, for the log lines.
    private let target: String
    private let logger: LogSink
    private let handlers: Handlers

    private var connection: (any FramedControlChannel)?
    private var runLoop: Task<Void, Never>?
    private var stopped = false

    /// - Parameters:
    ///   - tailscale: the live node's handle (from `node.tailscale`).
    ///   - host: the sharer's tailnet hostname or IP.
    ///   - port: the sharer's control port (7447).
    ///   - handlers: inbound-message callbacks.
    ///   - logger: where dial/reconnect diagnostics go.
    public init(
        tailscale: TailscaleHandle,
        host: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        handlers: Handlers = Handlers(),
        logger: LogSink
    ) {
        let target = TsnetTransport.formatAddr(host: host, port: port)
        self.wire = .tailnet(tailscale, target: target)
        self.target = target
        self.handlers = handlers
        self.logger = logger
    }

    /// The guest twin: same channel, dialed through the share-by-token
    /// tunnel (`GuestClientNode.dial`) instead of the tailnet.
    public init(
        guest: GuestClientNode,
        port: UInt16 = NetworkConfig.tailscreenPort,
        handlers: Handlers = Handlers(),
        logger: LogSink
    ) {
        self.wire = .guest(guest, port: port)
        self.target = "guest tunnel :\(port)"
        self.handlers = handlers
        self.logger = logger
    }

    /// Begin dialing + draining in the background. Idempotent.
    public func start() {
        guard runLoop == nil, !stopped else { return }
        runLoop = Task { await self.runChannel() }
    }

    /// Tear down: cancel the loop and close the live connection. After this
    /// the channel is dead (a fresh `ViewerBackChannel` is needed to resume).
    public func stop() async {
        stopped = true
        runLoop?.cancel()
        runLoop = nil
        if let connection {
            await connection.close()
            self.connection = nil
        }
    }

    // MARK: Outbound

    /// Send an annotation op to the sharer. Best-effort; drops silently if the
    /// channel isn't currently connected (a reconnect is already in flight).
    public func sendAnnotation(_ op: AnnotationOp) async {
        await send(.annotation(op), label: "annotation")
    }

    /// Ask the sharer for remote control (`.controlRequest`). The sharer only
    /// surfaces this if it advertised `ScreenShareCaps.remoteControl`; the host
    /// UI gates the affordance on that, matching the mac viewer.
    public func requestControl() async {
        await send(.controlRequest, label: "controlRequest")
    }

    /// Send one input event for injection on the sharer (`.inputEvent`). Rides
    /// the same reliable, ordered TCP channel as annotations so a `mouseDown`
    /// never arrives without its `mouseUp`.
    ///
    /// ORDERING CONTRACT (for the future input-capture wiring): the actor
    /// preserves send order only for calls that reach it in order. Do NOT
    /// dispatch one detached `Task { await sendInputEvent(…) }` per GTK event —
    /// two independently-spawned tasks can enter the actor in either order and
    /// invert a down/up pair. Feed events from a single serial producer (or an
    /// `AsyncStream` drained by one consumer, like `TsnetTransport`'s outbound
    /// UDP queue).
    public func sendInputEvent(_ event: InputEvent) async {
        await send(.inputEvent(event), label: "inputEvent")
    }

    /// Tell the sharer we're done controlling (`.controlReleased`) so it
    /// revokes the grant and the UIs release in step.
    public func releaseControl() async {
        await send(.controlReleased, label: "controlReleased")
    }

    /// Serialize on the actor: `OutgoingConnection.send` is synchronous, so a
    /// single actor-isolated call site keeps writes ordered without a separate
    /// writer type (the mac client needs `ConnectionWriter` only because it
    /// sends from multiple isolation domains).
    private func send(_ message: ScreenShareMessage, label: String) async {
        guard let connection else { return }
        do {
            try await connection.send(message.encode())
        } catch {
            logger.log("[backchannel] send \(label) failed: \(error)")
        }
    }

    // MARK: Inbound + reconnect

    /// A connection that stays up at least this long before dropping is treated
    /// as "healthy" and resets the backoff; a shorter-lived one keeps escalating
    /// it (see `runChannel`).
    private static let minHealthyConnNs: UInt64 = 1_000_000_000  // 1 s

    /// Own the connection for the whole session: dial, drain inbound, and
    /// reconnect with capped backoff on a mid-session drop — mirroring
    /// `TailscaleScreenShareClient.runAnnotationChannel`, with one hardening:
    /// the backoff resets only after a *healthy* connection, so an
    /// accept-then-immediately-EOF sharer can't spin dial→EOF→dial with no
    /// delay (the mac client resets on every successful dial).
    private func runChannel() async {
        var reconnectAttempts = 0
        while !Task.isCancelled && !stopped {
            guard let conn = await dial() else {
                if Task.isCancelled || stopped { break }
                reconnectAttempts += 1
                // Same 250 ms → 5 s capped doubling the UDP receive loops use.
                try? await Task.sleep(
                    nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: reconnectAttempts))
                continue
            }
            connection = conn
            let upSinceNs = DispatchTime.now().uptimeNanoseconds
            await receiveLoop(over: conn)  // returns on drop/EOF/cancel
            connection = nil
            if Task.isCancelled || stopped { break }
            await conn.close()
            let aliveNs = DispatchTime.now().uptimeNanoseconds - upSinceNs
            if aliveNs < Self.minHealthyConnNs {
                // Barely up — escalate the backoff before redialing.
                reconnectAttempts += 1
                try? await Task.sleep(
                    nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: reconnectAttempts))
            } else {
                reconnectAttempts = 0
            }
            logger.log("[backchannel] dropped — reconnecting")
        }
        if let connection {
            await connection.close()
            self.connection = nil
        }
    }

    /// Dial the sharer once, over whichever tunnel this channel rides.
    /// Returns nil (logged) on failure.
    private func dial() async -> (any FramedControlChannel)? {
        do {
            switch wire {
            case .tailnet(let tailscale, let dialTarget):
                let conn = try await OutgoingConnection(
                    tailscale: tailscale, to: dialTarget, proto: .tcp, logger: logger)
                try await conn.connect()
                logger.log("[backchannel] connected to \(target)")
                return conn
            case .guest(let guest, let port):
                let conn = try await guest.dial(port: port)
                logger.log("[backchannel] connected to \(target)")
                return conn
            }
        } catch {
            logger.log("[backchannel] dial \(target) failed: \(error)")
            return nil
        }
    }

    /// Drain framed messages until the connection closes or the task is
    /// cancelled. Only annotation + control-grant/revoke are meaningful to a
    /// viewer; everything else (sharer→sharer or viewer→sharer types the
    /// sharer would never send us) is dropped.
    private func receiveLoop(over connection: any FramedControlChannel) async {
        var parser = ScreenShareMessageParser()
        while !Task.isCancelled && !stopped {
            let startNs = DispatchTime.now().uptimeNanoseconds
            do {
                let chunk = try await connection.receive(maximumLength: 16 * 1024, timeout: 5_000)
                if chunk.isEmpty { return }  // EOF (defensive — see the catch below)
                parser.append(chunk)
                while let message = parser.next() {
                    switch message {
                    case .annotation(let op):
                        handlers.onAnnotation?(op)
                    case .controlGranted:
                        handlers.onControlGranted?()
                    case .controlRevoked(let reason):
                        handlers.onControlRevoked?(reason)
                    default:
                        break
                    }
                }
                // A bogus oversized frame poisons the parser (can't resync) —
                // drop the connection; the reconnect loop redials.
                if parser.isCorrupt {
                    logger.log("[backchannel] oversized frame — closing")
                    return
                }
            } catch TailscaleError.readFailed {
                if Task.isCancelled || stopped { return }
                // `OutgoingConnection.receive` collapses THREE cases into
                // `readFailed`: a benign poll timeout, peer EOF (read → 0), and
                // a hard error (read → -1). Only the first should keep looping —
                // an EOF/RST fd polls readable *instantly* forever, so a blind
                // `continue` here busy-spins a core and never reaches the
                // reconnect path. Distinguish by wall time (the shared
                // `ReceiveLoopPolicy` rule the other loops use): a `readFailed`
                // returning far faster than the 5 s poll interval is a dead
                // socket — return so `runChannel` redials; a full-interval one
                // is a real timeout — keep reading.
                let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startNs
                if ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: elapsedNs) {
                    return
                }
                continue
            } catch {
                return
            }
        }
    }
}
