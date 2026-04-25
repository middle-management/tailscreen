import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import os
import TailscaleKit

/// Screen-share server. Runs two listeners on the same port:
///
///   - **TCP 7447**: presence beacon for peer discovery only. Accepts and
///     immediately closes — `TailscalePeerDiscovery` probes this to detect
///     "is Tailscreen running on that node?" without speaking any protocol.
///   - **UDP 7447**: actual video stream. Carries RTP packets out to viewers
///     and small control bytes (HELLO/KEEPALIVE/BYE/PLI) back from them. The
///     same socket multiplexes both directions; we tell them apart by the
///     first byte (RTP V=2 → 0x80–0xBF, control → 0x00–0x7F).
///
/// Viewers are tracked by their UDP source address. A viewer has to send a
/// HELLO datagram to be added to the fan-out set; if no HELLO/KEEPALIVE
/// arrives for `viewerIdleTimeout` seconds the viewer is dropped silently.
/// There is no TCP-style accept queue and no per-viewer send pipeline — UDP
/// send is non-blocking and a slow viewer just drops packets at the network
/// boundary instead of stalling our process.
final class TailscaleScreenShareServer: @unchecked Sendable {
    private let port: UInt16
    var node: TailscaleNode?
    private var probeListener: Listener?
    private var packetListener: PacketListener?
    private var encoder: VideoEncoder?
    private var screenCapture: ScreenCapture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    private var isRunning = false
    private var frameCounter = 0
    private let logger: TSLogger

    /// Wall-clock anchor used to derive the 90 kHz RTP timestamp. Stays
    /// fixed for the lifetime of the server so the timestamp space is
    /// monotonic across encoder restarts.
    private let rtpTimestampOriginNs: UInt64

    /// Per-viewer state. Keyed by the UDP source address ("ip:port") that
    /// the HELLO arrived from — that's also the destination we echo packets
    /// back to.
    private struct Viewer {
        let addr: String
        let ssrc: UInt32
        var nextSequence: UInt16
        var lastSeenNs: UInt64
    }

    private let viewers = OSAllocatedUnfairLock<[String: Viewer]>(initialState: [:])
    private let parameterSets = OSAllocatedUnfairLock<(sps: Data, pps: Data)?>(initialState: nil)
    private let annotationConnections = OSAllocatedUnfairLock<[UUID: IncomingConnection]>(initialState: [:])

    /// Tail of the broadcast chain. Each new frame's send job awaits this
    /// before issuing its own sends, so frame N's packets fully drain
    /// through the PacketListener actor before frame N+1 starts. Without
    /// this, two concurrent send tasks could interleave at the actor and
    /// receivers would see seq numbers go backwards within an AU.
    private let broadcastTail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Drop viewers that have gone silent for this long. Tuned to be longer
    /// than any reasonable HELLO/KEEPALIVE cadence (clients send
    /// KEEPALIVE every 1s) but short enough that a crashed client is gone
    /// before the next HELLO bursts.
    private let viewerIdleTimeoutNs: UInt64 = 5_000_000_000

    var onCaptureStopped: ((Error?) -> Void)?
    var onPreviewImage: ((NSImage) -> Void)?
    private let previewContext = CIContext(options: [.useSoftwareRenderer: false])
    private let previewMaxWidth: CGFloat = 280

    /// Fires when a viewer sends an annotation op over the back-channel.
    /// AppState routes these into the sharer's overlay window; the drawings
    /// get captured into the video stream and distributed to every viewer.
    var onAnnotationReceived: ((AnnotationOp) -> Void)?

    init(port: UInt16 = 7447) {
        self.port = port
        self.logger = TSLogger()
        self.rtpTimestampOriginNs = DispatchTime.now().uptimeNanoseconds
    }

    func start(hostname: String = "tailscreen-server", authKey: String? = nil, path: String? = nil, displayID: CGDirectDisplayID? = nil) async throws {
        guard !isRunning else { return }

        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Tailscreen/tailscale\(TailscreenInstance.stateSuffix)").path
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

        // TCP "presence beacon" so existing peer discovery (which probes
        // by opening a TCP connection on this port) keeps working. We
        // never speak any protocol on these sockets — accept and close.
        let probeListener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(port)",
            logger: logger
        )
        self.probeListener = probeListener
        print("TCP presence beacon listening on :\(port)")

        // tsnet's ListenPacket requires an explicit IP. "0.0.0.0:\(port)"
        // binds to the tailnet interface address tsnet routes for us.
        let packetListener = try await PacketListener(
            tailscale: tailscaleHandle,
            address: "0.0.0.0:\(port)",
            logger: logger
        )
        self.packetListener = packetListener
        print("UDP video stream listening on :\(port)")

        isRunning = true

        Task { [weak self] in await self?.acceptControlConnections() }
        Task { [weak self] in await self?.receiveControlLoop() }
        Task { [weak self] in await self?.sweepIdleViewers() }

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
            await self.stop()
            throw error
        }
    }

    /// Accept TCP connections on port 7447. The same listener serves two
    /// roles, both of which look identical at the socket level:
    ///
    ///   * **Peer-discovery probe** (`TailscalePeerDiscovery.probeTailscreenPort`)
    ///     opens a connection, sends nothing, then closes. The receive loop
    ///     errors out on EOF and we move on — the probe got "connection
    ///     succeeded" which is all it needed.
    ///   * **Annotation back-channel** from a viewer streams framed
    ///     ``ScreenShareMessage.annotation(...)`` payloads. We parse and
    ///     surface each op via ``onAnnotationReceived``.
    private func acceptControlConnections() async {
        guard let listener = probeListener else { return }
        while isRunning {
            do {
                let conn = try await listener.accept(timeout: 1.0)
                let id = UUID()
                annotationConnections.withLock { $0[id] = conn }
                Task { [weak self] in
                    await self?.receiveAnnotations(from: conn, id: id)
                }
            } catch {
                continue
            }
        }
    }

    /// Reads framed annotation messages from one viewer's TCP back-channel
    /// until the connection closes or the server stops. A peer-discovery
    /// probe just hangs up after a successful connect — the receive call
    /// errors quickly and we tear the entry down with no noise.
    private func receiveAnnotations(from connection: IncomingConnection, id: UUID) async {
        defer {
            annotationConnections.withLock { $0.removeValue(forKey: id) }
            Task { await connection.close() }
        }
        var parser = ScreenShareMessageParser()
        while isRunning {
            do {
                let chunk = try await connection.receive(maximumLength: 16 * 1024, timeout: 5_000)
                if chunk.isEmpty { return }  // EOF — peer closed
                parser.append(chunk)
                while let message = parser.next() {
                    if case .annotation(let op) = message {
                        onAnnotationReceived?(op)
                    }
                }
            } catch TailscaleError.readFailed {
                if !isRunning { return }
                continue  // poll timeout or transient — keep reading
            } catch {
                return
            }
        }
    }

    /// Drains UDP datagrams and routes control bytes (HELLO/KEEPALIVE/BYE/PLI).
    /// RTP packets shouldn't arrive at the server; if they do (a confused
    /// client), they're dropped — we identify them by V=2 in byte 0.
    private func receiveControlLoop() async {
        guard let pl = packetListener else { return }
        while isRunning {
            do {
                let (data, from) = try await pl.recv(timeout: 1_000)
                handleIncoming(data: data, from: from)
            } catch TailscaleError.readFailed {
                continue  // poll timeout, just keep polling
            } catch {
                if isRunning {
                    print("Server: receive error: \(error)")
                }
                break
            }
        }
    }

    private func handleIncoming(data: Data, from addr: String) {
        guard !data.isEmpty else { return }
        // V=2 (RTP) → drop; viewers don't send RTP up to us.
        if !ScreenShareControlMessage.looksLikeControl(data) { return }
        guard let kind = ScreenShareControlMessage.decode(data) else { return }

        switch kind {
        case .hello:
            registerOrRefresh(addr: addr, isNew: true)
        case .keepalive:
            registerOrRefresh(addr: addr, isNew: false)
        case .bye:
            removeViewer(addr: addr)
        case .pli:
            registerOrRefresh(addr: addr, isNew: false)
            encoder?.requestKeyframe()
        }
    }

    private func registerOrRefresh(addr: String, isNew: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (added, viewerCount) = viewers.withLock { state -> (Bool, Int) in
            if var existing = state[addr] {
                existing.lastSeenNs = now
                state[addr] = existing
                return (false, state.count)
            }
            let v = Viewer(
                addr: addr,
                ssrc: UInt32.random(in: 1...UInt32.max),
                nextSequence: UInt16.random(in: 0...UInt16.max),
                lastSeenNs: now
            )
            state[addr] = v
            return (true, state.count)
        }

        if added || isNew {
            print("Viewer \(added ? "joined" : "refreshed") \(addr) (total=\(viewerCount))")
            // New viewer (or one that re-helloed): force a keyframe so
            // they get something decodable immediately. We also push the
            // last cached SPS/PPS in-band on the next IDR; that's handled
            // in handleEncodedData.
            encoder?.requestKeyframe()
        }
    }

    private func removeViewer(addr: String) {
        let removed = viewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        if removed {
            print("Viewer disconnected \(addr)")
        }
    }

    /// Periodically prunes viewers that haven't said anything in a while.
    /// Covers the case where a viewer crashes without sending BYE — we
    /// can't rely on UDP for "the other side is gone" the way TCP gives
    /// us via FIN/RST.
    private func sweepIdleViewers() async {
        while isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            let dropped = viewers.withLock { state -> [String] in
                let stale = state.filter { now &- $0.value.lastSeenNs > self.viewerIdleTimeoutNs }
                for (addr, _) in stale { state.removeValue(forKey: addr) }
                return Array(stale.keys)
            }
            for addr in dropped {
                print("Viewer timeout \(addr)")
            }
        }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }
        frameCounter += 1
        if frameCounter == 1 || frameCounter % 60 == 0 {
            let count = viewers.withLock { $0.count }
            print("ScreenCapture: frame #\(frameCounter), \(count) viewer(s)")
        }

        if frameCounter % 30 == 0, let callback = onPreviewImage {
            if let image = buildPreviewImage(from: pixelBuffer) {
                callback(image)
            }
        }

        let hasViewers = viewers.withLock { !$0.isEmpty }
        guard hasViewers else { return }

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
                    self?.parameterSets.withLock { $0 = (sps, pps) }
                }
                newEncoder.onEncodedData = { [weak self] data, isKeyframe in
                    self?.broadcast(avccData: data, isKeyframe: isKeyframe)
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

    /// Convert an encoded AVCC access unit into RTP packets and fan them out
    /// to every registered viewer with a per-viewer SSRC and sequence number.
    /// On IDR we prepend the cached SPS+PPS as Single NAL packets so the
    /// access unit is fully self-contained — late-joining viewers can decode
    /// the very first frame they observe.
    private func broadcast(avccData: Data, isKeyframe: Bool) {
        guard let pl = packetListener else { return }

        var nals = AVCCParser.nalUnits(from: avccData)
        if isKeyframe, let cached = parameterSets.withLock({ $0 }) {
            // Order is significant: SPS, PPS, then the IDR slice(s).
            nals = [cached.sps, cached.pps] + nals
        }
        guard !nals.isEmpty else { return }

        let rtpTs = currentRTPTimestamp()

        // Snapshot viewer state and bump nextSequence atomically so two
        // concurrent broadcasts can't issue overlapping seq ranges to the
        // same viewer.
        struct Plan {
            let addr: String
            let ssrc: UInt32
            let startSeq: UInt16
        }
        // Predict packet count by packetizing once with seq=0/ssrc=0; each
        // viewer then gets the same byte template with seq/ssrc rewritten.
        let templates = H264Packetizer.packetize(
            nals: nals, timestamp: rtpTs, ssrc: 0, startSequence: 0
        )
        let packetCount = UInt16(templates.count)

        let plans = viewers.withLock { state -> [Plan] in
            var out: [Plan] = []
            // Snapshot keys before the lookup/update loop so we don't iterate
            // a dict whose contents are mid-mutation.
            let addrs = Array(state.keys)
            out.reserveCapacity(addrs.count)
            for addr in addrs {
                guard var viewer = state[addr] else { continue }
                out.append(Plan(addr: addr, ssrc: viewer.ssrc, startSeq: viewer.nextSequence))
                viewer.nextSequence &+= packetCount
                state[addr] = viewer
            }
            return out
        }

        // Chain after the previous frame's send job. The encoder is bursty
        // (one frame's worth of packets emitted in a single callback) but
        // VT serializes its callbacks, so the chain stays short — at most
        // one frame's worth of work in flight at a time.
        let prev = broadcastTail.withLock { $0 }
        let job = Task {
            await prev?.value
            for plan in plans {
                for (i, template) in templates.enumerated() {
                    var pkt = template
                    let seq = plan.startSeq &+ UInt16(i)
                    Self.rewriteRTPHeader(&pkt, sequence: seq, ssrc: plan.ssrc)
                    // UDP is allowed to fail; PLI from the viewer will
                    // recover any frame we couldn't push.
                    try? await pl.send(pkt, to: plan.addr)
                }
            }
        }
        broadcastTail.withLock { $0 = job }
    }

    /// 90 kHz RTP timestamp, anchored at server start. Wraps every ~13 hours
    /// at 90 kHz, which is fine — RTP timestamps are designed to wrap.
    private func currentRTPTimestamp() -> UInt32 {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- rtpTimestampOriginNs
        // Multiply nanoseconds by 9 then divide by 100_000 → ns × (90_000 / 1e9).
        let ticks = (elapsedNs / 100_000) * 9
        return UInt32(truncatingIfNeeded: ticks)
    }

    /// Overwrites bytes 2-3 (sequence) and 8-11 (SSRC) of an RTP packet.
    /// Avoids re-encoding the whole header per viewer.
    private static func rewriteRTPHeader(_ packet: inout Data, sequence: UInt16, ssrc: UInt32) {
        packet[2] = UInt8((sequence >> 8) & 0xFF)
        packet[3] = UInt8(sequence & 0xFF)
        packet[8]  = UInt8((ssrc >> 24) & 0xFF)
        packet[9]  = UInt8((ssrc >> 16) & 0xFF)
        packet[10] = UInt8((ssrc >> 8) & 0xFF)
        packet[11] = UInt8(ssrc & 0xFF)
    }

    func getIPAddresses() async throws -> (ip4: String?, ip6: String?) {
        guard let node = node else { throw TailscaleError.badInterfaceHandle }
        return try await node.addrs()
    }

    func stop() async {
        print("Server stopping…")
        isRunning = false

        await screenCapture?.stop()
        screenCapture = nil
        print("Server stop: capture done")

        encoder?.shutdown()
        encoder = nil

        viewers.withLock { $0.removeAll() }

        await packetListener?.close()
        packetListener = nil
        print("Server stop: packet listener closed")

        await probeListener?.close()
        probeListener = nil
        print("Server stop: probe listener closed")

        // Close any in-flight annotation back-channels in parallel; their
        // receive tasks will see the close and exit naturally.
        let conns = annotationConnections.withLock { state -> [IncomingConnection] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        await withTaskGroup(of: Void.self) { group in
            for conn in conns { group.addTask { await conn.close() } }
        }

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

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) {
        if message.hasPrefix("Listening for ") { return }
        print("[Tailscale] \(message)")
    }
}
