import Foundation
import AppKit
import CoreVideo
import TailscaleKit

/// Screen-share viewer. Dials a peer over TailscaleKit, parses the framed
/// protocol, and renders decoded frames into an NSWindow.
@available(macOS 10.15, *)
final class TailscaleScreenShareClient: @unchecked Sendable {
    var node: TailscaleNode?

    private var connection: OutgoingConnection?
    private let decoder = VideoDecoder()
    private var window: NSWindow?
    private var imageView: NSImageView?
    private var isConnected = false
    private let logger: TSLogger
    private var receiveTask: Task<Void, Never>?

    init() {
        self.logger = TSLogger()
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
            self?.displayFrame(pixelBuffer)
        }
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
                        decoder.setParameterSets(sps: sps, pps: pps)
                    case .frame(let data, let isKeyframe, let timestampNs):
                        framesReceived += 1
                        if framesReceived == 1 || framesReceived % 60 == 0 {
                            let nowNs = DispatchTime.now().uptimeNanoseconds
                            // Server timestamp is also mach ns. On a single host the
                            // clocks are identical; across hosts the delta is still
                            // useful as a relative number if clocks are close.
                            let latencyMs: Double
                            if timestampNs > 0 && nowNs >= timestampNs {
                                latencyMs = Double(nowNs - timestampNs) / 1_000_000.0
                            } else {
                                latencyMs = -1
                            }
                            let latencyStr = latencyMs >= 0 ? String(format: "%.1fms", latencyMs) : "n/a"
                            print("Client: received frame #\(framesReceived) (kf=\(isKeyframe), \(data.count)B, total=\(bytesReceived)B, encode→recv=\(latencyStr))")
                        }
                        decoder.decode(data: data, isKeyframe: isKeyframe)
                    }
                }
            } catch TailscaleError.readFailed {
                // Either poll timeout (no data) or EOF. Stay in the loop unless we were closed.
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

    private func displayFrame(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("Client: displayFrame failed to build CGImage")
            return
        }

        Task { @MainActor [weak self, cgImage] in
            guard let self = self else { return }

            let firstFrame = (self.window == nil)
            if firstFrame {
                print("Client: creating viewer window (first decoded frame \(cgImage.width)x\(cgImage.height))")
                self.createWindow()
            }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            self.imageView?.image = image

            guard let window = self.window else { return }
            if !window.isVisible {
                let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                var windowSize = image.size
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
                window.setFrame(NSRect(origin: origin, size: windowSize), display: true)
                // MenuBarExtra apps default to .accessory activation policy, so
                // windows can exist but don't necessarily come to the front.
                // Activate the app + raise the window so the viewer is visible.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                print("Client: viewer window ordered front (size=\(Int(windowSize.width))x\(Int(windowSize.height)))")
            }
        }
    }

    @MainActor
    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tailscale Screen Share"
        window.backgroundColor = .black

        let imageView = NSImageView(frame: window.contentView!.bounds)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(imageView)

        self.window = window
        self.imageView = imageView

        NotificationCenter.default.addObserver(
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
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil

        if let connection = connection {
            await connection.close()
            self.connection = nil
        }

        decoder.shutdown()

        if let node = node {
            try? await node.close()
            self.node = nil
        }

        await MainActor.run {
            self.window?.close()
            self.window = nil
            self.imageView = nil
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
