import AppKit
import CoreVideo
import Foundation
import TailscaleKit

/// Screen-share viewer. Dials a peer over TailscaleKit, parses the framed
/// protocol, decodes H.264 via `VideoDecoder` (VTDecompressionSession), and
/// presents the resulting `CVPixelBuffer`s on a `CAMetalLayer` driven by a
/// `CADisplayLink`.
///
/// The previous implementation pushed sample buffers straight into an
/// `AVSampleBufferDisplayLayer`; that layer owns a background renderer that
/// autoreleases internal objects into whatever autorelease pool is active on
/// the main queue. Disconnect + window teardown raced that background work
/// and produced a repeatable `SIGSEGV` in `objc_release` on the next pool
/// pop. Decoding and rendering ourselves removes the background actor and
/// lets us tear everything down synchronously.
@available(macOS 10.15, *)
final class TailscaleScreenShareClient: @unchecked Sendable {
    var node: TailscaleNode?

    private var connection: OutgoingConnection?
    private var window: NSWindow?
    private var renderer: MetalViewerRenderer?
    private var decoder: VideoDecoder?
    private var isConnected = false
    private var isDisconnecting = false
    private var windowCloseObserver: NSObjectProtocol?
    private let logger: TSLogger
    private var receiveTask: Task<Void, Never>?

    init() {
        self.logger = TSLogger()
    }

    func connect(to hostname: String, port: UInt16 = 7447, authKey: String? = nil, path: String? = nil) async throws {
        guard !isConnected else { return }

        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Cuple/tailscale-client\(CupleInstance.stateSuffix)").path
        }()
        try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

        print("Starting Tailscale client…")

        let clientHostname = "cuple-client-\(UUID().uuidString.prefix(8))"
        let config = Configuration(
            hostName: clientHostname,
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

        print("Dialing \(hostname):\(port)…")
        let connection = try await OutgoingConnection(
            tailscale: tailscaleHandle,
            to: "\(hostname):\(port)",
            proto: .tcp,
            logger: logger
        )
        try await connection.connect()
        self.connection = connection

        let decoder = VideoDecoder()
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
            self?.handleDecodedFrame(pixelBuffer)
        }
        self.decoder = decoder

        self.isConnected = true
        print("Connected to \(hostname)")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        guard let connection = connection else { return }
        var parser = ScreenShareMessageParser()
        var bytesReceived = 0
        var framesReceived = 0

        while isConnected {
            do {
                // Generous timeout so we don't spin; receive returns as soon as bytes arrive.
                let chunk = try await connection.receive(maximumLength: 64 * 1024, timeout: 5_000)
                if chunk.isEmpty { continue }
                bytesReceived += chunk.count

                parser.append(chunk)
                while let message = parser.next() {
                    switch message {
                    case .parameterSets(let sps, let pps):
                        print("Client: received SPS/PPS (sps=\(sps.count)B pps=\(pps.count)B)")
                        decoder?.setParameterSets(sps: sps, pps: pps)
                    case .frame(let data, let isKeyframe, let timestampNs):
                        framesReceived += 1
                        if framesReceived == 1 || framesReceived % 60 == 0 {
                            let nowNs = DispatchTime.now().uptimeNanoseconds
                            let latencyMs: Double
                            if timestampNs > 0 && nowNs >= timestampNs {
                                latencyMs = Double(nowNs - timestampNs) / 1_000_000.0
                            } else {
                                latencyMs = -1
                            }
                            let latencyStr = latencyMs >= 0 ? String(format: "%.1fms", latencyMs) : "n/a"
                            print("Client: received frame #\(framesReceived) (kf=\(isKeyframe), \(data.count)B, total=\(bytesReceived)B, encode→recv=\(latencyStr))")
                        }
                        self.lastReceiveUptimeNs = DispatchTime.now().uptimeNanoseconds
                        decoder?.decode(data: data, isKeyframe: isKeyframe)
                    }
                }
            } catch TailscaleError.readFailed {
                if !isConnected { break }
                continue
            } catch {
                if isConnected {
                    print("Receive error: \(error)")
                }
                break
            }
        }
    }

    /// Timestamp (mach uptime ns) when the most recent frame finished
    /// arriving on the socket. Used only to measure recv→present latency;
    /// last-writer-wins is fine for that purpose.
    private var lastReceiveUptimeNs: UInt64 = 0

    private func handleDecodedFrame(_ buffer: CVPixelBuffer) {
        // VTDecompressionSession delivers frames on its own callback thread.
        // Hand the buffer to the renderer on whatever thread this is — the
        // renderer guards its slot with a lock. If the window isn't up yet
        // `renderer` is nil; that's fine, the next frame lands once main
        // finishes window creation.
        let ns = lastReceiveUptimeNs
        guard isConnected, !isDisconnecting else { return }
        renderer?.setPixelBuffer(buffer, receiveUptimeNs: ns)

        // First frame: hop to main once to build the window so we know the
        // source dimensions. Deliberately don't capture `buffer` in the
        // main-actor closure — Swift 6's region isolation analysis flags
        // sending a non-Sendable `CVPixelBuffer` across the boundary, and
        // we don't need it there anyway.
        if window == nil {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let size = CGSize(width: width, height: height)
            Task { @MainActor [weak self] in
                guard let self = self, self.isConnected, !self.isDisconnecting else { return }
                if self.window == nil {
                    self.createWindow(initialSize: size)
                }
            }
        }
    }

    @MainActor
    private func createWindow(initialSize: CGSize) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        var windowSize = initialSize
        let maxWidth = screenFrame.width * 0.9
        let maxHeight = screenFrame.height * 0.9
        if windowSize.width > maxWidth {
            let scale = maxWidth / windowSize.width
            windowSize.width = maxWidth
            windowSize.height *= scale
        }
        if windowSize.height > maxHeight {
            let scale = maxHeight / windowSize.height
            windowSize.height = maxHeight
            windowSize.width *= scale
        }

        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tailscale Screen Share"
        window.backgroundColor = .black

        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        contentView.wantsLayer = true
        contentView.layer = CALayer()
        contentView.layer?.backgroundColor = NSColor.black.cgColor

        let renderer = MetalViewerRenderer()
        let metalLayer = renderer.metalLayer
        metalLayer.frame = contentView.bounds
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(metalLayer)

        window.contentView = contentView
        self.window = window
        self.renderer = renderer

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        print("Client: viewer window ordered front (size=\(Int(windowSize.width))x\(Int(windowSize.height)))")

        // `NSView.displayLink(target:selector:)` needs the view to be on a
        // screen, so start the link after ordering the window front.
        renderer.start(in: contentView)

        self.windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.disconnect()
            }
        }
    }

    func disconnect() async {
        // Idempotent. Disconnect can fire from: AppState.disconnect menu
        // click, the window's close button (via willCloseNotification), and
        // the receiveLoop's error path — all at once during teardown.
        if isDisconnecting { return }
        isDisconnecting = true

        isConnected = false

        // Stop the receive loop and wait for it to exit BEFORE closing the
        // Tailscale node. Closing the node rips the underlying fd out from
        // under a concurrent read and segfaults tsnet.
        if let receiveTask = receiveTask {
            receiveTask.cancel()
            _ = await receiveTask.value
        }
        receiveTask = nil

        if let connection = connection {
            await connection.close()
            self.connection = nil
        }

        if let node = node {
            try? await node.close()
            self.node = nil
        }

        // Shut the decoder down next. `shutdown` blocks on the decoder's
        // serial queue, so once it returns no more frames can be delivered
        // to the renderer.
        if let decoder = decoder {
            decoder.onDecodedFrame = nil
            decoder.shutdown()
            self.decoder = nil
        }

        // Bisect concluded: NSWindow.close() under any teardown ordering
        // we tried (sync, autoreleasepool-wrapped, contentView-detach +
        // multi-tick yield) produces a zombie that the next pool pop
        // SIGSEGVs on. Apple framework leaves something autoreleased in
        // the surrounding pool that we can't isolate without changing
        // the framework. Workaround: orderOut the window, invalidate the
        // display link, leave window + renderer retained by self until
        // TailscaleScreenShareClient itself deallocates one runloop later
        // under a fresh pool. Leaks one NSWindow per viewer session.
        await MainActor.run {
            // Don't call NotificationCenter.removeObserver here. When the
            // window's close button triggered this disconnect, we're still
            // inside the willCloseNotification dispatch — removing the
            // observer mid-dispatch crashed objc_msgSend_uncached at a
            // null receiver. Leaking the observer is fine: the NSWindow
            // it watches is also leaked by the workaround below, so it
            // never fires again. Just drop our strong ref.
            self.windowCloseObserver = nil
            self.renderer?.invalidate()
            self.window?.orderOut(nil)
        }

        print("Client disconnected")
    }

    deinit {
        isConnected = false
        receiveTask?.cancel()
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) { print("[Tailscale] \(message)") }
}
