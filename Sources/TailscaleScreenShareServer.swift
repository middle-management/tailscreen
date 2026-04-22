import Foundation
import CoreVideo
import TailscaleKit

/// Screen-share server that uses TailscaleKit as the transport.
///
/// Each accepted client gets its own ``ClientSender`` actor; a slow client can't
/// stall the capture pipeline or other viewers. When a client attaches, the
/// server immediately pushes cached SPS/PPS (if any) and asks the encoder for a
/// fresh IDR so the new viewer starts on a keyframe.
@available(macOS 10.15, *)
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

    private let clientsLock = NSLock()
    private var clients: [UUID: ClientSender] = [:]

    init(port: UInt16 = 7447) {
        self.port = port
        self.logger = TSLogger()
    }

    func start(hostname: String = "cuple-server", authKey: String? = nil, path: String? = nil) async throws {
        guard !isRunning else { return }

        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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

        clientsLock.lock()
        clients[id] = sender
        let cached = encoder?.cachedParameterSets
        clientsLock.unlock()

        let addr = await connection.remoteAddress ?? "unknown"
        print("New viewer: \(addr) [\(id)]")

        if let cached = cached {
            sender.enqueue(.parameterSets(sps: cached.sps, pps: cached.pps), priority: .critical)
        }
        encoder?.requestKeyframe()

        sender.start()
    }

    private func removeClient(_ id: UUID) {
        clientsLock.lock()
        let sender = clients.removeValue(forKey: id)
        clientsLock.unlock()
        if sender != nil {
            print("Viewer disconnected [\(id)]")
        }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }

        clientsLock.lock()
        let hasClients = !clients.isEmpty
        clientsLock.unlock()
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
        clientsLock.lock()
        let senders = Array(clients.values)
        clientsLock.unlock()
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

        clientsLock.lock()
        let all = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()
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
private final class ClientSender: @unchecked Sendable {
    enum Priority {
        case critical
        case droppable
    }

    let id: UUID
    private let connection: IncomingConnection
    private let onClose: (UUID) -> Void

    private let lock = NSLock()
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var closed = false

    /// If the viewer's backlog grows past this, we drop droppable frames.
    /// Roughly one second of 60Mbps = 7.5 MB — this leaves some slack.
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

        lock.lock()
        if closed {
            lock.unlock()
            return
        }

        if priority == .droppable && queuedBytes + data.count > backlogCapBytes {
            lock.unlock()
            return  // viewer is behind — drop this frame
        }

        queue.append(data)
        queuedBytes += data.count
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()

        waiter?.resume()
    }

    private func drain() async {
        while true {
            let item: Data? = await nextItem()
            guard let data = item else { return }
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
            lock.lock()
            if closed {
                lock.unlock()
                return nil
            }
            if !queue.isEmpty {
                let data = queue.removeFirst()
                queuedBytes -= data.count
                lock.unlock()
                return data
            }
            lock.unlock()

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if closed || !queue.isEmpty {
                    lock.unlock()
                    cont.resume()
                    return
                }
                self.waiter = cont
                lock.unlock()
            }
        }
    }

    func close() async {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        queue.removeAll()
        queuedBytes = 0
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()

        waiter?.resume()
        await connection.close()
        task?.cancel()
        onClose(id)
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) { print("[Tailscale] \(message)") }
}
