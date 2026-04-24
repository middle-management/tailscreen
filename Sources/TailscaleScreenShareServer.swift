import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import os
import TailscaleKit

/// Screen-share server over TailscaleKit.
///
/// # Transport
/// Two independent channels, both served by their own ``Listener``:
///
/// - **TCP control** (port 7447): sharer → viewer ``parameterSets`` (SPS/PPS)
///   on every IDR, viewer → sharer ``keyframeRequest`` when the RTP
///   depacketizer detects loss.
/// - **UDP media** (port 7448): RTP-packetized H.264 access units,
///   RFC 3550 + RFC 6184. Plain RTP, not SRTP — WireGuard already encrypts.
///
/// The two channels are broadcast-independent: the server tracks TCP and
/// UDP peers in separate sets and fans each message out to the relevant
/// set. A viewer normally opens both; if one is momentarily down the
/// other still functions degraded. Any new accept on either channel
/// triggers a fresh keyframe so the viewer sees video promptly.
final class TailscaleScreenShareServer: @unchecked Sendable {
    private let controlPort: UInt16
    private let mediaPort: UInt16
    var node: TailscaleNode?
    private var controlListener: Listener?
    private var mediaListener: Listener?
    private var encoder: VideoEncoder?
    private var screenCapture: ScreenCapture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    private var isRunning = false
    private var frameCounter = 0
    private var broadcastCounter = 0
    private let logger: TSLogger
    private let packetizer = RTPPacketizer()

    /// TCP control peers. SPS/PPS go here, keyframeRequest comes from here.
    private let controlClients = OSAllocatedUnfairLock<[UUID: ControlChannel]>(initialState: [:])
    /// UDP media peers. RTP packets go here.
    private let mediaClients = OSAllocatedUnfairLock<[UUID: MediaChannel]>(initialState: [:])

    /// Fires when the underlying ScreenCaptureKit stream ends on its own —
    /// user clicked "Stop Screen Recording" in the menubar, display changed,
    /// or the stream hit an error. AppState observes this to flip the
    /// `isSharing` flag and tear the server down.
    var onCaptureStopped: ((Error?) -> Void)?

    /// Fires at ~2 Hz with a scaled-down thumbnail of the latest captured
    /// frame. Used by AppState to show a preview in the menu while sharing.
    var onPreviewImage: ((NSImage) -> Void)?
    private let previewContext = CIContext(options: [.useSoftwareRenderer: false])
    private let previewMaxWidth: CGFloat = 280

    init(controlPort: UInt16 = 7447, mediaPort: UInt16 = 7448) {
        self.controlPort = controlPort
        self.mediaPort = mediaPort
        self.logger = TSLogger()
    }

    func start(hostname: String = "cuple-server", authKey: String? = nil, path: String? = nil, displayID: CGDirectDisplayID? = nil) async throws {
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

        let controlListener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(controlPort)",
            logger: logger
        )
        self.controlListener = controlListener

        let mediaListener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .udp,
            address: ":\(mediaPort)",
            logger: logger
        )
        self.mediaListener = mediaListener

        print("Listening on Tailscale — control=tcp:\(controlPort) media=udp:\(mediaPort)")

        isRunning = true

        Task { [weak self] in await self?.acceptControl() }
        Task { [weak self] in await self?.acceptMedia() }

        let capture = ScreenCapture()
        capture.onFrameCaptured = { [weak self] pixelBuffer in
            self?.handleCapturedFrame(pixelBuffer)
        }
        capture.onStreamStopped = { [weak self] error in
            self?.onCaptureStopped?(error)
        }
        screenCapture = capture

        do {
            try await capture.start(displayID: displayID)
            print("ScreenCapture started (displayID=\(displayID.map { String($0) } ?? "default"))")
        } catch {
            print("ERROR: ScreenCapture failed to start: \(error)")
        }
    }

    // MARK: - Accept loops

    private func acceptControl() async {
        guard let listener = controlListener else { return }
        while isRunning {
            do {
                let connection = try await listener.accept(timeout: 10.0)
                await attachControl(connection)
            } catch {
                continue
            }
        }
    }

    private func acceptMedia() async {
        guard let listener = mediaListener else { return }
        while isRunning {
            do {
                let connection = try await listener.accept(timeout: 10.0)
                await attachMedia(connection)
            } catch {
                continue
            }
        }
    }

    private func attachControl(_ connection: IncomingConnection) async {
        let id = UUID()
        let addr = await connection.remoteAddress ?? "unknown"
        print("New viewer control: \(addr) [\(id)]")

        let channel = ControlChannel(id: id, connection: connection,
                                     onKeyframeRequest: { [weak self] in self?.encoder?.requestKeyframe() },
                                     onClose: { [weak self] cid in self?.removeControlClient(cid) })
        controlClients.withLock { $0[id] = channel }

        // Seed the viewer with cached params so decoding can start without
        // waiting for the next IDR.
        if let cached = encoder?.cachedParameterSets {
            channel.enqueue(.parameterSets(sps: cached.sps, pps: cached.pps))
        }
        encoder?.requestKeyframe()
        channel.start()
    }

    private func attachMedia(_ connection: IncomingConnection) async {
        let id = UUID()
        let addr = await connection.remoteAddress ?? "unknown"
        print("New viewer media: \(addr) [\(id)]")

        let channel = MediaChannel(id: id, connection: connection,
                                   onClose: { [weak self] cid in self?.removeMediaClient(cid) })
        mediaClients.withLock { $0[id] = channel }
        encoder?.requestKeyframe()
        channel.start()
    }

    private func removeControlClient(_ id: UUID) {
        let removed = controlClients.withLock { $0.removeValue(forKey: id) }
        if removed != nil { print("Viewer control disconnected [\(id)]") }
    }

    private func removeMediaClient(_ id: UUID) {
        let removed = mediaClients.withLock { $0.removeValue(forKey: id) }
        if removed != nil { print("Viewer media disconnected [\(id)]") }
    }

    // MARK: - Capture → encode → broadcast

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }
        frameCounter += 1
        if frameCounter == 1 || frameCounter % 60 == 0 {
            let cc = controlClients.withLock { $0.count }
            let mc = mediaClients.withLock { $0.count }
            print("ScreenCapture: frame #\(frameCounter), control=\(cc) media=\(mc)")
        }

        // Emit a preview thumbnail ~2 Hz regardless of viewer count so the
        // menubar preview stays live. Cheap at this cadence.
        if frameCounter % 30 == 0, let callback = onPreviewImage {
            if let image = buildPreviewImage(from: pixelBuffer) {
                callback(image)
            }
        }

        let hasClients = mediaClients.withLock { !$0.isEmpty }
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
                    self?.broadcastControl(.parameterSets(sps: sps, pps: pps))
                }
                newEncoder.onEncodedData = { [weak self] data, isKeyframe in
                    let ts = DispatchTime.now().uptimeNanoseconds
                    self?.broadcastMedia(data, isKeyframe: isKeyframe, uptimeNs: ts)
                }
                encoder = newEncoder
            } catch {
                print("VideoEncoder setup failed: \(error)")
                return
            }
        }

        encoder?.encode(pixelBuffer: pixelBuffer)
    }

    private func buildPreviewImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let srcExtent = ciImage.extent
        guard srcExtent.width > 0 else { return nil }
        let scale = min(1.0, previewMaxWidth / srcExtent.width)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = previewContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func broadcastControl(_ message: ScreenShareMessage) {
        let viewers = controlClients.withLock { Array($0.values) }
        for v in viewers { v.enqueue(message) }
    }

    private func broadcastMedia(_ accessUnit: Data, isKeyframe: Bool, uptimeNs: UInt64) {
        let viewers = mediaClients.withLock { Array($0.values) }
        broadcastCounter += 1
        if broadcastCounter == 1 || broadcastCounter % 60 == 0 {
            print("Broadcast #\(broadcastCounter) -> \(viewers.count) viewer(s) (kf=\(isKeyframe), \(accessUnit.count)B)")
        }
        guard !viewers.isEmpty else { return }

        let rtpTs = RTPClock.timestamp(fromUptimeNanoseconds: uptimeNs)
        let packets = packetizer.packetize(accessUnit: accessUnit, rtpTimestamp: rtpTs)
        for pkt in packets {
            for v in viewers { v.enqueue(pkt) }
        }
    }

    func getIPAddresses() async throws -> (ip4: String?, ip6: String?) {
        guard let node = node else { throw TailscaleError.badInterfaceHandle }
        return try await node.addrs()
    }

    func stop() async {
        isRunning = false

        await screenCapture?.stop()
        screenCapture = nil

        encoder?.shutdown()
        encoder = nil

        let controls = controlClients.withLock { state -> [ControlChannel] in
            let v = Array(state.values); state.removeAll(); return v
        }
        for c in controls { await c.close() }

        let medias = mediaClients.withLock { state -> [MediaChannel] in
            let v = Array(state.values); state.removeAll(); return v
        }
        for m in medias { await m.close() }

        await controlListener?.close()
        controlListener = nil
        await mediaListener?.close()
        mediaListener = nil

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

// MARK: - Per-viewer channels

/// TCP control channel for a single viewer. Bidirectional: sends SPS/PPS
/// to the viewer, receives keyframeRequest from the viewer.
fileprivate final class ControlChannel: @unchecked Sendable {
    let id: UUID
    private let connection: IncomingConnection
    private let onKeyframeRequest: () -> Void
    private let onClose: (UUID) -> Void

    private struct State {
        var queue: [Data] = []
        var closed = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let lock = NSLock()
    private var state = State()
    private var sendTask: Task<Void, Never>?
    private var recvTask: Task<Void, Never>?

    init(id: UUID,
         connection: IncomingConnection,
         onKeyframeRequest: @escaping () -> Void,
         onClose: @escaping (UUID) -> Void) {
        self.id = id
        self.connection = connection
        self.onKeyframeRequest = onKeyframeRequest
        self.onClose = onClose
    }

    func start() {
        sendTask = Task.detached { [weak self] in await self?.drainSend() }
        recvTask = Task.detached { [weak self] in await self?.drainRecv() }
    }

    func enqueue(_ message: ScreenShareMessage) {
        let data = message.encode()
        lock.lock()
        if state.closed { lock.unlock(); return }
        state.queue.append(data)
        let w = state.waiter; state.waiter = nil
        lock.unlock()
        w?.resume()
    }

    private enum Pop { case closed, item(Data), empty }

    private func drainSend() async {
        while true {
            let popped: Pop = {
                lock.lock(); defer { lock.unlock() }
                if state.closed { return .closed }
                if !state.queue.isEmpty { return .item(state.queue.removeFirst()) }
                return .empty
            }()
            switch popped {
            case .closed: return
            case .item(let d):
                do { try await connection.send(d) }
                catch { print("ControlChannel[\(id)] send failed: \(error)"); await close(); return }
            case .empty:
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = {
                        lock.lock(); defer { lock.unlock() }
                        if state.closed || !state.queue.isEmpty { return true }
                        state.waiter = cont
                        return false
                    }()
                    if resumeNow { cont.resume() }
                }
            }
        }
    }

    private func drainRecv() async {
        var parser = ScreenShareMessageParser()
        while true {
            let closed: Bool = { lock.lock(); defer { lock.unlock() }; return state.closed }()
            if closed { return }
            do {
                let chunk = try await connection.receive(maximumLength: 4096, timeout: 30_000)
                if chunk.isEmpty { continue }
                parser.append(chunk)
                while let msg = parser.next() {
                    switch msg {
                    case .keyframeRequest:
                        print("ControlChannel[\(id)] keyframe requested")
                        onKeyframeRequest()
                    case .parameterSets:
                        break // server never receives these
                    }
                }
            } catch TailscaleError.readFailed {
                if !closed { continue } else { return }
            } catch {
                print("ControlChannel[\(id)] recv error: \(error)")
                await close()
                return
            }
        }
    }

    func close() async {
        let (didClose, waiter): (Bool, CheckedContinuation<Void, Never>?) = {
            lock.lock(); defer { lock.unlock() }
            if state.closed { return (false, nil) }
            state.closed = true
            state.queue.removeAll()
            let w = state.waiter; state.waiter = nil
            return (true, w)
        }()
        waiter?.resume()
        await connection.close()
        sendTask?.cancel()
        recvTask?.cancel()
        if didClose { onClose(id) }
    }
}

/// UDP media channel for a single viewer. Send-only from the server's
/// perspective (RTP packets fan out here).
fileprivate final class MediaChannel: @unchecked Sendable {
    let id: UUID
    private let connection: IncomingConnection
    private let onClose: (UUID) -> Void

    private struct State {
        var queue: [Data] = []
        var closed = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let lock = NSLock()
    private var state = State()
    private var task: Task<Void, Never>?

    /// ~300 KB of buffered UDP datagrams — roughly one Retina IDR.
    /// Oldest-shed on overflow (the UDP drop model — slow viewers don't
    /// stall the capture pipeline).
    // TODO: bitrate adaptation via RTCP would replace this coarse policy.
    private static let softCap = 256

    init(id: UUID, connection: IncomingConnection, onClose: @escaping (UUID) -> Void) {
        self.id = id
        self.connection = connection
        self.onClose = onClose
    }

    func start() {
        task = Task.detached { [weak self] in await self?.drain() }
    }

    func enqueue(_ datagram: Data) {
        lock.lock()
        if state.closed { lock.unlock(); return }
        if state.queue.count >= Self.softCap {
            state.queue.removeFirst(state.queue.count - Self.softCap + 1)
        }
        state.queue.append(datagram)
        let w = state.waiter; state.waiter = nil
        lock.unlock()
        w?.resume()
    }

    private enum Pop { case closed, item(Data), empty }

    private func drain() async {
        while true {
            let popped: Pop = {
                lock.lock(); defer { lock.unlock() }
                if state.closed { return .closed }
                if !state.queue.isEmpty { return .item(state.queue.removeFirst()) }
                return .empty
            }()
            switch popped {
            case .closed: return
            case .item(let d):
                do { try await connection.send(d) }
                catch { print("MediaChannel[\(id)] send failed: \(error)"); await close(); return }
            case .empty:
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = {
                        lock.lock(); defer { lock.unlock() }
                        if state.closed || !state.queue.isEmpty { return true }
                        state.waiter = cont
                        return false
                    }()
                    if resumeNow { cont.resume() }
                }
            }
        }
    }

    func close() async {
        let (didClose, waiter): (Bool, CheckedContinuation<Void, Never>?) = {
            lock.lock(); defer { lock.unlock() }
            if state.closed { return (false, nil) }
            state.closed = true
            state.queue.removeAll()
            let w = state.waiter; state.waiter = nil
            return (true, w)
        }()
        waiter?.resume()
        await connection.close()
        task?.cancel()
        if didClose { onClose(id) }
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) {
        if message.hasPrefix("Listening for ") { return }
        print("[Tailscale] \(message)")
    }
}
