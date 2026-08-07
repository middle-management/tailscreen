import AudioToolbox
import CoreMedia
import Foundation

/// Helper-side system-audio pipeline: an audio `CMSampleBuffer` from
/// ScreenCaptureKit → mono `[Float]` → 960-sample framing → `OpusVoiceEncoder`
/// (in `.audio` music mode) → encoded-AU callback. Deliberately imports no
/// ScreenCaptureKit; the SCStream lives in `ScreenCapture` and only hands us
/// the already-delivered sample buffer, keeping all SCK coupling in one place.
///
/// Not thread-safe: `handle(_:)` mutates the framer, so the caller must confine
/// every call to the SCStream audio-output serial queue (as `ScreenCapture`
/// does). `@unchecked Sendable` records that contract so the value can be
/// captured into the audio-output closure.
final class SystemAudioTap: @unchecked Sendable {
    private let encoder: OpusVoiceEncoder
    /// The portable 960-sample (20 ms Opus) framer from TailscreenAudio —
    /// the same accumulate-and-drain both voice paths use, pinned by the
    /// package's `MicrophoneCaptureTests`.
    private var framer = PCMFramer(frameSamples: OpusVoiceEncoder.frameSamples)
    private let onEncodedAU: (Data) -> Void

    init(onEncodedAU: @escaping (Data) -> Void) throws {
        // System audio is music/computer output, not speech — encode it in
        // Opus's `.audio` application mode rather than `.voip`.
        self.encoder = try OpusVoiceEncoder(application: .audio)
        self.onEncodedAU = onEncodedAU
    }

    /// Extract mono Float PCM from one audio sample buffer, frame it into
    /// 960-sample frames, Opus-encode each, and emit via `onEncodedAU`. Runs on
    /// the SCStream audio-output queue; stays off the MainActor so a busy main
    /// thread can never stall audio.
    func handle(_ sampleBuffer: CMSampleBuffer) {
        let samples = Self.extractMonoFloat(sampleBuffer)
        guard !samples.isEmpty else { return }
        for frame in framer.push(samples) {
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
    static func extractMonoFloat(_ sb: CMSampleBuffer) -> [Float] {
        guard CMSampleBufferGetNumSamples(sb) > 0 else { return [] }
        var blockBuffer: CMBlockBuffer?
        // channelCount == 1 ⇒ a single mono buffer; access `mBuffers` directly
        // rather than the buffer-list pointer overlay.
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
        guard status == noErr, blockBuffer != nil else { return [] }
        guard let data = abl.mBuffers.mData else { return [] }
        let frameCount = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard frameCount > 0 else { return [] }
        let ptr = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: frameCount))
    }
}
