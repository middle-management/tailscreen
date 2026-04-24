import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import TailscaleKit

/// Screen-share viewer. Opens two connections to the sharer:
///
/// - **TCP control** (``OutgoingConnection`` on port 7447): receives
///   ``parameterSets`` (SPS/PPS), sends ``keyframeRequest`` when the RTP
///   depacketizer notices loss.
/// - **UDP media** (``OutgoingConnection`` on port 7448): receives
///   RFC 3550 + RFC 6184 RTP packets; the ``RTPDepacketizer`` reassembles
///   them into AVCC access units, which go straight into an
///   ``AVSampleBufferDisplayLayer`` for hardware decode + presentation.
@available(macOS 10.15, *)
final class TailscaleScreenShareClient: @unchecked Sendable {
    var node: TailscaleNode?

    private var controlConnection: OutgoingConnection?
    private var mediaConnection: OutgoingConnection?
    private var window: NSWindow?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMFormatDescription?
    private var isConnected = false
    private var isDisconnecting = false
    private var windowCloseObserver: NSObjectProtocol?
    private let logger: TSLogger
    private var controlTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private let depacketizer = RTPDepacketizer()
    /// Filled by `depacketizer.onAccessUnit` (fires synchronously inside
    /// `feed()` on the media-loop thread) and drained by `mediaLoop`
    /// between datagrams so it can `await enqueueFrame`. Never touched
    /// from another thread.
    private var pendingAccessUnits: [(Data, Bool)] = []
    private var framesReceived = 0
    private var lossEvents = 0

    init() {
        self.logger = TSLogger()
    }

    func connect(to hostname: String,
                 controlPort: UInt16 = 7447,
                 mediaPort: UInt16 = 7448,
                 authKey: String? = nil,
                 path: String? = nil) async throws {
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

        print("Dialing \(hostname):\(controlPort) (control) and \(hostname):\(mediaPort) (media)…")
        let control = try await OutgoingConnection(
            tailscale: tailscaleHandle,
            to: "\(hostname):\(controlPort)",
            proto: .tcp,
            logger: logger
        )
        try await control.connect()

        let media = try await OutgoingConnection(
            tailscale: tailscaleHandle,
            to: "\(hostname):\(mediaPort)",
            proto: .udp,
            logger: logger
        )
        try await media.connect()

        // Nudge the sharer's UDP listener so it accepts our peer and starts
        // delivering. A 4-byte NUL "ping" is tiny, costs nothing, and is
        // silently ignored by ``RTPDepacketizer`` (< 12-byte minimum).
        try? await media.send(Data(count: 4))

        self.controlConnection = control
        self.mediaConnection = media
        self.isConnected = true
        print("Connected to \(hostname)")

        depacketizer.onAccessUnit = { [weak self] accessUnit, isKeyframe in
            // Buffered synchronously from inside `depacketizer.feed()`; the
            // media loop drains after each feed so it can `await enqueueFrame`.
            self?.pendingAccessUnits.append((accessUnit, isKeyframe))
        }
        depacketizer.onLoss = { [weak self] count in
            self?.handleLoss(count)
        }

        controlTask = Task { [weak self] in await self?.controlLoop() }
        mediaTask = Task { [weak self] in await self?.mediaLoop() }
    }

    // MARK: - Loops

    private func controlLoop() async {
        guard let connection = controlConnection else { return }
        var parser = ScreenShareMessageParser()
        while isConnected {
            do {
                let chunk = try await connection.receive(maximumLength: 64 * 1024, timeout: 5_000)
                if chunk.isEmpty { continue }
                parser.append(chunk)
                while let message = parser.next() {
                    switch message {
                    case .parameterSets(let sps, let pps):
                        print("Client: received SPS/PPS (sps=\(sps.count)B pps=\(pps.count)B)")
                        applyParameterSets(sps: sps, pps: pps)
                    case .keyframeRequest:
                        break // server-bound message; ignore if echoed
                    }
                }
            } catch TailscaleError.readFailed {
                if !isConnected { break }
                continue
            } catch {
                if isConnected { print("Control recv error: \(error)") }
                break
            }
        }
    }

    private func mediaLoop() async {
        guard let connection = mediaConnection else { return }
        while isConnected {
            do {
                // One call → one UDP datagram (see UDP semantics in
                // TailscaleScreenShareServer.swift header comment).
                let datagram = try await connection.receive(
                    maximumLength: RTPConstants.maxDatagramBytes + 64,
                    timeout: 5_000
                )
                if datagram.isEmpty { continue }
                depacketizer.feed(datagram)
                while !pendingAccessUnits.isEmpty {
                    let (unit, isKeyframe) = pendingAccessUnits.removeFirst()
                    framesReceived += 1
                    if framesReceived == 1 || framesReceived % 60 == 0 {
                        print("Client: received frame #\(framesReceived) (kf=\(isKeyframe), \(unit.count)B, loss events=\(lossEvents))")
                    }
                    await enqueueFrame(data: unit, isKeyframe: isKeyframe)
                }
            } catch TailscaleError.readFailed {
                if !isConnected { break }
                continue
            } catch {
                if isConnected { print("Media recv error: \(error)") }
                break
            }
        }
    }

    private func handleLoss(_ count: Int) {
        lossEvents += 1
        // Coalesce: one keyframe request per several loss events is enough —
        // the encoder will emit an IDR within a frame time either way.
        if lossEvents == 1 || lossEvents % 30 == 0 {
            print("Client: loss detected (missing≈\(count), total events=\(lossEvents)) — requesting keyframe")
            Task { [weak self] in await self?.sendKeyframeRequest() }
        }
    }

    private func sendKeyframeRequest() async {
        guard let control = controlConnection else { return }
        let data = ScreenShareMessage.keyframeRequest.encode()
        do { try await control.send(data) }
        catch { print("Client: keyframeRequest send failed: \(error)") }
    }

    // MARK: - Decoder wiring (unchanged vs. TCP version)

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

    private func enqueueFrame(data: Data, isKeyframe: Bool) async {
        guard let format = formatDescription else { return }

        // Lazily create the window once we know the video dimensions. All
        // subsequent frames skip the MainActor hop and enqueue directly on
        // the layer's renderer, which AVFoundation documents as thread-safe.
        if window == nil {
            let size = Self.size(of: format)
            await MainActor.run { [weak self] in
                guard let self = self, self.isConnected, !self.isDisconnecting else { return }
                if self.window == nil {
                    self.createWindow(initialSize: size)
                }
            }
        }

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
        // Use CFArrayGetValueAtIndex instead of bridging the CFArray to
        // [CFMutableDictionary] — the latter produces a bridged *copy* whose
        // mutations don't reach the real per-sample attachment dictionary,
        // and the Unmanaged pointer juggling involved has tripped
        // objc_autoreleasePoolPop on disconnect.
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0 {
            let raw = CFArrayGetValueAtIndex(attachmentsArray, 0)
            let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
            let displayKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
            let trueValue = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            CFDictionarySetValue(dict, displayKey, trueValue)
            if !isKeyframe {
                let notSyncKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
                CFDictionarySetValue(dict, notSyncKey, trueValue)
            }
        }

        // Enqueue directly from the receive-loop thread. The video renderer
        // is documented thread-safe, and skipping the main-queue hop per
        // frame dodges the repeatable SIGSEGV in objc_autoreleasePoolPop
        // that showed up on every viewer disconnect.
        guard isConnected, !isDisconnecting else { return }
        displayLayer?.sampleBufferRenderer.enqueue(sampleBuffer)
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

        // Stop the receive loops and wait for them to exit BEFORE closing
        // the Tailscale node. Closing the node rips the underlying fds out
        // from under concurrent reads and segfaults tsnet.
        controlTask?.cancel()
        mediaTask?.cancel()
        if let t = controlTask { _ = await t.value }
        if let t = mediaTask { _ = await t.value }
        controlTask = nil
        mediaTask = nil

        if let c = controlConnection { await c.close(); controlConnection = nil }
        if let m = mediaConnection { await m.close(); mediaConnection = nil }

        if let node = node {
            try? await node.close()
            self.node = nil
        }

        await MainActor.run {
            // Detach the willCloseNotification observer BEFORE hiding the
            // window so its callback can't re-enter disconnect().
            if let obs = self.windowCloseObserver {
                NotificationCenter.default.removeObserver(obs)
                self.windowCloseObserver = nil
            }
            self.formatDescription = nil
            // Just hide the window. DO NOT call close(), DO NOT nil our
            // strong refs to window/layer synchronously — every teardown
            // attempt has produced a SIGSEGV in objc_release on the next
            // runloop autoreleasepool pop. Leaving the window + layer
            // retained until the process exits (or the user connects to
            // something else) avoids the race entirely, at the cost of
            // leaking one NSWindow per viewer session.
            self.window?.orderOut(nil)
        }

        print("Client disconnected")
    }

    deinit {
        isConnected = false
        controlTask?.cancel()
        mediaTask?.cancel()
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) { print("[Tailscale] \(message)") }
}
