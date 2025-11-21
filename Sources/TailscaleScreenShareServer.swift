import Foundation
import CoreVideo
import TailscaleKit

/// Screen share server that uses TailscaleKit for networking
/// This uses the official TailscaleKit framework from libtailscale/swift
@available(macOS 10.15, *)
class TailscaleScreenShareServer: @unchecked Sendable {
    private let port: UInt16
    private var node: TailscaleNode?
    private var listener: Listener?
    private var connections: [IncomingConnection] = []
    private var encoder: VideoEncoder?
    private var screenCapture: ScreenCapture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0
    private var isRunning = false
    private let logger: TSLogger

    // Connection management
    private let connectionQueue = DispatchQueue(label: "com.cuple.tailscale.connections", attributes: .concurrent)
    private var activeConnections: [UUID: (connection: IncomingConnection, task: Task<Void, Never>)] = [:]

    init(port: UInt16 = 7447) {
        self.port = port
        self.logger = TSLogger()
    }

    /// Start the Tailscale server
    /// - Parameters:
    ///   - hostname: The Tailscale hostname for this node (e.g., "cuple-server")
    ///   - authKey: Optional auth key (if not provided, will prompt for auth via URL)
    ///   - path: State directory (defaults to ~/Library/Application Support/Cuple/tailscale)
    func start(hostname: String = "cuple-server", authKey: String? = nil, path: String? = nil) async throws {
        guard !isRunning else { return }

        // Determine state directory
        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Cuple/tailscale").path
        }()

        // Create directory if needed
        try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

        print("🔷 Starting Tailscale server...")

        // Create Tailscale configuration
        let config = Configuration(
            hostName: hostname,
            path: statePath,
            authKey: authKey,
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        // Initialize Tailscale node
        let node = try TailscaleNode(config: config, logger: logger)
        self.node = node

        // Bring up the node
        try await node.up()

        let ips = try await node.addrs()
        print("✅ Tailscale connected!")
        if let ip4 = ips.ip4 {
            print("   IPv4: \(ip4)")
        }
        if let ip6 = ips.ip6 {
            print("   IPv6: \(ip6)")
        }

        // Get the tailscale handle for creating listener
        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        // Start listening on Tailscale network
        print("🔷 Starting listener on port \(port)...")
        let listener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(port)",
            logger: logger
        )
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
                let connection = try await listener.accept(timeout: 10.0)
                handleNewConnection(connection)
            } catch {
                // Poll timeout or other errors - just continue trying
                // Timeouts are expected when no connections are pending
                continue
            }
        }
    }

    private func handleNewConnection(_ connection: IncomingConnection) {
        let id = UUID()
        let remoteAddr = Task { await connection.remoteAddress }

        Task {
            let addr = await remoteAddr.value
            print("✅ New Tailscale connection from: \(addr ?? "unknown")")
        }

        // Don't actually need to read from connection for server mode
        // We just broadcast to all connections
        connectionQueue.async(flags: .barrier) { [weak self] in
            self?.activeConnections[id] = (connection, Task {})
        }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning, !activeConnections.isEmpty else { return }

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

        // Send to all connections (using the underlying file descriptors)
        connectionQueue.sync {
            var deadConnections: [UUID] = []

            for (id, (connection, _)) in activeConnections {
                // Note: IncomingConnection doesn't have a send method
                // We'd need to get the raw file descriptor and write directly
                // For now, we'll track connections but actual sending would need
                // additional implementation or use of OutgoingConnection pattern

                // This is a limitation of the current TailscaleKit API
                // for bidirectional communication
                _ = connection
            }

            // Remove dead connections
            for id in deadConnections {
                activeConnections.removeValue(forKey: id)
            }
        }
    }

    func getIPAddresses() async throws -> (ip4: String?, ip6: String?) {
        guard let node = node else {
            throw TailscaleError.badInterfaceHandle
        }
        return try await node.addrs()
    }

    func stop() async {
        isRunning = false

        encoder?.shutdown()
        encoder = nil

        screenCapture?.stop()
        screenCapture = nil

        // Close all connections
        for (_, (connection, task)) in activeConnections {
            task.cancel()
            await connection.close()
        }
        activeConnections.removeAll()

        listener?.close()
        listener = nil

        if let node = node {
            try? await node.close()
            self.node = nil
        }

        print("🛑 Server stopped")
    }

    deinit {
        Task {
            await stop()
        }
    }
}

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[Tailscale] \(message)")
    }
}
