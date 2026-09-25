import AppKit
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Snapshot of viewer-side health metrics for the stats overlay. All counters
/// are "since this session began rendering" — reset on `resetStats()`.
///
/// `codec`/`bitrateBps` are best-effort: codec from the first RTP packet's
/// payload type, bitrate a 1s sliding window over received bytes (wire-level,
/// not the encoder's internal target).
struct ViewerStats: Sendable, Equatable {
    var latencyMs: Double?
    var fps: Double
    /// `replacePendingBuffer` overwriting a not-yet-rendered buffer counts as
    /// a drop.
    var droppedPct: Double?
    var bitrateBps: Double?
    var codec: VideoCodec?
    var framesPresented: Int
    var framesDropped: Int
    var decodeFailures: Int
    /// Both loss-driven and decode-ladder-driven, post-throttle.
    var plisSent: Int
    var isDegraded: Bool
    /// Should rise while `plisSent` stays low on a lossy link — the point of
    /// retransmit vs. the old keyframe storm.
    var nacksSent: Int
    /// Should rise while `nacksSent`/`plisSent` stay near zero on a lossy
    /// high-RTT link — the net-impair validation signal for FEC.
    var fecRecovered: Int
    /// "P3", "BT.2020 · PQ" (`ColorInfo.statsLabel`). No range: the mac
    /// decoder outputs 32BGRA, so no YCbCr range survives to report (the GTK/
    /// WinUI viewers show one since their decoder hands back raw planes).
    var colorLabel: String?

    static let empty = ViewerStats(
        latencyMs: nil,
        fps: 0,
        droppedPct: nil,
        bitrateBps: nil,
        codec: nil,
        framesPresented: 0,
        framesDropped: 0,
        decodeFailures: 0,
        plisSent: 0,
        isDegraded: false,
        nacksSent: 0,
        fecRecovered: 0,
        colorLabel: nil
    )
}

/// Not `@MainActor` so it can be a `let` on the non-isolated
/// `MetalViewerRenderer`; `@unchecked Sendable` carries the invariant that
/// all mutating calls hop to main first.
final class ViewerStatsModel: ObservableObject, @unchecked Sendable {
    @Published var stats: ViewerStats = .empty

    /// Bound into the overlay's hosting view's `isHidden`.
    @Published var isVisible: Bool = false

    /// Survives `reset()` on purpose — session identity, not a counter.
    @Published var isGuestSession: Bool = false

    /// Drives the sparkline chart in `ViewerStatsOverlay`.
    @Published var history: [HistorySample] = []

    /// 60 ≈ one minute, matching the overlay's width budget (~180px / 3px-per-sample).
    static let historyCapacity = 60

    func update(_ next: ViewerStats) {
        if next != stats { stats = next }  // avoid spurious SwiftUI re-renders
    }

    func appendHistory(_ sample: HistorySample) {
        var next = history
        next.append(sample)
        if next.count > Self.historyCapacity {
            next.removeFirst(next.count - Self.historyCapacity)
        }
        history = next
    }

    func reset() {
        stats = .empty
        history = []
    }
}

/// One per-second snapshot fed into the sparkline buffer. `nil` fields mark
/// gaps so the chart can break the line instead of drawing a fake zero.
struct HistorySample: Sendable, Equatable {
    var latencyMs: Double?
    var bitrateBps: Double?
    var droppedPct: Double?
}

/// Replaces `AVSampleBufferDisplayLayer`, whose background renderer
/// autoreleased work into the main-queue pool and produced a zombie-pointer
/// SIGSEGV on teardown.
///
/// Owned by `AppState` for the process lifetime — a prior disconnect race with
/// its own window/Metal layer pair was bad enough that neither is ever torn
/// down; callers `clearPendingBuffer` between sessions instead.
@available(macOS 14.0, *)
final class MetalViewerRenderer: NSObject, @unchecked Sendable {
    let metalLayer: CAMetalLayer

    /// -1 if never set.
    private(set) var lastPresentLatencyMs: Double = -1

    /// `(0,0)` until the first frame lands. Used by the host view to keep the
    /// annotation overlay aligned to the letterboxed video rect after a resize.
    private(set) var videoSize: CGSize = .zero
    /// Fires on the main thread.
    var onVideoSizeChanged: ((CGSize) -> Void)?

    /// Touched only from the display-link tick (main thread), so no lock needed.
    private var lastColorPrimaries: String?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    private let lock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var pendingReceiveUptimeNs: UInt64 = 0

    private var displayLink: CADisplayLink?
    private var isInvalidated = false
    private var framesPresented: Int = 0

    let statsModel = ViewerStatsModel()

    // MARK: stats counters (display-link/lock protected), all reset on `resetStats`

    private var framesDroppedTotal: Int = 0
    private var bucketFramesPresented: Int = 0
    private var bucketFramesDropped: Int = 0
    private var bucketBytesReceived: Int = 0
    /// Mach uptime ns.
    private var bucketStartNs: UInt64 = 0

    private var observedCodec: VideoCodec?

    /// Kept here rather than written straight into the stats model, since the
    /// 1Hz snapshot rebuilds `ViewerStats` from scratch and a model-only value
    /// would vanish after a second.
    private var observedColorLabel: String?

    /// Forces the next frame to re-derive the color label even with unchanged
    /// primaries — else `lastColorPrimaries` defeats the reset on a reconnect
    /// to the same sharer (nothing about the stream changed, so the label
    /// stays blank).
    private var colorNeedsRepublish = true

    private var decodeFailuresTotal: Int = 0
    /// `noteDecodeFailure` fires per failing frame (60Hz during a stress
    /// episode), so publishes coalesce to one in-flight main-queue block.
    /// Guarded by `lock`.
    private var decodeFailurePublishPending = false
    private var plisSentTotal: Int = 0
    private var nacksSentTotal: Int = 0
    private var fecRecoveredTotal: Int = 0
    private var degraded: Bool = false

    /// Traps on no Metal device or a shader compile failure — both indicate a
    /// misconfigured install, not something a caller can recover from.
    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MetalViewerRenderer: no Metal device")
        }
        guard let queue = device.makeCommandQueue() else {
            fatalError("MetalViewerRenderer: failed to create command queue")
        }
        self.device = device
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            fatalError("MetalViewerRenderer: shader compile failed: \(error)")
        }
        guard let vertexFn = library.makeFunction(name: "viewer_vertex"),
            let fragmentFn = library.makeFunction(name: "viewer_fragment")
        else {
            fatalError("MetalViewerRenderer: shader functions missing")
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            fatalError("MetalViewerRenderer: pipeline state creation failed: \(error)")
        }

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache = cache else {
            fatalError("MetalViewerRenderer: texture cache creation failed (\(cacheStatus))")
        }
        self.textureCache = cache

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        // Initial default; without it the compositor falls back to
        // generic-RGB gamma, rendering visibly different reds on P3 vs sRGB
        // displays. `render` re-tags from each buffer's actual primaries.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        self.metalLayer = layer

        super.init()
    }

    /// `view` must be in a window — `NSView.displayLink` picks up its current
    /// screen and re-targets if the window moves.
    @MainActor
    func start(in view: NSView) {
        guard displayLink == nil, !isInvalidated else { return }

        let link = view.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    /// Keeps only the most recent buffer; older ones are dropped and counted
    /// into `ViewerStats.framesDropped`.
    func setPixelBuffer(_ buffer: CVPixelBuffer, receiveUptimeNs: UInt64) {
        lock.lock()
        if pendingBuffer != nil {
            framesDroppedTotal += 1
            bucketFramesDropped += 1
        }
        pendingBuffer = buffer
        pendingReceiveUptimeNs = receiveUptimeNs
        lock.unlock()
    }

    /// Safe to call from any thread.
    func noteReceivedBytes(_ byteCount: Int) {
        lock.lock()
        bucketBytesReceived &+= byteCount
        lock.unlock()
    }

    /// Only forwards an update when the codec actually changes.
    func noteCodec(_ codec: VideoCodec) {
        lock.lock()
        let changed = observedCodec != codec
        observedCodec = codec
        lock.unlock()
        if changed {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var snap = self.statsModel.stats
                snap.codec = codec
                self.statsModel.update(snap)
            }
        }
    }

    /// Published without waiting for the display-link flush — a stalled
    /// stream stops rendering, so the flush stops firing.
    func noteDecodeFailure() {
        lock.lock()
        decodeFailuresTotal &+= 1
        let shouldPublish = !decodeFailurePublishPending
        if shouldPublish { decodeFailurePublishPending = true }
        lock.unlock()
        guard shouldPublish else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let total = self.decodeFailuresTotal
            self.decodeFailurePublishPending = false
            self.lock.unlock()
            var snap = self.statsModel.stats
            snap.decodeFailures = total
            self.statsModel.update(snap)
        }
    }

    func notePLISent() {
        lock.lock()
        plisSentTotal &+= 1
        let total = plisSentTotal
        lock.unlock()
        publishCounterUpdate { $0.plisSent = total }
    }

    func noteNACKSent() {
        lock.lock()
        nacksSentTotal &+= 1
        let total = nacksSentTotal
        lock.unlock()
        publishCounterUpdate { $0.nacksSent = total }
    }

    /// Never on the wire, so `noteReceivedBytes` is deliberately not called
    /// for it.
    func noteFECRecovered() {
        lock.lock()
        fecRecoveredTotal &+= 1
        let total = fecRecoveredTotal
        lock.unlock()
        publishCounterUpdate { $0.fecRecovered = total }
    }

    func setDegraded(_ isDegraded: Bool) {
        lock.lock()
        let changed = degraded != isDegraded
        degraded = isDegraded
        lock.unlock()
        guard changed else { return }
        publishCounterUpdate { $0.isDegraded = isDegraded }
    }

    /// Used by the counter hooks above, which can't wait for the next
    /// display-link flush — during a stall there isn't one.
    private func publishCounterUpdate(_ mutate: @escaping @Sendable (inout ViewerStats) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.statsModel.stats
            mutate(&snap)
            self.statsModel.update(snap)
        }
    }

    /// Call on connect so the new session doesn't inherit a stale drop rate.
    func resetStats() {
        lock.lock()
        framesDroppedTotal = 0
        bucketFramesPresented = 0
        bucketFramesDropped = 0
        bucketBytesReceived = 0
        bucketStartNs = 0
        observedCodec = nil
        observedColorLabel = nil
        colorNeedsRepublish = true
        decodeFailuresTotal = 0
        plisSentTotal = 0
        nacksSentTotal = 0
        fecRecoveredTotal = 0
        degraded = false
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.statsModel.reset()
        }
    }

    /// Next display-link tick presents a black drawable; doesn't stop the link.
    @MainActor
    func clearPendingBuffer() {
        lock.lock()
        pendingBuffer = nil
        pendingReceiveUptimeNs = 0
        lock.unlock()
    }

    /// No-op — kept for source compatibility; the display link stays attached
    /// for the process lifetime.
    @MainActor
    func invalidate() {}

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Per-tick rendering

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        if isInvalidated { return }

        // Take the buffer under the lock so the next `setPixelBuffer` observes
        // an empty slot; leaving it in place inflated droppedPct toward 50%.
        lock.lock()
        let buffer = pendingBuffer
        let receiveNs = pendingReceiveUptimeNs
        pendingBuffer = nil
        pendingReceiveUptimeNs = 0
        lock.unlock()

        guard let buffer = buffer else { return }
        render(buffer: buffer, receiveUptimeNs: receiveNs)
    }

    /// `lastColorPrimaries` short-circuits the common case where primaries
    /// never change.
    private func applyColorSpaceIfNeeded(from buffer: CVPixelBuffer) {
        let raw = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        let primaries = raw as? String
        lock.lock()
        let mustRepublish = colorNeedsRepublish
        lock.unlock()
        if primaries == lastColorPrimaries, !mustRepublish { return }
        lastColorPrimaries = primaries
        let name = ColorInfo.layerColorSpaceName(forPrimaries: primaries)
        metalLayer.colorspace = CGColorSpace(name: name)
        // Second consumer of the same attachments: the stats overlay. Sampled
        // here since it changes at most once per stream, same as the colorspace.
        let transferRaw = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil)
        let label = ColorInfo.statsLabel(primaries: primaries, transfer: transferRaw as? String)
        lock.lock()
        observedColorLabel = label
        colorNeedsRepublish = false
        lock.unlock()
    }

    private func render(buffer: CVPixelBuffer, receiveUptimeNs: UInt64) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        applyColorSpaceIfNeeded(from: buffer)

        var cvTexture: CVMetalTexture?
        let textureStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard textureStatus == kCVReturnSuccess,
            let cvTexture = cvTexture,
            let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            return
        }

        // Size the drawable to match the pixel buffer; the layer's
        // contentsGravity (.resizeAspect) letterboxes during composition.
        if metalLayer.drawableSize.width != CGFloat(width)
            || metalLayer.drawableSize.height != CGFloat(height)
        {
            let oldW = Int(metalLayer.drawableSize.width)
            let oldH = Int(metalLayer.drawableSize.height)
            metalLayer.drawableSize = CGSize(width: width, height: height)
            let newSize = CGSize(width: width, height: height)
            videoSize = newSize
            print("MetalRenderer: videoSize \(oldW)x\(oldH) -> \(width)x\(height)")
            let cb = onVideoSizeChanged
            DispatchQueue.main.async { cb?(newSize) }
        }

        guard let drawable = metalLayer.nextDrawable() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc)
        else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        framesPresented += 1
        var latencyMsThisFrame: Double?
        if receiveUptimeNs > 0 {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= receiveUptimeNs {
                let ms = Double(nowNs - receiveUptimeNs) / 1_000_000.0
                lastPresentLatencyMs = ms
                latencyMsThisFrame = ms
                if framesPresented == 1 || framesPresented % 60 == 0 {
                    print(
                        String(
                            format: "MetalRenderer: presented frame #%d recv→present=%.1fms",
                            framesPresented, ms))
                }
            }
        }

        publishStatsTick(latencyMsThisFrame: latencyMsThisFrame)
    }

    /// Set by `--ui-preview-video` to pin the seeded snapshot: that mode
    /// presents one frame and sits there, so the flush below would otherwise
    /// overwrite it with a dead-looking 0fps/no-codec reading.
    var suppressStatsPublishing = false

    private func publishStatsTick(latencyMsThisFrame: Double?) {
        if suppressStatsPublishing { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        if bucketStartNs == 0 { bucketStartNs = nowNs }
        bucketFramesPresented += 1
        let elapsedNs = nowNs &- bucketStartNs
        let totalPresented = framesPresented
        let totalDropped = framesDroppedTotal
        let codecSnap = observedCodec
        let colorLabelSnap = observedColorLabel
        let decodeFailuresSnap = decodeFailuresTotal
        let plisSentSnap = plisSentTotal
        let nacksSentSnap = nacksSentTotal
        let fecRecoveredSnap = fecRecoveredTotal
        let degradedSnap = degraded
        let bucketPresentedSnap = bucketFramesPresented
        let bucketDroppedSnap = bucketFramesDropped
        let bucketBytesSnap = bucketBytesReceived
        let shouldFlush = elapsedNs >= 1_000_000_000
        if shouldFlush {
            bucketFramesPresented = 0
            bucketFramesDropped = 0
            bucketBytesReceived = 0
            bucketStartNs = nowNs
        }
        lock.unlock()

        guard shouldFlush else {
            // Publish latency on every frame between flushes so the ms
            // readout doesn't sit stale for up to a second.
            if let latency = latencyMsThisFrame {
                let totalForUpdate = totalPresented
                let droppedForUpdate = totalDropped
                let codecForUpdate = codecSnap
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    var snap = self.statsModel.stats
                    snap.latencyMs = latency
                    snap.framesPresented = totalForUpdate
                    snap.framesDropped = droppedForUpdate
                    if let c = codecForUpdate { snap.codec = c }
                    self.statsModel.update(snap)
                }
            }
            return
        }

        let seconds = max(Double(elapsedNs) / 1_000_000_000.0, 0.0001)
        let fps = Double(bucketPresentedSnap) / seconds
        let denom = bucketPresentedSnap + bucketDroppedSnap
        let droppedPct: Double? =
            denom > 0
            ? (Double(bucketDroppedSnap) / Double(denom)) * 100.0
            : nil
        let bitrate = Double(bucketBytesSnap) * 8.0 / seconds

        let latencyForSnapshot: Double? =
            latencyMsThisFrame
            ?? (lastPresentLatencyMs >= 0 ? lastPresentLatencyMs : nil)

        let snapshot = ViewerStats(
            latencyMs: latencyForSnapshot,
            fps: fps,
            droppedPct: droppedPct,
            bitrateBps: bitrate,
            codec: codecSnap,
            framesPresented: totalPresented,
            framesDropped: totalDropped,
            decodeFailures: decodeFailuresSnap,
            plisSent: plisSentSnap,
            isDegraded: degradedSnap,
            nacksSent: nacksSentSnap,
            fecRecovered: fecRecoveredSnap,
            colorLabel: colorLabelSnap
        )
        let historySample = HistorySample(
            latencyMs: latencyForSnapshot,
            bitrateBps: bitrate,
            droppedPct: droppedPct
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.statsModel.update(snapshot)
            self.statsModel.appendHistory(historySample)
        }
    }

    // MARK: - Shaders

    // A trivial fullscreen textured quad. The vertex id indexes a strip of
    // four corners; UVs are flipped vertically so CV's top-left-origin
    // pixel buffers land right-side up on Metal's lower-left-origin NDC.
    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VSOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VSOut viewer_vertex(uint vid [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };
            VSOut out;
            out.position = float4(positions[vid], 0.0, 1.0);
            out.uv = uvs[vid];
            return out;
        }

        fragment float4 viewer_fragment(VSOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            return tex.sample(s, in.uv);
        }
        """
}
