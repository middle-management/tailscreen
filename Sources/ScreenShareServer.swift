import Network
import CoreVideo

class ScreenShareServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var encoder: VideoEncoder?
    private var screenCapture: ScreenCapture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        // Setup listener
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = false

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Server listening on port \(self?.port ?? 0)")
            case .failed(let error):
                print("Server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: .global(qos: .userInteractive))

        // Setup screen capture
        screenCapture = ScreenCapture()
        Task {
            try? await screenCapture?.start()

            await MainActor.run {
                self.screenCapture?.onFrameCaptured = { [weak self] pixelBuffer in
                    self?.handleCapturedFrame(pixelBuffer)
                }
            }
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        print("New connection from \(connection.endpoint)")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Connection ready")
                self?.connections.append(connection)
            case .failed(let error):
                print("Connection failed: \(error)")
                self?.removeConnection(connection)
            case .cancelled:
                print("Connection cancelled")
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInteractive))
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !connections.isEmpty else { return }

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
                print("Failed to setup encoder: \(error)")
                return
            }
        }

        encoder?.encode(pixelBuffer: pixelBuffer)
    }

    private func sendEncodedData(_ data: Data, isKeyframe: Bool) {
        // Protocol: [frameSize: UInt32][isKeyframe: UInt8][frameData]
        var packet = Data()

        // Frame size
        var size = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &size, count: 4))

        // Keyframe flag
        var keyframeFlag: UInt8 = isKeyframe ? 1 : 0
        packet.append(Data(bytes: &keyframeFlag, count: 1))

        // Frame data
        packet.append(data)

        // Send to all connections
        for connection in connections {
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    print("Send error: \(error)")
                }
            })
        }
    }

    func stop() {
        encoder?.shutdown()
        encoder = nil

        screenCapture?.stop()
        screenCapture = nil

        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()

        listener?.cancel()
        listener = nil
    }
}
