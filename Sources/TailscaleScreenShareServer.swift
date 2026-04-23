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
    private var frameCounter = 0
    private var broadcastCounter = 0
    private let logger: TSLogger

    private let clients = OSAllocatedUnfairLock<[UUID: ClientSender]>(initialState: [:])

    /// Fires when the underlying ScreenCaptureKit stream ends on its own —
    /// user clicked "Stop Screen Recording" in the menubar, display changed,
    /// or the stream hit an error. AppState observes this to flip the
    /// `isSharing` flag and tear the server down.
    var onCaptureStopped: ((Error?) -> Void)?

    init(port: UInt16 = 7447) {
        self.port = port
        self.logger = TSLogger()
    }

    func start(hostname: String = "cuple-server", authKey: String? = nil, path: String? = nil) async throws {
        guard !isRunning else { return }

        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Cuple/tailscale\(CupleInstance.stateSuffix)").path
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

        let capture = ScreenCapture()
        // Wire the callback BEFORE starting so we don't drop the first few
        // frames while the assignment hops over to MainActor.
        capture.onFrameCaptured = { [weak self] pixelBuffer in
            self?.handleCapturedFrame(pixelBuffer)
        }
        capture.onStreamStopped = { [weak self] error in
            self?.onCaptureStopped?(error)
        }
        screenCapture = capture

        do {
            try await capture.start()
            print("ScreenCapture started")
        } catch {
            // Surface the error instead of silently swallowing it. Most common
            // cause on first run: macOS Screen Recording permission missing.
            print("ERROR: ScreenCapture failed to start: \(error)")
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
        frameCounter += 1
        if frameCounter == 1 || frameCounter % 60 == 0 {
            let clientCount = clients.withLock { $0.count }
            print("ScreenCapture: frame #\(frameCounter), \(clientCount) viewer(s)")
        }
        let hasClients = clients.withLock { !$0.isEmpty }
        guard hasClients else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if encoder == nil || width != lastWidth || height != lastHeight {
            encoder?.shutdown()
            let newEncoder = VideoEncoder()
            do {
                try newEncoder.setup(width: width, height: height, fps: 60)
                print("VideoEncoder setup: \(width)x\(height) @ 60fps")
                lastWidth = width
                lastHeight = height

                newEncoder.onParameterSets = { [weak self] sps, pps in
                    print("VideoEncoder emitted SPS/PPS (sps=\(sps.count)B pps=\(pps.count)B)")
                    self?.broadcast(.parameterSets(sps: sps, pps: pps), priority: .critical)
                }
                newEncoder.onEncodedData = { [weak self] data, isKeyframe in
                    let ts = DispatchTime.now().uptimeNanoseconds
                    self?.broadcast(.frame(data: data, isKeyframe: isKeyframe, timestampNs: ts),
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
        broadcastCounter += 1
        if broadcastCounter == 1 || broadcastCounter % 60 == 0 {
            print("Broadcast #\(broadcastCounter) -> \(senders.count) viewer(s)")
        }
        // Every ~5s of 60fps, log per-viewer queue depth. Reveals slow viewers
        // whose droppable frames are being shed.
        if senders.count > 1 && broadcastCounter % 300 == 0 {
            let summary = senders.map { s -> String in
                let (depth, bytes) = s.backlog()
                return "\(s.id.uuidString.prefix(8))=\(depth)msg/\(bytes / 1024)KB"
            }.joined(separator: " ")
            print("Viewer backlog: \(summary)")
        }
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

    /// Snapshot of (queueDepth, queuedBytes) for logging. Cheap: single lock.
    func backlog() -> (depth: Int, bytes: Int) {
        state.withLock { ($0.queue.count, $0.queuedBytes) }
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
    func log(_ message: String) {
        // The listener prints "Listening for tcp on :PORT" on every accept()
        // poll, which floods the console every 10s. Silence it; accept()
        // successes are already logged by the server itself.
        if message.hasPrefix("Listening for ") { return }
        print("[Tailscale] \(message)")
    }
}
