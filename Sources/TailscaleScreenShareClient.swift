import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import TailscaleKit

/// Screen-share viewer. Dials a peer over TailscaleKit, parses the framed
/// protocol, and pipes the raw H.264 sample buffers straight into an
/// `AVSampleBufferDisplayLayer` — no CIImage, no CGImage copies, no
/// per-frame MainActor hop. The display layer handles hardware decode +
/// presentation on its own thread.
@available(macOS 10.15, *)
final class TailscaleScreenShareClient: @unchecked Sendable {
    var node: TailscaleNode?

    private var connection: OutgoingConnection?
    private var window: NSWindow?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMFormatDescription?
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
                        applyParameterSets(sps: sps, pps: pps)
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
                        enqueueFrame(data: data, isKeyframe: isKeyframe)
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

    private func applyParameterSets(sps: Data, pps: Data) {
        var newDesc: CMFormatDescription?
        let status = sps.withUnsafeBytes { (spsBuf: UnsafeRawBufferPointer) -> OSStatus in
            pps.withUnsafeBytes { (ppsBuf: UnsafeRawBufferPointer) -> OSStatus in
                guard let spsBase = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrs in
                    sizes.withUnsafeBufferPointer { szs in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: szs.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newDesc
                        )
                    }
                }
            }
        }
        guard status == noErr, let desc = newDesc else {
            print("Client: failed to build H.264 format description (\(status))")
            return
        }
        formatDescription = desc
    }

    private func enqueueFrame(data: Data, isKeyframe: Bool) {
        guard let format = formatDescription else { return }

        // Wrap the AVCC NAL units in a CMBlockBuffer owning its own copy.
        var blockBuffer: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else { return }

        let copyStatus = data.withUnsafeBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizes = [data.count]
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else { return }

        // Tell the display layer to show this frame immediately, no reorder.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyframe {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        Task { @MainActor [weak self, sampleBuffer] in
            guard let self = self else { return }
            if self.window == nil {
                self.createWindow(initialSize: Self.size(of: format))
            }
            self.displayLayer?.sampleBufferRenderer.enqueue(sampleBuffer)
        }
    }

    private static func size(of format: CMFormatDescription) -> CGSize {
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
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

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.frame = contentView.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(displayLayer)

        window.contentView = contentView
        self.window = window
        self.displayLayer = displayLayer

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        print("Client: viewer window ordered front (size=\(Int(windowSize.width))x\(Int(windowSize.height)))")

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

        await MainActor.run {
            // Detach the willCloseNotification observer BEFORE closing the
            // window so its callback can't re-enter disconnect().
            if let obs = self.windowCloseObserver {
                NotificationCenter.default.removeObserver(obs)
                self.windowCloseObserver = nil
            }
            // Remove the layer from its superlayer before nil-ing — flushing
            // a detached renderer is fine, but we want to stop any in-flight
            // enqueues from touching it.
            self.displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
            self.displayLayer?.removeFromSuperlayer()
            self.displayLayer = nil
            self.window?.close()
            self.window = nil
            self.formatDescription = nil
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
