import Foundation
import CoreVideo

/// Screen share server that uses Tailscale for networking
@available(macOS 10.15, *)
class TailscaleScreenShareServer {
    private let port: UInt16
    private var tailscale: TailscaleNetwork?
    private var listener: TailscaleListener?
    private var connections: [FileHandle] = []
    private var encoder: VideoEncoder?
    private var screenCapture: ScreenCapture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    private var isRunning = false
    private let connectionQueue = DispatchQueue(label: "com.cuple.tailscale.connections", attributes: .concurrent)

    init(port: UInt16 = 7447) {
        self.port = port
    }

    /// Start the Tailscale server
    /// - Parameters:
    ///   - hostname: The Tailscale hostname for this node (e.g., "cuple-server")
    ///   - authKey: Optional auth key (if not provided, will prompt for auth via URL)
    func start(hostname: String = "cuple-server", authKey: String? = nil) async throws {
        guard !isRunning else { return }

        // Initialize Tailscale
        print("🔷 Starting Tailscale network...")
        let ts = TailscaleNetwork(hostname: hostname)
        self.tailscale = ts

        // Connect to tailnet
        try await ts.start(authKey: authKey, ephemeral: true)

        let ips = ts.getIPAddresses()
        print("✅ Tailscale connected! IP addresses: \(ips.joined(separator: ", "))")

        // Start listening on Tailscale network
        print("🔷 Starting listener on port \(port)...")
        let listener = try ts.listen(port: port)
        self.listener = listener
        print("✅ Listening on Tailscale port \(port)")

        isRunning = true

        // Start accepting connections in background
        Task {
            await acceptConnections()
        }

        // Setup screen capture
        print("🔷 Starting screen capture...")
        screenCapture = ScreenCapture()
        try? await screenCapture?.start()

        await MainActor.run {
            self.screenCapture?.onFrameCaptured = { [weak self] pixelBuffer in
                self?.handleCapturedFrame(pixelBuffer)
            }
        }

        print("✅ Screen share server started!")
    }

    private func acceptConnections() async {
        guard let listener = listener else { return }

        while isRunning {
            do {
                let connection = try await listener.accept()
                handleNewConnection(connection)
            } catch {
                if isRunning {
                    print("❌ Accept error: \(error)")
                }
            }
        }
    }

    private func handleNewConnection(_ connection: FileHandle) {
        print("✅ New Tailscale connection!")

        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.connections.append(connection)
        }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning, !connections.isEmpty else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Initialize or reinitialize encoder if dimensions changed
        if encoder == nil || width != lastWidth || height != lastHeight {
            encoder?.shutdown()
            encoder = VideoEncoder()

            do {
                try encoder?.setup(width: width, height: height)
                lastWidth = width
                lastHeight = height

                encoder?.onEncodedData = { [weak self] data, isKeyframe in
                    self?.sendEncodedData(data, isKeyframe: isKeyframe)
                }
            } catch {
                print("❌ Failed to setup encoder: \(error)")
                return
            }
        }

        encoder?.encode(pixelBuffer: pixelBuffer)
    }

    private func sendEncodedData(_ data: Data, isKeyframe: Bool) {
        // Protocol: [frameSize: UInt32][isKeyframe: UInt8][frameData]
        var packet = Data()

        // Frame size (big-endian)
        var size = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }

        // Keyframe flag
        var keyframeFlag: UInt8 = isKeyframe ? 1 : 0
        withUnsafeBytes(of: &keyframeFlag) { packet.append(contentsOf: $0) }

        // Frame data
        packet.append(data)

        // Send to all connections
        connectionQueue.sync {
            var deadConnections: [FileHandle] = []

            for connection in connections {
                do {
                    try packet.withUnsafeBytes { buffer in
                        if let baseAddress = buffer.baseAddress {
                            let bytesWritten = Darwin.write(connection.fileDescriptor,
                                                           baseAddress,
                                                           packet.count)
                            if bytesWritten < 0 {
                                deadConnections.append(connection)
                            }
                        }
                    }
                } catch {
                    print("❌ Send error: \(error)")
                    deadConnections.append(connection)
                }
            }

            // Remove dead connections
            for dead in deadConnections {
                print("🔌 Removing dead connection")
                try? dead.close()
                connections.removeAll { $0 === dead }
            }
        }
    }

    func getIPAddresses() -> [String] {
        return tailscale?.getIPAddresses() ?? []
    }

    func stop() {
        isRunning = false

        encoder?.shutdown()
        encoder = nil

        screenCapture?.stop()
        screenCapture = nil

        connectionQueue.sync(flags: .barrier) {
            for connection in connections {
                try? connection.close()
            }
            connections.removeAll()
        }

        listener?.close()
        listener = nil

        tailscale?.stop()
        tailscale = nil

        print("🛑 Server stopped")
    }

    deinit {
        stop()
    }
}
