import AudioToolbox
import CoreMedia
import Foundation

/// `CMSampleBuffer` from ScreenCaptureKit -> mono `[Float]` -> 960-sample
/// framing -> `OpusVoiceEncoder` (`.audio` music mode) -> encoded-AU callback.
/// Imports no ScreenCaptureKit; `ScreenCapture` owns the SCStream and hands us
/// the delivered buffer, keeping all SCK coupling in one place.
///
/// Not thread-safe: `handle(_:)` mutates the framer, so the caller must
/// confine calls to the SCStream audio-output serial queue.
final class SystemAudioTap: @unchecked Sendable {
    private let encoder: OpusVoiceEncoder
    /// The portable 960-sample (20ms Opus) framer both voice paths use.
    private var framer = PCMFramer(frameSamples: OpusVoiceEncoder.frameSamples)
    private let onEncodedAU: (Data) -> Void

    init(onEncodedAU: @escaping (Data) -> Void) throws {
        // Music/computer output, not speech — .audio mode, not .voip.
        self.encoder = try OpusVoiceEncoder(application: .audio)
        self.onEncodedAU = onEncodedAU
    }

    /// Runs on the SCStream audio-output queue; stays off the MainActor so a
    /// busy main thread can never stall audio.
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

    /// SCK is configured with `channelCount = 1`, so the buffer list carries a
    /// single mono Float32 buffer; copied into a Swift array before the
    /// retained block buffer goes out of scope.
    static func extractMonoFloat(_ sb: CMSampleBuffer) -> [Float] {
        guard CMSampleBufferGetNumSamples(sb) > 0 else { return [] }
        var blockBuffer: CMBlockBuffer?
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
