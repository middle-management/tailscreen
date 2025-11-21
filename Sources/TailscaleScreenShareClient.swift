import Foundation
import AppKit
import CoreVideo

/// Screen share client that uses Tailscale for networking
@available(macOS 10.15, *)
class TailscaleScreenShareClient {
    private var tailscale: TailscaleNetwork?
    private var connection: FileHandle?
    private var decoder: VideoDecoder?
    private var window: NSWindow?
    private var imageView: NSImageView?
    private var receiveBuffer = Data()
    private var isConnected = false
    private let receiveQueue = DispatchQueue(label: "com.cuple.tailscale.receive", qos: .userInteractive)

    /// Connect to a Tailscale peer
    /// - Parameters:
    ///   - hostname: The Tailscale hostname to connect to (e.g., "cuple-server")
    ///   - port: The port to connect to
    ///   - authKey: Optional auth key for authentication
    func connect(to hostname: String, port: UInt16 = 7447, authKey: String? = nil) async throws {
        guard !isConnected else { return }

        print("🔷 Starting Tailscale client...")

        // Initialize Tailscale
        let ts = TailscaleNetwork(hostname: "cuple-client-\(UUID().uuidString.prefix(8))")
        self.tailscale = ts

        // Connect to tailnet
        print("🔷 Connecting to Tailscale network...")
        try await ts.start(authKey: authKey, ephemeral: true)

        let ips = ts.getIPAddresses()
        print("✅ Tailscale connected! IP addresses: \(ips.joined(separator: ", "))")

        // Connect to the server
        print("🔷 Connecting to \(hostname):\(port)...")
        let connection = try await ts.dial(host: hostname, port: port)
        self.connection = connection
        self.isConnected = true

        print("✅ Connected to \(hostname)!")

        // Setup decoder
        decoder = VideoDecoder()
        decoder?.onDecodedFrame = { [weak self] pixelBuffer in
            self?.displayFrame(pixelBuffer)
        }

        // Start receiving data
        receiveQueue.async { [weak self] in
            self?.receiveData()
        }
    }

    private func receiveData() {
        guard let connection = connection, isConnected else { return }

        // Buffer for reading
        var buffer = [UInt8](repeating: 0, count: 65536)

        while isConnected {
            let bytesRead = Darwin.read(connection.fileDescriptor, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                receiveBuffer.append(data)
                processBuffer()
            } else if bytesRead == 0 {
                // Connection closed
                print("🔌 Connection closed by peer")
                DispatchQueue.main.async { [weak self] in
                    self?.disconnect()
                }
                break
            } else {
                // Error
                let error = errno
                if error != EAGAIN && error != EWOULDBLOCK {
                    print("❌ Read error: \(String(cString: strerror(error)))")
                    DispatchQueue.main.async { [weak self] in
                        self?.disconnect()
                    }
                    break
                }
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
        DispatchQueue.main.async { [weak self] in
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
            self?.disconnect()
        }
    }

    func disconnect() {
        isConnected = false

        if let connection = connection {
            try? connection.close()
            self.connection = nil
        }

        decoder?.shutdown()
        decoder = nil

        tailscale?.stop()
        tailscale = nil

        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            self?.window = nil
            self?.imageView = nil
        }

        receiveBuffer.removeAll()

        print("🛑 Client disconnected")
    }

    deinit {
        disconnect()
    }
}
