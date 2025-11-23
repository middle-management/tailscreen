import Foundation
import CoreVideo
import os
import TailscaleKit

/// Screen-share server that uses TailscaleKit as the transport.
///
/// Each accepted client gets its own ``ClientSender``; a slow viewer can't stall
/// the capture pipeline or other viewers. When a viewer attaches, the server
/// immediately pushes cached SPS/PPS (if any) and asks the encoder for a fresh
/// IDR so the new viewer starts on a keyframe.
final class TailscaleScreenShareServer: @unchecked Sendable {
    private let port: UInt16
    var node: TailscaleNode?
    private var listener: Listener?
    private var encoder: VideoEncoder?
    private var screenCapture: ScreenCapture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    private var isRunning = false
    private let logger: TSLogger

    private let clients = OSAllocatedUnfairLock<[UUID: ClientSender]>(initialState: [:])

    init(port: UInt16 = 7447) {
        self.port = port
        self.logger = TSLogger()
    }

    func start(hostname: String = "cuple-server", authKey: String? = nil, path: String? = nil) async throws {
        guard !isRunning else { return }

        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

            // Check for instance override
            if let instance = ProcessInfo.processInfo.environment["CUPLE_INSTANCE"] {
                return appSupport.appendingPathComponent("Cuple-\(instance)/tailscale").path
            }

            return appSupport.appendingPathComponent("Cuple/tailscale").path
        }()
        try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

        print("Starting Tailscale server…")

        let config = Configuration(
            hostName: hostname,
            path: statePath,
            authKey: authKey,
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        let node = try TailscaleNode(config: config, logger: logger)
        self.node = node
        try await node.up()

        let ips = try await node.addrs()
        print("Tailscale connected — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        let listener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(port)",
            logger: logger
        )
        self.listener = listener
        print("Listening on Tailscale port \(port)")

        isRunning = true

        Task { [weak self] in
            await self?.acceptConnections()
        }

        screenCapture = ScreenCapture()
        try? await screenCapture?.start()

        await MainActor.run {
            self.screenCapture?.onFrameCaptured = { [weak self] pixelBuffer in
                self?.handleCapturedFrame(pixelBuffer)
            }
        }
    }

    private func acceptConnections() async {
        guard let listener = listener else { return }
        while isRunning {
            do {
                let connection = try await listener.accept(timeout: 10.0)
                await attach(connection)
            } catch {
                continue  // timeout — just keep polling
            }
        }
    }

    private func attach(_ connection: IncomingConnection) async {
        let id = UUID()
        let sender = ClientSender(id: id, connection: connection) { [weak self] clientID in
            self?.removeClient(clientID)
        }

        clients.withLock { $0[id] = sender }

        let addr = await connection.remoteAddress ?? "unknown"
        print("New viewer: \(addr) [\(id)]")

        if let cached = encoder?.cachedParameterSets {
            sender.enqueue(.parameterSets(sps: cached.sps, pps: cached.pps), priority: .critical)
        }
        encoder?.requestKeyframe()

        sender.start()
    }

    private func removeClient(_ id: UUID) {
        let removed = clients.withLock { $0.removeValue(forKey: id) }
        if removed != nil {
            print("Viewer disconnected [\(id)]")
        }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }
        let hasClients = clients.withLock { !$0.isEmpty }
        guard hasClients else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if encoder == nil || width != lastWidth || height != lastHeight {
            encoder?.shutdown()
            let newEncoder = VideoEncoder()
            do {
                try newEncoder.setup(width: width, height: height, fps: 60)
                lastWidth = width
                lastHeight = height

                newEncoder.onParameterSets = { [weak self] sps, pps in
                    self?.broadcast(.parameterSets(sps: sps, pps: pps), priority: .critical)
                }
                newEncoder.onEncodedData = { [weak self] data, isKeyframe in
                    self?.broadcast(.frame(data: data, isKeyframe: isKeyframe),
                                    priority: isKeyframe ? .critical : .droppable)
                }
                encoder = newEncoder
            } catch {
                print("VideoEncoder setup failed: \(error)")
                return
            }
        }

        encoder?.encode(pixelBuffer: pixelBuffer)
    }

    private func broadcast(_ message: ScreenShareMessage, priority: ClientSender.Priority) {
        let senders = clients.withLock { Array($0.values) }
        for sender in senders {
            sender.enqueue(message, priority: priority)
        }
    }

    func getIPAddresses() async throws -> (ip4: String?, ip6: String?) {
        guard let node = node else { throw TailscaleError.badInterfaceHandle }
        return try await node.addrs()
    }

    func stop() async {
        isRunning = false

        // Stop capture first so no more frames arrive after the encoder is torn down.
        await screenCapture?.stop()
        screenCapture = nil

        encoder?.shutdown()
        encoder = nil

        let all = clients.withLock { state -> [ClientSender] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for sender in all {
            await sender.close()
        }

        await listener?.close()
        listener = nil

        if let node = node {
            try? await node.close()
            self.node = nil
        }

        print("Server stopped")
    }

    deinit {
        isRunning = false
    }
}

/// One per viewer. Owns a background task that drains a bounded send queue.
/// Critical messages (parameter sets, keyframes) always queue; droppable frames
/// are discarded when the queue is already over its byte cap.
fileprivate final class ClientSender: @unchecked Sendable {
    enum Priority {
        case critical
        case droppable
    }

    let id: UUID
    private let connection: IncomingConnection
    private let onClose: (UUID) -> Void

    private struct State {
        var queue: [Data] = []
        var queuedBytes = 0
        var closed = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Viewer backlog cap. ~1s of 60Mbps = 7.5 MB; 12 MB leaves slack.
    private let backlogCapBytes = 12 * 1024 * 1024
    private var task: Task<Void, Never>?

    init(id: UUID, connection: IncomingConnection, onClose: @escaping (UUID) -> Void) {
        self.id = id
        self.connection = connection
        self.onClose = onClose
    }

    func start() {
        task = Task.detached { [weak self] in
            await self?.drain()
        }
    }

    func enqueue(_ message: ScreenShareMessage, priority: Priority) {
        let data = message.encode()

        let waiterToResume: CheckedContinuation<Void, Never>? = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if s.closed { return nil }
            if priority == .droppable && s.queuedBytes + data.count > backlogCapBytes {
                return nil
            }
            s.queue.append(data)
            s.queuedBytes += data.count
            let w = s.waiter
            s.waiter = nil
            return w
        }
        waiterToResume?.resume()
    }

    private enum PopResult {
        case closed
        case item(Data)
        case empty
    }

    private func drain() async {
        while true {
            guard let data = await nextItem() else { return }
            do {
                try await connection.send(data)
            } catch {
                print("ClientSender[\(id)] send failed: \(error)")
                await close()
                return
            }
        }
    }

    private func nextItem() async -> Data? {
        while true {
            let popped: PopResult = state.withLock { s -> PopResult in
                if s.closed { return .closed }
                if !s.queue.isEmpty {
                    let data = s.queue.removeFirst()
                    s.queuedBytes -= data.count
                    return .item(data)
                }
                return .empty
            }

            switch popped {
            case .closed: return nil
            case .item(let d): return d
            case .empty: break
            }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let shouldResumeImmediately = state.withLock { s -> Bool in
                    if s.closed || !s.queue.isEmpty { return true }
                    s.waiter = cont
                    return false
                }
                if shouldResumeImmediately { cont.resume() }
            }
        }
    }

    func close() async {
        let transition: (didClose: Bool, waiter: CheckedContinuation<Void, Never>?) = state.withLock { s in
            if s.closed { return (false, nil) }
            s.closed = true
            s.queue.removeAll()
            s.queuedBytes = 0
            let w = s.waiter
            s.waiter = nil
            return (true, w)
        }
        guard transition.didClose else { return }

        transition.waiter?.resume()
        await connection.close()
        task?.cancel()
        onClose(id)
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) { print("[Tailscale] \(message)") }
}
