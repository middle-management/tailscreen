import AppKit
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Displays decoded `CVPixelBuffer` frames on a `CAMetalLayer`, driven by a
/// `CADisplayLink`. Replaces `AVSampleBufferDisplayLayer`, whose background
/// renderer autoreleased work into the main-queue autorelease pool and
/// produced a zombie-pointer SIGSEGV on teardown.
///
/// Lifecycle is explicit: create, attach to a host view, feed pixel buffers
/// via `setPixelBuffer`, then `invalidate()` on main before dropping the
/// window. `CADisplayLink.invalidate()` detaches synchronously, and the
/// display link's selector runs on the main runloop, so after invalidate
/// returns no more render work is pending.
@available(macOS 14.0, *)
final class MetalViewerRenderer: NSObject, @unchecked Sendable {
    let metalLayer: CAMetalLayer

    /// Latency from frame arrival on the socket to presentation, in
    /// milliseconds. Snapshot at the last presented frame; -1 if never set.
    private(set) var lastPresentLatencyMs: Double = -1

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
              let fragmentFn = library.makeFunction(name: "viewer_fragment") else {
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
    /// older ones are dropped on the floor.
    func setPixelBuffer(_ buffer: CVPixelBuffer, receiveUptimeNs: UInt64) {
        lock.lock()
        pendingBuffer = buffer
        pendingReceiveUptimeNs = receiveUptimeNs
        lock.unlock()
    }

    /// Stop the display link and release GPU resources. Safe to call from
    /// main at any point in the lifecycle. `CADisplayLink.invalidate()`
    /// detaches the timer from the runloop synchronously, and because the
    /// selector fires on the main runloop no callback can race with this
    /// call — after `invalidate()` returns, no more Metal work is enqueued.
    @MainActor
    func invalidate() {
        if isInvalidated { return }
        isInvalidated = true

        if let link = displayLink {
            link.invalidate()
            self.displayLink = nil
        }

        lock.lock()
        pendingBuffer = nil
        lock.unlock()

        CVMetalTextureCacheFlush(textureCache, 0)
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Per-tick rendering

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        if isInvalidated { return }

        lock.lock()
        let buffer = pendingBuffer
        let receiveNs = pendingReceiveUptimeNs
        lock.unlock()

        guard let buffer = buffer else { return }
        render(buffer: buffer, receiveUptimeNs: receiveNs)
    }

    private func render(buffer: CVPixelBuffer, receiveUptimeNs: UInt64) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

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
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }

        // Size the drawable to match the pixel buffer; the layer's
        // contentsGravity (.resizeAspect) letterboxes during composition.
        if metalLayer.drawableSize.width != CGFloat(width)
            || metalLayer.drawableSize.height != CGFloat(height) {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }

        guard let drawable = metalLayer.nextDrawable() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        framesPresented += 1
        if receiveUptimeNs > 0 {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= receiveUptimeNs {
                let ms = Double(nowNs - receiveUptimeNs) / 1_000_000.0
                lastPresentLatencyMs = ms
                if framesPresented == 1 || framesPresented % 60 == 0 {
                    print(String(format: "MetalRenderer: presented frame #%d recv→present=%.1fms",
                                 framesPresented, ms))
                }
            }
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
