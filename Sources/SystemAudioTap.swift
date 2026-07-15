import AudioToolbox
import CoreMedia
import Foundation

/// Pure 1024-sample framer for system-audio PCM. Accumulates inbound Float
/// samples and drains complete 1024-sample frames (one AAC AU's worth),
/// carrying the remainder to the next call. Mirrors `TapBuffer.appendAndDrain`
/// semantics but as a value type so CI can exercise the framing without any
/// CoreMedia buffers.
struct SystemAudioFramer {
    /// Samples per AAC-LC access unit at 48 kHz.
    static let frameSize = 1024

    private var accumulator: [Float] = []

    /// Append `samples` and return every complete 1024-sample frame that can
    /// now be drained, in order. The tail shorter than a full frame is kept.
    mutating func append(_ samples: [Float]) -> [[Float]] {
        accumulator.append(contentsOf: samples)
        var frames: [[Float]] = []
        while accumulator.count >= Self.frameSize {
            frames.append(Array(accumulator.prefix(Self.frameSize)))
            accumulator.removeFirst(Self.frameSize)
        }
        return frames
    }

    /// Samples buffered but not yet drained into a full frame.
    var pendingCount: Int { accumulator.count }
}

/// Helper-side system-audio pipeline: an audio `CMSampleBuffer` from
/// ScreenCaptureKit → mono `[Float]` → 1024-sample framing → `AACEncoder` →
/// encoded-AU callback. Deliberately imports no ScreenCaptureKit; the SCStream
/// lives in `ScreenCapture` and only hands us the already-delivered sample
/// buffer, keeping all SCK coupling in one place.
///
/// Not thread-safe: `handle(_:)` mutates the framer, so the caller must confine
/// every call to the SCStream audio-output serial queue (as `ScreenCapture`
/// does). `@unchecked Sendable` records that contract so the value can be
/// captured into the audio-output closure.
final class SystemAudioTap: @unchecked Sendable {
    private let encoder: AACEncoder
    private var framer = SystemAudioFramer()
    private let onEncodedAU: (Data) -> Void

    init(onEncodedAU: @escaping (Data) -> Void) throws {
        self.encoder = try AACEncoder()
        self.onEncodedAU = onEncodedAU
    }

    /// Extract mono Float PCM from one audio sample buffer, frame it into
    /// 1024-sample AUs, AAC-encode each, and emit via `onEncodedAU`. Runs on
    /// the SCStream audio-output queue; stays off the MainActor so a busy main
    /// thread can never stall audio.
    func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = Self.extractMonoFloat(sampleBuffer) else { return }
        for frame in framer.append(samples) {
            do {
                if let au = try encoder.encode(pcm: frame) {
                    onEncodedAU(au)
                }
            } catch {
                print("SystemAudioTap: encode failed: \(error)")
            }
        }
    }

    /// Pull deinterleaved Float32 PCM (channel 0) out of an SCStream audio
    /// sample buffer. SCK is configured with `channelCount = 1`, so the buffer
    /// list carries a single mono Float32 buffer; we copy it into a Swift
    /// array before the retained block buffer goes out of scope.
    static func extractMonoFloat(_ sb: CMSampleBuffer) -> [Float]? {
        guard CMSampleBufferGetNumSamples(sb) > 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        // channelCount == 1 ⇒ a single mono buffer; access `mBuffers` directly
        // (the same pattern `AACCodec` uses) rather than the buffer-list
        // pointer overlay.
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }
        guard let data = abl.mBuffers.mData else { return nil }
        let frameCount = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return nil }
        let ptr = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: frameCount))
    }
}
