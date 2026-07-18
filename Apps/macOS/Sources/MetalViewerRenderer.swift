import AppKit
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Snapshot of viewer-side health metrics shown by the optional stats
/// overlay. Plain value type so it can be diffed for `@Published` updates
/// without touching the renderer's internal bookkeeping. All counters are
/// "since this session began rendering" — they reset on `resetStats()`.
///
/// `codec` and `bitrateBps` are best-effort: the codec is detected from
/// the first RTP packet's payload type and the bitrate is a 1-second
/// sliding window over received-from-network bytes (so it captures the
/// actual wire load, not the encoder's internal target).
struct ViewerStats: Sendable, Equatable {
    /// Most recent receive-to-present latency in milliseconds, or `nil`
    /// if no frame has been presented yet.
    var latencyMs: Double?
    /// Frames presented per second, averaged over a 1 s window. Updates
    /// on the display link tick.
    var fps: Double
    /// Percentage of dropped frames in the last reporting window.
    /// `replacePendingBuffer` overwrites a not-yet-rendered buffer; that
    /// counts as a drop. `nil` if not yet sampled.
    var droppedPct: Double?
    /// Rolling 1 s bitrate in bits/sec measured from the receive socket,
    /// or `nil` if not yet sampled. Server-side encoder target lives on
    /// the sharer, not the viewer, so this is the wire-level approximation.
    var bitrateBps: Double?
    /// Codec carried on the wire, learned from the RTP payload type.
    /// `nil` until the first video packet lands.
    var codec: VideoCodec?
    /// Total frames presented since the stats were last reset.
    var framesPresented: Int
    /// Total frames dropped (overwritten before render) since reset.
    var framesDropped: Int
    /// Per-frame decode failures reported by the viewer's decoder since
    /// reset (see `VideoDecoder.onFrameDecodeFailed`).
    var decodeFailures: Int
    /// PLIs (keyframe requests) sent to the sharer since reset — both
    /// loss-driven and decode-ladder-driven, post-throttle.
    var plisSent: Int
    /// True while the decode-failure escalation ladder considers the
    /// connection degraded; cleared when decoding recovers.
    var isDegraded: Bool
    /// NACK datagrams sent to the sharer since reset (selective-retransmit
    /// requests). On a lossy link this should rise while `plisSent` stays low —
    /// the whole point of the retransmit path vs. the old keyframe storm.
    var nacksSent: Int
    /// Packets reconstructed from XOR parity (FEC) since reset. On a lossy
    /// high-RTT link this should rise while `nacksSent` AND `plisSent` stay
    /// near zero — the net-impair validation signal for the FEC path.
    var fecRecovered: Int

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
        fecRecovered: 0
    )
}

/// Observable wrapper around `ViewerStats` so SwiftUI views can subscribe
/// with `@ObservedObject`. The renderer pushes new snapshots in from the
/// display-link tick (already on the main thread); the client pushes codec
/// + byte-counter updates from the receive task via a `DispatchQueue.main`
/// hop so all `@Published` writes happen on main.
///
/// Not annotated `@MainActor` so it can be stored as a `let` on the
/// non-isolated `MetalViewerRenderer`; `@unchecked Sendable` carries the
/// invariant that all mutating calls hop to main first.
final class ViewerStatsModel: ObservableObject, @unchecked Sendable {
    @Published var stats: ViewerStats = .empty

    /// Toggled by the toolbar's "Show Stats" button. Bound directly into
    /// the overlay's hosting view's `isHidden`.
    @Published var isVisible: Bool = false

    /// Rolling history of the last `historyCapacity` per-second snapshots:
    /// latency in ms, bitrate in bps, drop percentage. Drives the sparkline
    /// chart in `ViewerStatsOverlay`. Appended to on every 1 s flush from
    /// `publishStatsTick`; oldest sample evicted on overflow.
    @Published var history: [HistorySample] = []

    /// Number of 1 s buckets retained for the sparkline. 60 ≈ one minute,
    /// matches the width budget of the overlay (~180 px / 3 px-per-sample).
    static let historyCapacity = 60

    func update(_ next: ViewerStats) {
        // Avoid spurious SwiftUI re-renders on identical snapshots.
        if next != stats { stats = next }
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

/// Displays decoded `CVPixelBuffer` frames on a `CAMetalLayer`, driven by a
/// `CADisplayLink`. Replaces `AVSampleBufferDisplayLayer`, whose background
/// renderer autoreleased work into the main-queue autorelease pool and
/// produced a zombie-pointer SIGSEGV on teardown.
///
/// Owned by `AppState` for the process lifetime — the disconnect race we
/// hit when this owned its own window/Metal layer pair was bad enough that
/// we now never tear either down. Between sessions, callers `clearPendingBuffer`
/// to drop the last presented frame; the display link stays attached to the
/// host view for the lifetime of the process.
@available(macOS 14.0, *)
final class MetalViewerRenderer: NSObject, @unchecked Sendable {
    let metalLayer: CAMetalLayer

    /// Latency from frame arrival on the socket to presentation, in
    /// milliseconds. Snapshot at the last presented frame; -1 if never set.
    private(set) var lastPresentLatencyMs: Double = -1

    /// Native video resolution of the most recent decoded frame.
    /// `(0,0)` until the first frame lands. Used by the host view to keep
    /// the annotation overlay aligned to the letterboxed video rect — a
    /// click at "the centre of the video" must still hit the same pixel
    /// after the window is resized to a different aspect ratio.
    private(set) var videoSize: CGSize = .zero
    /// Fires (on the main thread) whenever `videoSize` changes.
    var onVideoSizeChanged: ((CGSize) -> Void)?

    /// Last color-primaries attachment string applied to the layer's
    /// colorspace, so `render` only re-tags the `CAMetalLayer` when the
    /// stream's primaries actually change. Touched only from the display-link
    /// tick (main thread), so it needs no lock. `nil` until the first frame.
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

    /// Observable model the stats overlay binds to. Updated on the main
    /// thread from the display-link tick and from client-side packet
    /// hand-offs (see `noteReceivedBytes` / `noteCodec`).
    let statsModel = ViewerStatsModel()

    // MARK: stats counters (display-link/lock protected)

    /// Frames overwritten before they could be rendered. A drop happens
    /// when `setPixelBuffer` is called while `pendingBuffer` is still
    /// non-nil. Reset on `resetStats`.
    private var framesDroppedTotal: Int = 0
    /// Frames presented in the current 1 s bucket.
    private var bucketFramesPresented: Int = 0
    /// Frames dropped in the current 1 s bucket.
    private var bucketFramesDropped: Int = 0
    /// Bytes received in the current 1 s bucket (set by the client via
    /// `noteReceivedBytes`).
    private var bucketBytesReceived: Int = 0
    /// Start of the current 1 s sampling window, in mach uptime ns.
    private var bucketStartNs: UInt64 = 0

    /// Codec observed on the wire. Set by the client when it detects the
    /// RTP payload type. Pure metadata — the renderer doesn't act on it.
    private var observedCodec: VideoCodec?

    /// Decode failures reported via `noteDecodeFailure`. Reset on `resetStats`.
    private var decodeFailuresTotal: Int = 0
    /// True while a decode-failure publish is already queued on main.
    /// `noteDecodeFailure` fires per failing frame (60 Hz during exactly the
    /// stress episodes), so publishes are coalesced: at most one main-queue
    /// block in flight, reading the then-current total when it runs.
    /// Guarded by `lock`.
    private var decodeFailurePublishPending = false
    /// PLIs reported via `notePLISent`. Reset on `resetStats`.
    private var plisSentTotal: Int = 0
    /// NACK datagrams reported via `noteNACKSent`. Reset on `resetStats`.
    private var nacksSentTotal: Int = 0
    /// FEC-recovered packets reported via `noteFECRecovered`. Reset on
    /// `resetStats`.
    private var fecRecoveredTotal: Int = 0
    /// Degraded indication driven via `setDegraded`. Reset on `resetStats`.
    private var degraded: Bool = false

    /// Traps if the machine has no Metal device (very old Macs) or the
    /// shader library fails to compile — both indicate a misconfigured
    /// install rather than anything a caller could recover from.
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
        // Tag the layer with sRGB so the compositor doesn't fall back to
        // generic-RGB gamma assumptions on the captured BT.709 stream.
        // Without this tag the same pixels can render visibly different
        // shades of red on Display P3 displays vs sRGB displays. This is the
        // initial default; `render` re-tags the layer from each decoded
        // buffer's actual color primaries (Display P3 / BT.2020) so
        // wide-gamut streams aren't clipped to sRGB.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        self.metalLayer = layer

        super.init()
    }

    /// Start driving this renderer from `view`'s display link. The view
    /// must be in a window — `NSView.displayLink` picks up the screen the
    /// view is currently on and re-targets if the window moves. Must be
    /// called on the main thread.
    @MainActor
    func start(in view: NSView) {
        guard displayLink == nil, !isInvalidated else { return }

        let link = view.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    /// Hand in the latest decoded frame. Called from the decoder's output
    /// callback thread. The renderer only keeps the most recent buffer;
    /// older ones are dropped on the floor — those drops are counted into
    /// `ViewerStats.framesDropped` so the overlay can surface them.
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

    /// Client hook: account for `byteCount` bytes that just landed on the
    /// receive socket. Used to compute the live bitrate shown in the stats
    /// overlay. Safe to call from any thread.
    func noteReceivedBytes(_ byteCount: Int) {
        lock.lock()
        bucketBytesReceived &+= byteCount
        lock.unlock()
    }

    /// Client hook: record the codec carried on the wire, as detected from
    /// the RTP payload type. Cheap to call repeatedly — only forwards an
    /// update when the codec actually changes.
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

    /// Client hook: one per-frame decode failure reported by the decoder.
    /// Safe to call from any thread. Published without waiting for the
    /// display-link flush — a stalled stream stops rendering, so the flush
    /// stops firing — but coalesced to one pending main-queue publish at a
    /// time so a 60 Hz failure storm doesn't drive 60 Hz SwiftUI updates.
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

    /// Client hook: one PLI (keyframe request) actually sent to the sharer
    /// (post-throttle). Safe to call from any thread.
    func notePLISent() {
        lock.lock()
        plisSentTotal &+= 1
        let total = plisSentTotal
        lock.unlock()
        publishCounterUpdate { $0.plisSent = total }
    }

    /// Client hook: one NACK datagram sent to the sharer (a selective
    /// retransmit request). Safe to call from any thread.
    func noteNACKSent() {
        lock.lock()
        nacksSentTotal &+= 1
        let total = nacksSentTotal
        lock.unlock()
        publishCounterUpdate { $0.nacksSent = total }
    }

    /// Client hook: one packet reconstructed from FEC parity (never on the
    /// wire, so `noteReceivedBytes` is deliberately NOT called for it).
    /// Safe to call from any thread.
    func noteFECRecovered() {
        lock.lock()
        fecRecoveredTotal &+= 1
        let total = fecRecoveredTotal
        lock.unlock()
        publishCounterUpdate { $0.fecRecovered = total }
    }

    /// Client hook: flip the degraded-connection indication driven by the
    /// decoder's escalation ladder. Safe to call from any thread; no-ops
    /// when the flag hasn't changed.
    func setDegraded(_ isDegraded: Bool) {
        lock.lock()
        let changed = degraded != isDegraded
        degraded = isDegraded
        lock.unlock()
        guard changed else { return }
        publishCounterUpdate { $0.isDegraded = isDegraded }
    }

    /// Push a small mutation of the current stats snapshot to the model on
    /// the main thread. Used by the counter hooks above, which can't wait
    /// for the next display-link flush — during a stall there isn't one.
    private func publishCounterUpdate(_ mutate: @escaping @Sendable (inout ViewerStats) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var snap = self.statsModel.stats
            mutate(&snap)
            self.statsModel.update(snap)
        }
    }

    /// Reset the stats counters. Call on connect so the new session
    /// doesn't inherit a 30 % drop rate from a previous flaky connection.
    func resetStats() {
        lock.lock()
        framesDroppedTotal = 0
        bucketFramesPresented = 0
        bucketFramesDropped = 0
        bucketBytesReceived = 0
        bucketStartNs = 0
        observedCodec = nil
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

    /// Drop the latest frame so the next display-link tick presents a black
    /// drawable. Safe to call from main; doesn't stop the link.
    @MainActor
    func clearPendingBuffer() {
        lock.lock()
        pendingBuffer = nil
        pendingReceiveUptimeNs = 0
        lock.unlock()
    }

    /// No-op. Renderer is owned by `AppState` for the process lifetime; the
    /// display link stays attached so reconnects can resume rendering without
    /// reattaching to the host view. Kept for source compatibility.
    @MainActor
    func invalidate() {}

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Per-tick rendering

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        if isInvalidated { return }

        // Consume the pending buffer: take it out under the lock so the next
        // `setPixelBuffer` call observes an empty slot and does NOT count its
        // frame as dropped. Leaving the buffer in place after presenting was
        // the prior behavior and made every subsequent decoder frame look
        // like a drop, inflating `droppedPct` toward 50% on a steady stream.
        lock.lock()
        let buffer = pendingBuffer
        let receiveNs = pendingReceiveUptimeNs
        pendingBuffer = nil
        pendingReceiveUptimeNs = 0
        lock.unlock()

        guard let buffer = buffer else { return }
        render(buffer: buffer, receiveUptimeNs: receiveNs)
    }

    /// Read the decoded buffer's `kCVImageBufferColorPrimariesKey` attachment
    /// and, when it differs from what's currently applied, re-tag the
    /// `CAMetalLayer` colorspace to match (Display P3 / BT.2020, else sRGB).
    /// Runs on the display-link tick (main thread); `lastColorPrimaries`
    /// short-circuits the common case where the primaries never change.
    private func applyColorSpaceIfNeeded(from buffer: CVPixelBuffer) {
        let raw = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        let primaries = raw as? String
        if primaries == lastColorPrimaries { return }
        lastColorPrimaries = primaries
        let name = ColorInfo.layerColorSpaceName(forPrimaries: primaries)
        metalLayer.colorspace = CGColorSpace(name: name)
    }

    private func render(buffer: CVPixelBuffer, receiveUptimeNs: UInt64) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        // Re-tag the layer's colorspace from the decoded buffer's color
        // primaries (VideoToolbox populated them from the SPS VUI). Display P3
        // and BT.2020 streams would otherwise be clipped to the sRGB tag set
        // at init. Only touched when the primaries change (rare — once per
        // stream), so it stays off the per-frame hot path.
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

    /// Update the 1 s rolling bucket and, when it fills, hand a fresh
    /// `ViewerStats` snapshot to the observable model. Called once per
    /// rendered frame from the display-link tick (main thread).
    private func publishStatsTick(latencyMsThisFrame: Double?) {
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        if bucketStartNs == 0 { bucketStartNs = nowNs }
        bucketFramesPresented += 1
        let elapsedNs = nowNs &- bucketStartNs
        let totalPresented = framesPresented
        let totalDropped = framesDroppedTotal
        let codecSnap = observedCodec
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
            // Between flushes still publish the latency on every frame so
            // the overlay's ms readout doesn't sit at a stale value for
            // up to a full second.
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
            fecRecovered: fecRecoveredSnap
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
