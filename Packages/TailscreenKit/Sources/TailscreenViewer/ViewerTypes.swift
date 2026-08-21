import Foundation
import TailscreenProtocol

// The host-agnostic seam of the portable viewer data-plane. `ViewerSession`
// (see ViewerSession.swift) turns inbound RTP into decoded frames + audio +
// outbound feedback bytes without owning a socket, a thread, or a timer, and
// without linking any concrete codec/renderer/audio backend. These value and
// protocol types are that seam: the Linux viewer plugs the real FFmpeg decoder /
// GTK-GL renderer / ALSA sink in behind them, while THIS target stays
// Foundation-only and Linux-buildable (no FFmpeg/GTK/ALSA dependency — see the
// package README).

/// A decoded video frame the session routes **without inspecting** — a marker
/// so the concrete frame type is opaque to `ViewerSession`. The decoder produces
/// `DecodedFrame`s and the sink consumes them; the session only carries them
/// from one to the other, so the type is whatever the host's decoder/renderer
/// pair agrees on: CPU I420 (`DecodedVideoFrame`) for the FFmpeg→GTK-GL path, or a
/// platform-native handle (e.g. a `CVPixelBuffer` box on macOS) for a zero-copy
/// VideoToolbox→Metal path — without the portable target importing CoreVideo.
/// `ViewerSession` never reads a frame; the sink downcasts to its own concrete
/// type (a decoder/sink pair always agree on it) to reach the pixels. The only
/// requirements are the frame **dimensions** — cheap for every backing (I420
/// carries them; `CVPixelBufferGetWidth/Height` on a mac box) and exactly what
/// a generic decorator or stats overlay needs, so those don't have to downcast.
public protocol DecodedFrame {
    /// Frame width in luma samples.
    var width: Int { get }
    /// Frame height in luma samples.
    var height: Int { get }
}

/// One decoded video frame in packed 8-bit YUV 4:2:0 (I420) planar form.
///
/// The plane layout deliberately matches what the FFmpeg decoder in
/// `Packages/FFmpegKit` emits, so a later adapter can hand its output straight
/// to a `VideoSink` — but this struct pulls in nothing FFmpeg-specific, keeping
/// the viewer core dependency-free. `yPlane` is `width × height` luma samples;
/// `uPlane` / `vPlane` are each `⌈width/2⌉ × ⌈height/2⌉` chroma samples
/// (tightly packed, no row padding — the host/adapter owns any stride reshuffle).
///
/// The default `DecodedFrame` — the Linux/portable instantiation of the seam.
public struct DecodedVideoFrame: Sendable, Equatable, DecodedFrame {
    /// Frame width in luma samples.
    public let width: Int
    /// Frame height in luma samples.
    public let height: Int
    /// `width × height` luma (Y) samples, row-major.
    public let yPlane: [UInt8]
    /// `⌈width/2⌉ × ⌈height/2⌉` blue-difference chroma (U/Cb) samples.
    public let uPlane: [UInt8]
    /// `⌈width/2⌉ × ⌈height/2⌉` red-difference chroma (V/Cr) samples.
    public let vPlane: [UInt8]
    /// What the decoder learned about how these samples encode colour.
    ///
    /// `range` is the half a renderer MUST honour: a sharer using full-range
    /// samples (every default macOS share) rendered with limited-range maths
    /// loses its shadows and highlights. It defaults to
    /// `.unspecifiedLimited` so a frame built by a caller that predates this
    /// field — the colour-bars fixture, the sharer's preview path, a test —
    /// keeps exactly the behaviour it had.
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

/// A concrete video decoder the host supplies. `ViewerSession` *submits* one
/// reassembled AVCC access unit at a time via `decode`, and receives decoded
/// frames back through the `onDecodedFrame` callback — **synchronously** within
/// `decode` for a synchronous backend (FFmpeg on Linux, or a test stub), or
/// **later** for an asynchronous one (VideoToolbox on macOS, whose
/// decompression session delivers frames on its own thread). A decode failure
/// is signalled via `onDecodeFailure`; the session answers it with a PLI
/// (keyframe request) so the stream can recover.
///
/// **Threading contract.** Both callbacks MUST be invoked on the same
/// serialization context the host drives the session on (the queue it calls
/// `receiveRTP` / `tick` from). A synchronous backend satisfies this for free
/// — it fires the callback inside `decode`, which the host already called on
/// that queue. An asynchronous backend must hop back to that context before
/// invoking a callback, because `ViewerSession` is not `Sendable` and owns no
/// queue of its own.
public protocol VideoDecoding: AnyObject {
    /// Invoked once per decoded frame. The session sets this at wiring time and
    /// routes the (opaque) frame straight to the `VideoSink`. A decoder is free
    /// to emit CPU I420 (`DecodedVideoFrame`) or a platform-native handle its
    /// paired sink understands — the session never inspects it.
    var onDecodedFrame: ((any DecodedFrame) -> Void)? { get set }

    /// Invoked when decoding fails (a submit error, or an asynchronous decode
    /// error). The session responds with a PLI so the sharer sends a fresh
    /// keyframe. A backend that runs its own recovery ladder calls this only
    /// when it actually wants the sharer to intervene.
    var onDecodeFailure: (() -> Void)? { get set }

    /// Submit one AVCC-formatted access unit for decoding. `codec` is the
    /// stream's codec (`.h264` / `.hevc`), deterministically known from the RTP
    /// payload type — the session forwards it so the decoder never has to sniff
    /// the bitstream. `isKeyframe` is true when the AU carries an IDR (its
    /// in-band parameter sets, if any, are inside `accessUnit` — the decoder
    /// extracts them). Frames and failures are delivered via the callbacks
    /// above, not returned.
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
