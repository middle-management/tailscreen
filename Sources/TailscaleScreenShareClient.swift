import Foundation
import AppKit
import CoreVideo
import TailscaleKit

/// Screen share client that uses TailscaleKit for networking
/// This uses the official TailscaleKit framework from libtailscale/swift
@available(macOS 10.15, *)
class TailscaleScreenShareClient: @unchecked Sendable {
    private var node: TailscaleNode?
    private var connection: OutgoingConnection?
    private var decoder: VideoDecoder?
    private var window: NSWindow?
    private var imageView: NSImageView?
    private var receiveBuffer = Data()
    private var isConnected = false
    private let logger: TSLogger
    private var receiveTask: Task<Void, Never>?

    init() {
        self.logger = TSLogger()
    }

    /// Connect to a Tailscale peer
    /// - Parameters:
    ///   - hostname: The Tailscale hostname or IP to connect to (e.g., "cuple-server" or "100.64.0.1")
    ///   - port: The port to connect to
    ///   - authKey: Optional auth key for authentication
    ///   - path: State directory (defaults to ~/Library/Application Support/Cuple/tailscale-client)
    func connect(to hostname: String, port: UInt16 = 7447, authKey: String? = nil, path: String? = nil) async throws {
        guard !isConnected else { return }

        // Determine state directory
        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Cuple/tailscale-client").path
        }()

        // Create directory if needed
        try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

        print("🔷 Starting Tailscale client...")

        // Create Tailscale configuration with unique hostname
        let clientHostname = "cuple-client-\(UUID().uuidString.prefix(8))"
        let config = Configuration(
            hostName: clientHostname,
            path: statePath,
            authKey: authKey,
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        // Initialize Tailscale node
        let node = try TailscaleNode(config: config, logger: logger)
        self.node = node

        // Bring up the node
        print("🔷 Connecting to Tailscale network...")
        try await node.up()

        let ips = try await node.addrs()
        print("✅ Tailscale connected!")
        if let ip4 = ips.ip4 {
            print("   IPv4: \(ip4)")
        }
        if let ip6 = ips.ip6 {
            print("   IPv6: \(ip6)")
        }

        // Get the tailscale handle
        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        // Connect to the server
        print("🔷 Connecting to \(hostname):\(port)...")
        let connection = try await OutgoingConnection(
            tailscale: tailscaleHandle,
            to: "\(hostname):\(port)",
            proto: .tcp,
            logger: logger
        )

        try await connection.connect()
        self.connection = connection
        self.isConnected = true

        print("✅ Connected to \(hostname)!")

        // Setup decoder
        decoder = VideoDecoder()
        decoder?.onDecodedFrame = { [weak self] pixelBuffer in
            self?.displayFrame(pixelBuffer)
        }

        // Start receiving data
        receiveTask = Task { [weak self] in
            await self?.receiveData()
        }
    }

    private func receiveData() async {
        while isConnected {
            do {
                // Read data from connection
                // Note: OutgoingConnection doesn't have a receive method in the current API
                // We'd need to access the underlying file descriptor or use IncomingConnection
                // This is a limitation of the current TailscaleKit API design

                // For bidirectional communication, we might need to:
                // 1. Create a separate listener for server->client communication
                // 2. Or extend OutgoingConnection to support receiving
                // 3. Or use the raw file descriptor

                // For now, this is a placeholder showing the intended structure
                try await Task.sleep(for: .seconds(1))

            } catch {
                if isConnected {
                    print("❌ Receive error: \(error)")
                }
                break
            }
        }
    }

    private func processBuffer() {
        // Protocol: [frameSize: UInt32][isKeyframe: UInt8][frameData]
        while receiveBuffer.count >= 5 {
            // Read frame size (big-endian)
            let sizeData = receiveBuffer[0..<4]
            let frameSize = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Check if we have the complete frame
            guard receiveBuffer.count >= 5 + Int(frameSize) else {
                break
            }

            // Read keyframe flag
            let isKeyframe = receiveBuffer[4] == 1

            // Read frame data
            let frameData = receiveBuffer[5..<(5 + Int(frameSize))]

            // Process the frame
            decoder?.decode(data: frameData, isKeyframe: isKeyframe)

            // Remove processed data from buffer
            receiveBuffer.removeFirst(5 + Int(frameSize))
        }
    }

    private func displayFrame(_ pixelBuffer: CVPixelBuffer) {
        Task { @MainActor [weak self, pixelBuffer] in
            guard let self = self else { return }

            // Create window if needed
            if self.window == nil {
                self.createWindow()
            }

            // Convert pixel buffer to NSImage
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()

            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                return
            }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            self.imageView?.image = image

            // Resize window to match image if needed
            if let window = self.window, !window.isVisible {
                let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

                // Calculate scaled size to fit screen
                let imageSize = image.size
                var windowSize = imageSize

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
                window.makeKeyAndOrderFront(nil)
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

        // Handle window close
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

        decoder?.shutdown()
        decoder = nil

        if let node = node {
            try? await node.close()
            self.node = nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            self?.window = nil
            self?.imageView = nil
        }

        receiveBuffer.removeAll()

        print("🛑 Client disconnected")
    }

    deinit {
        // Cleanup is handled by disconnect() which should be called before deallocation
        // We cannot use Task in deinit as it would capture self after deallocation
        isConnected = false
        receiveTask?.cancel()
    }
}

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[Tailscale] \(message)")
    }
}
