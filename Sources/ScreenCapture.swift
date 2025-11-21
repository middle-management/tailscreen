import ScreenCaptureKit
import AppKit
import CoreMedia
import CoreVideo

class ScreenCapture: NSObject {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var availableContent: SCShareableContent?
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?

    static func requestPermission() async throws {
        // Request permission by attempting to get shareable content
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func start() async throws {
        // Get available content
        availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = availableContent?.displays.first else {
            throw ScreenCaptureError.noDisplayAvailable
        }

        // Configure the stream
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2 // Retina resolution
        config.height = Int(display.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 FPS
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 5

        // Create content filter for the main display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Create stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Create and add output
        streamOutput = StreamOutput()
        streamOutput?.onFrameCaptured = { [weak self] pixelBuffer in
            self?.onFrameCaptured?(pixelBuffer)
        }

        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        // Start capture
        try await stream?.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        streamOutput = nil
    }

    func captureFrame() {
        // Frames are captured automatically via the stream output
    }
}

extension ScreenCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
    }
}

private class StreamOutput: NSObject, SCStreamOutput {
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        onFrameCaptured?(pixelBuffer)
    }
}

enum ScreenCaptureError: Error {
    case noDisplayAvailable
    case permissionDenied
}
