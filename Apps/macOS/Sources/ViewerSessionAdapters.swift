import CoreVideo
import Foundation
import TailscreenProtocol
import TailscreenViewer

// macOS adapters binding `ViewerSession`'s host-agnostic seams to the app's
// existing VideoToolbox decoder and Metal renderer, so the mac viewer can
// reuse the portable receive-side data plane. See
// docs/mac-viewer-convergence.md for the phased plan.
//
// Phase B: the adapters exist and are unit-tested, but are NOT yet wired into
// `TailscaleScreenShareClient` — that rewiring (behind a feature flag) is
// Phase C.

/// A `DecodedFrame` carrying a VideoToolbox `CVPixelBuffer`. The buffer is
/// IOSurface-backed and Metal-compatible, so keeping it as the frame currency
/// preserves the zero-copy VT→Metal path as it flows through `ViewerSession`
/// (which treats every frame as opaque).
///
/// `@unchecked Sendable`: a `CVPixelBuffer` isn't `Sendable`, but the box is
/// handed off single-owner across the decoder's callback-queue hop and never
/// mutated, so we own the invariant (the codebase's `@unchecked Sendable`
/// convention).
struct CVPixelBufferBox: DecodedFrame, @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// Monotonic clock reading of when the source AU was submitted, forwarded
    /// to the renderer for the stats overlay's decode-latency estimate.
    let receiveUptimeNs: UInt64

    var width: Int { CVPixelBufferGetWidth(buffer) }
    var height: Int { CVPixelBufferGetHeight(buffer) }
}

/// `VideoSink` over the app's `MetalViewerRenderer`: forwards the boxed
/// `CVPixelBuffer` straight to the zero-copy Metal upload path. A frame that
/// isn't a `CVPixelBufferBox` can't arise here (the paired VT decoder only
/// emits that type) and is dropped.
final class MetalSinkAdapter: VideoSink {
    private let renderer: MetalViewerRenderer

    init(renderer: MetalViewerRenderer) {
        self.renderer = renderer
    }

    func present(_ frame: any DecodedFrame) {
        guard let box = frame as? CVPixelBufferBox else { return }
        renderer.setPixelBuffer(box.buffer, receiveUptimeNs: box.receiveUptimeNs)
    }
}

/// `VideoDecoding` over the app's `VideoDecoder` (VideoToolbox). It hides two
/// mac-specific details from `ViewerSession`: it extracts the in-band parameter
/// sets from each keyframe and installs them before decoding (the session's
/// model is "the decoder extracts them"), and it bridges VideoToolbox's
/// asynchronous `CVPixelBuffer`-callback delivery to the session's
/// `onDecodedFrame` seam — hopping to a host-supplied serialization queue
/// first, per `VideoDecoding`'s threading contract.
///
/// `@unchecked Sendable`: `installedParameters` is touched only from the host's
/// serialization queue in `decode`; `lastSubmitUptimeNs` is written there and
/// read on VideoToolbox's callback thread for a best-effort latency stamp (the
/// same approximation the client's `lastReceiveUptimeNs` makes today), which is
/// benign.
final class VTVideoDecoderAdapter: VideoDecoding, @unchecked Sendable {
    var onDecodedFrame: ((any DecodedFrame) -> Void)?
    var onDecodeFailure: (() -> Void)?

    /// Mac-only decode-recovery / codec-fallback pass-throughs. These bypass
    /// `ViewerSession` entirely — it never inspects decoded frames — and fire on
    /// the underlying decoder's serial queue (no `callbackQueue` hop), exactly as
    /// the legacy client wired the raw `VideoDecoder` callbacks. The host uses
    /// them to drive the CODEC_NO (`0x07`) H.264 fallback and the
    /// `DecodeRecoveryAction` escalation ladder that the session's naive
    /// `onDecodeFailure → PLI` doesn't cover.
    ///
    /// `onCodecUnsupported` carries the codec the decoder couldn't build a
    /// session for (so the host can ask the sharer to switch codecs); because it
    /// takes over the underlying decoder's `onDecodeFailure`, the session's own
    /// `onDecodeFailure` seam is left unused on mac — the ladder owns PLIs.
    var onCodecUnsupported: ((VideoCodec) -> Void)?
    var onFrameDecodeFailed: (() -> Void)?
    var onRecoveryAction: ((DecodeRecoveryAction) -> Void)?
    var onRecovered: (() -> Void)?

    /// Test-only: fires with each decoded `CVPixelBuffer` on the decoder's
    /// output thread, *before* the `callbackQueue` hop — the client forwards it
    /// to its `onDecodedFrameForTesting` seam (the E2E suites assert a frame
    /// decoded, off the windowed render path xctest lacks). Matches the legacy
    /// loop's firing thread/order.
    var onDecodedPixelBufferForTesting: ((CVPixelBuffer) -> Void)?

    private let decoder: VideoDecoder
    private let callbackQueue: DispatchQueue
    private var installedParameters: CodecParameterSets?
    private var lastSubmitUptimeNs: UInt64 = 0

    /// - Parameters:
    ///   - decoder: the VideoToolbox decoder to drive (defaults to a fresh one).
    ///   - callbackQueue: the host's serialization queue — the one it drives the
    ///     `ViewerSession` on. VideoToolbox delivers frames on its own thread,
    ///     so the adapter hops here before invoking the session's callbacks.
    init(decoder: VideoDecoder = VideoDecoder(), callbackQueue: DispatchQueue) {
        self.decoder = decoder
        self.callbackQueue = callbackQueue

        decoder.onDecodedFrame = { [weak self] buffer in
            guard let self else { return }
            self.onDecodedPixelBufferForTesting?(buffer)
            let box = CVPixelBufferBox(buffer: buffer, receiveUptimeNs: self.lastSubmitUptimeNs)
            self.callbackQueue.async { self.onDecodedFrame?(box) }
        }
        // "Can't build a decompression session" (typically HEVC on a Mac
        // without HEVC decode): route to the CODEC_NO H.264 fallback with the
        // offending codec, not the session's plain PLI (a fresh keyframe in the
        // same undecodable codec wouldn't help). Fires on the decoder's queue.
        decoder.onDecodeFailure = { [weak self] codec in
            self?.onCodecUnsupported?(codec)
        }
        // The per-frame decode-failure stats signal and the consecutive-failure
        // escalation ladder pass straight through to the host (no session hop).
        decoder.onFrameDecodeFailed = { [weak self] in self?.onFrameDecodeFailed?() }
        decoder.onRecoveryAction = { [weak self] action in self?.onRecoveryAction?(action) }
        decoder.onRecovered = { [weak self] in self?.onRecovered?() }
    }

    func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool) {
        lastSubmitUptimeNs = DispatchTime.now().uptimeNanoseconds
        // Parameter sets ride in-band on every IDR; install them before
        // decoding (VideoDecoder rebuilds its session only when they actually
        // change — the diff avoids a needless teardown per keyframe).
        if isKeyframe {
            let params = Self.parameterSets(fromAVCC: accessUnit, codec: codec)
            if let params, params != installedParameters {
                installedParameters = params
                decoder.setParameterSets(params)
            }
        }
        decoder.decode(data: accessUnit, isKeyframe: isKeyframe)
    }

    /// Pull SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) out of an AVCC access unit —
    /// the same in-band extraction the client's `extractParameterSets` does,
    /// specialized to raw AVCC + codec. Internal for unit testing.
    static func parameterSets(fromAVCC avcc: Data, codec: VideoCodec) -> CodecParameterSets? {
        let nals = AVCCParser.nalUnits(from: avcc)
        switch codec {
        case .h264:
            var sps: Data?
            var pps: Data?
            for nal in nals {
                guard let header = nal.first else { continue }
                switch header & 0x1F {
                case 7: sps = nal
                case 8: pps = nal
                default: break
                }
            }
            guard let sps, let pps else { return nil }
            return .h264(sps: sps, pps: pps)
        case .hevc:
            var vps: Data?
            var sps: Data?
            var pps: Data?
            for nal in nals {
                guard let header = nal.first else { continue }
                switch (header >> 1) & 0x3F {
                case 32: vps = nal
                case 33: sps = nal
                case 34: pps = nal
                default: break
                }
            }
            guard let vps, let sps, let pps else { return nil }
            return .hevc(vps: vps, sps: sps, pps: pps)
        }
    }
}
