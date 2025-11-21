import Network
import AppKit
import CoreVideo

class ScreenShareClient {
    private var connection: NWConnection?
    private var decoder: VideoDecoder?
    private var window: NSWindow?
    private var imageView: NSImageView?
    private var receiveBuffer = Data()

    func connect(to host: String, port: UInt16) async throws {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: .tcp)

        // Setup decoder
        decoder = VideoDecoder()
        decoder?.onDecodedFrame = { [weak self] pixelBuffer in
            self?.displayFrame(pixelBuffer)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false

            connection?.stateUpdateHandler = { state in
                lock.lock()
                let hasResumed = resumed
                lock.unlock()

                guard !hasResumed else { return }

                switch state {
                case .ready:
                    lock.lock()
                    resumed = true
                    lock.unlock()
                    continuation.resume()
                    self.receiveData()
                case .failed(let error):
                    lock.lock()
                    resumed = true
                    lock.unlock()
                    continuation.resume(throwing: error)
                case .cancelled:
                    lock.lock()
                    let hasResumed = resumed
                    if !hasResumed {
                        resumed = true
                    }
                    lock.unlock()

                    if !hasResumed {
                        continuation.resume(throwing: ClientError.connectionCancelled)
                    }
                default:
                    break
                }
            }

            connection?.start(queue: .global(qos: .userInteractive))
        }
    }

    private func receiveData() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("Receive error: \(error)")
                return
            }

            if let data = data {
                self.receiveBuffer.append(data)
                self.processBuffer()
            }

            if !isComplete {
                self.receiveData()
            }
        }
    }

    private func processBuffer() {
        // Protocol: [frameSize: UInt32][isKeyframe: UInt8][frameData]
        while receiveBuffer.count >= 5 {
            // Read frame size
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

        window.title = "Screen Share Viewer"
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
        connection?.cancel()
        connection = nil

        decoder?.shutdown()
        decoder = nil

        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            self?.window = nil
            self?.imageView = nil
        }

        receiveBuffer.removeAll()
    }
}

enum ClientError: Error {
    case connectionCancelled
}
