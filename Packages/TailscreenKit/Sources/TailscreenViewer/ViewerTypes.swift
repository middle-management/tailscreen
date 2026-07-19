import Foundation

// The host-agnostic seam of the portable viewer data-plane. `ViewerSession`
// (see ViewerSession.swift) turns inbound RTP into decoded frames + audio +
// outbound feedback bytes without owning a socket, a thread, or a timer, and
// without linking any concrete codec/renderer/audio backend. These value and
// protocol types are that seam: a later PR plugs the real FFmpeg decoder / SDL
// renderer / ALSA sink in behind them, while THIS target stays Foundation-only
// and Linux-buildable (no FFmpeg/SDL/ALSA dependency — see the package README).

/// One decoded video frame in packed 8-bit YUV 4:2:0 (I420) planar form.
///
/// The plane layout deliberately matches what the FFmpeg decoder in
/// `Packages/FFmpegKit` emits, so a later adapter can hand its output straight
/// to a `VideoSink` — but this struct pulls in nothing FFmpeg-specific, keeping
/// the viewer core dependency-free. `yPlane` is `width × height` luma samples;
/// `uPlane` / `vPlane` are each `⌈width/2⌉ × ⌈height/2⌉` chroma samples
/// (tightly packed, no row padding — the host/adapter owns any stride reshuffle).
public struct DecodedVideoFrame: Sendable, Equatable {
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

    public init(
        width: Int,
        height: Int,
        yPlane: [UInt8],
        uPlane: [UInt8],
        vPlane: [UInt8]
    ) {
        self.width = width
        self.height = height
        self.yPlane = yPlane
        self.uPlane = uPlane
        self.vPlane = vPlane
    }
}

/// A concrete video decoder the host supplies. `ViewerSession` hands it one
/// reassembled AVCC access unit at a time; the implementation (VideoToolbox on
/// macOS, FFmpeg on Linux, or a test stub) turns it into zero or more decoded
/// frames. Throwing signals a decode failure the session answers with a PLI
/// (keyframe request), so the stream can recover.
public protocol VideoDecoding: AnyObject {
    /// Decode one AVCC-formatted access unit. `isKeyframe` is true when the AU
    /// carries an IDR (its in-band parameter sets, if any, are inside `accessUnit`
    /// — the decoder extracts them). Returns the frames the AU produced (usually
    /// one; may be empty while a decoder primes).
    func decode(accessUnit: Data, isKeyframe: Bool) throws -> [DecodedVideoFrame]
}

/// Where decoded frames go — the host's renderer (Metal on macOS, SDL/GL on
/// Linux, or a test collector).
public protocol VideoSink: AnyObject {
    func present(_ frame: DecodedVideoFrame)
}

/// Where decoded audio PCM goes — the host's audio output. PCM is 48 kHz mono
/// Float32 in `[-1, 1]`, 960 samples per 20 ms Opus frame (the same contract
/// `OpusVoiceDecoder` produces).
public protocol AudioSink: AnyObject {
    func play(_ pcm: [Float])
}
