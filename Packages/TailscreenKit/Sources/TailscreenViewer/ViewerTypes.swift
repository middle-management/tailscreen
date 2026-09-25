import Foundation
import TailscreenProtocol

// The host-agnostic seam of the portable viewer data-plane. `ViewerSession`
// turns inbound RTP into decoded frames + audio + outbound feedback bytes
// without owning a socket/thread/timer or linking a concrete codec/renderer/
// audio backend. These value/protocol types are that seam, so this target
// stays Foundation-only and Linux-buildable (see the package README).

/// A decoded video frame the session routes **without inspecting** — opaque
/// to `ViewerSession` so the type can be CPU I420 (`DecodedVideoFrame`, the
/// FFmpeg→GTK-GL path) or a platform-native handle (e.g. a boxed
/// `CVPixelBuffer` for zero-copy VideoToolbox→Metal) without this target
/// importing CoreVideo. The sink downcasts to the concrete type it and its
/// paired decoder agree on. Only **dimensions** are required here — cheap for
/// every backing and enough for a generic decorator or stats overlay.
public protocol DecodedFrame {
    var width: Int { get }
    var height: Int { get }
}

/// One decoded video frame in packed 8-bit YUV 4:2:0 (I420) planar form. The
/// default `DecodedFrame` — the Linux/portable instantiation of the seam.
/// Plane layout matches the FFmpeg decoder's output but is FFmpeg-agnostic.
/// `yPlane` is `width × height`; `uPlane`/`vPlane` are each
/// `⌈width/2⌉ × ⌈height/2⌉`, tightly packed with no row padding.
public struct DecodedVideoFrame: Sendable, Equatable, DecodedFrame {
    public let width: Int
    public let height: Int
    /// `width × height` luma (Y) samples, row-major.
    public let yPlane: [UInt8]
    /// `⌈width/2⌉ × ⌈height/2⌉` blue-difference chroma (U/Cb) samples.
    public let uPlane: [UInt8]
    /// `⌈width/2⌉ × ⌈height/2⌉` red-difference chroma (V/Cr) samples.
    public let vPlane: [UInt8]
    /// What the decoder learned about how these samples encode colour.
    /// `range` is the half a renderer MUST honour: full-range samples (every
    /// default macOS share) rendered with limited-range maths lose their
    /// shadows and highlights. Defaults to `.unspecifiedLimited` so callers
    /// predating this field keep their old behaviour.
    public let colorInfo: VideoColorInfo

    public init(
        width: Int,
        height: Int,
        yPlane: [UInt8],
        uPlane: [UInt8],
        vPlane: [UInt8],
        colorInfo: VideoColorInfo = .unspecifiedLimited
    ) {
        self.width = width
        self.height = height
        self.yPlane = yPlane
        self.uPlane = uPlane
        self.vPlane = vPlane
        self.colorInfo = colorInfo
    }
}

/// A concrete video decoder the host supplies. `ViewerSession` submits one
/// reassembled AVCC access unit at a time via `decode`, and receives frames
/// back through `onDecodedFrame` — synchronously within `decode` for a
/// synchronous backend (FFmpeg, or a test stub), or later for an async one
/// (VideoToolbox, whose session delivers on its own thread). A decode failure
/// is signalled via `onDecodeFailure`; the session answers with a PLI
/// (keyframe request).
///
/// **Threading contract.** Both callbacks MUST be invoked on the same
/// serialization context the host drives the session on. A synchronous
/// backend gets this for free; an async one must hop back to that context —
/// `ViewerSession` is not `Sendable` and owns no queue of its own.
public protocol VideoDecoding: AnyObject {
    /// Invoked once per decoded frame, routed straight to the `VideoSink`
    /// without inspection — a decoder may emit CPU I420 or a platform-native
    /// handle its paired sink understands.
    var onDecodedFrame: ((any DecodedFrame) -> Void)? { get set }

    /// Invoked on decode failure (submit error or async decode error); the
    /// session responds with a PLI. A backend with its own recovery ladder
    /// should call this only when it wants the sharer to intervene.
    var onDecodeFailure: (() -> Void)? { get set }

    /// Submits one AVCC-formatted access unit. `codec` is deterministically
    /// known from the RTP payload type. `isKeyframe` is true when the AU
    /// carries an IDR (in-band parameter sets, if any, are inside
    /// `accessUnit`). Frames/failures are delivered via the callbacks above.
    func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool)
}

/// Where decoded frames go — the host's renderer (Metal on macOS, SDL/GL on
/// Linux, or a test collector). The frame is the opaque `DecodedFrame` the
/// paired decoder produced; the sink downcasts to its own concrete type.
public protocol VideoSink: AnyObject {
    func present(_ frame: any DecodedFrame)
}

/// Where decoded audio PCM goes — the host's audio output. PCM is 48 kHz mono
/// Float32 in `[-1, 1]`, 960 samples per 20 ms Opus frame (the same contract
/// `OpusVoiceDecoder` produces).
public protocol AudioSink: AnyObject {
    func play(_ pcm: [Float])
}
