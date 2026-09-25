import CoreVideo
import Foundation
import TailscreenProtocol
import TailscreenViewer

// macOS adapters binding `ViewerSession`'s host-agnostic seams to the app's
// VideoToolbox decoder and Metal renderer, so the mac viewer reuses the
// portable receive-side data plane.

/// The buffer is IOSurface-backed and Metal-compatible, so keeping it as the
/// frame currency preserves the zero-copy VT->Metal path through
/// `ViewerSession` (which treats every frame as opaque).
///
/// `@unchecked Sendable`: not `Sendable`, but handed off single-owner across
/// the decoder's callback-queue hop and never mutated.
struct CVPixelBufferBox: DecodedFrame, @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// Forwarded to the renderer for the stats overlay's decode-latency estimate.
    let receiveUptimeNs: UInt64

    var width: Int { CVPixelBufferGetWidth(buffer) }
    var height: Int { CVPixelBufferGetHeight(buffer) }
}

/// A frame that isn't a `CVPixelBufferBox` can't arise here (the paired VT
/// decoder only emits that type) and is dropped.
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

/// Hides two mac-specific details from `ViewerSession`: extracts in-band
/// parameter sets from each keyframe before decoding, and bridges
/// VideoToolbox's async callback to the session's `onDecodedFrame` seam by
/// hopping to a host-supplied serialization queue.
///
/// `@unchecked Sendable`: `installedParameters` is touched only in `decode`;
/// `lastSubmitUptimeNs` is written there and read on VideoToolbox's callback
/// thread for a best-effort latency stamp, which is benign.
final class VTVideoDecoderAdapter: VideoDecoding, @unchecked Sendable {
    var onDecodedFrame: ((any DecodedFrame) -> Void)?
    var onDecodeFailure: (() -> Void)?

    /// Bypass `ViewerSession` entirely to drive the CODEC_NO H.264 fallback
    /// and the `DecodeRecoveryAction` ladder, which `VideoDecoder` runs
    /// internally on mac. Load-bearing non-wiring: `ViewerSession` can run the
    /// same ladder for hosts that report per-frame failures through its own
    /// seam (Linux/Windows), so the mac client must never also invoke the
    /// session's `onDecodeFailure` — that would double-ladder one episode.
    var onCodecUnsupported: ((VideoCodec) -> Void)?
    var onFrameDecodeFailed: (() -> Void)?
    var onRecoveryAction: ((DecodeRecoveryAction) -> Void)?
    var onRecovered: (() -> Void)?

    /// Test-only: fires before the `callbackQueue` hop, matching the legacy
    /// loop's firing thread/order — E2E suites assert a decoded frame off the
    /// windowed render path xctest lacks.
    var onDecodedPixelBufferForTesting: ((CVPixelBuffer) -> Void)?

    private let decoder: VideoDecoder
    private let callbackQueue: DispatchQueue
    private var installedParameters: CodecParameterSets?
    private var lastSubmitUptimeNs: UInt64 = 0

    /// `callbackQueue`: the host's `ViewerSession` serialization queue.
    /// VideoToolbox delivers frames on its own thread, so the adapter hops
    /// here first.
    init(decoder: VideoDecoder = VideoDecoder(), callbackQueue: DispatchQueue) {
        self.decoder = decoder
        self.callbackQueue = callbackQueue

        decoder.onDecodedFrame = { [weak self] buffer in
            guard let self else { return }
            self.onDecodedPixelBufferForTesting?(buffer)
            let box = CVPixelBufferBox(buffer: buffer, receiveUptimeNs: self.lastSubmitUptimeNs)
            self.callbackQueue.async { self.onDecodedFrame?(box) }
        }
        // Route to CODEC_NO H.264 fallback, not a plain PLI — a fresh keyframe
        // in the same undecodable codec wouldn't help.
        decoder.onDecodeFailure = { [weak self] codec in
            self?.onCodecUnsupported?(codec)
        }
        decoder.onFrameDecodeFailed = { [weak self] in self?.onFrameDecodeFailed?() }
        decoder.onRecoveryAction = { [weak self] action in self?.onRecoveryAction?(action) }
        decoder.onRecovered = { [weak self] in self?.onRecovered?() }
    }

    func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool) {
        lastSubmitUptimeNs = DispatchTime.now().uptimeNanoseconds
        // VideoDecoder rebuilds its session only when parameters actually
        // change, avoiding a teardown per keyframe.
        if isKeyframe {
            let params = Self.parameterSets(fromAVCC: accessUnit, codec: codec)
            if let params, params != installedParameters {
                installedParameters = params
                decoder.setParameterSets(params)
            }
        }
        decoder.decode(data: accessUnit, isKeyframe: isKeyframe)
    }

    /// This wrapper only supplies the AVCC split; the portable
    /// `ParameterSetExtraction` does the rest, since an AVCC-split NAL and an
    /// Annex-B-split NAL are the same bytes once the prefix/start code is gone.
    static func parameterSets(fromAVCC avcc: Data, codec: VideoCodec) -> CodecParameterSets? {
        ParameterSetExtraction.parameterSets(
            fromAnnexBNALs: AVCCParser.nalUnits(from: avcc), codec: codec)
    }
}
