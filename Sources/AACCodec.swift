import AudioToolbox
import Foundation

enum AACCodecError: Error {
    case converterCreate(OSStatus)
    case encode(OSStatus)
    case decode(OSStatus)
    case unexpectedFrameCount(Int)
    case missingMagicCookie
    case setMagicCookie(OSStatus)

    /// Sentinel `OSStatus` used by the encoder/decoder input callbacks
    /// to tell `AudioConverterFillComplexBuffer` "no more data right
    /// now" without triggering end-of-stream semantics. Any non-zero
    /// status would do; we use four-char-code 'NOIN' so it's
    /// recognizable in logs.
    static let kNoMoreInputThisCall = OSStatus(bitPattern: 0x4E4F494E) // 'NOIN'
}

/// Encodes 48 kHz mono Float32 PCM into AAC-LC access units, one AU per
/// 1024 input samples. The caller is responsible for accumulating frames
/// up to the AU boundary; pass exactly 1024 samples per call.
final class AACEncoder {
    static let frameCount: UInt32 = 1024
    static let sampleRate: Double = 48_000

    private var converter: AudioConverterRef?

    init() throws {
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: Self.frameCount,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var conv: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &conv)
        guard status == noErr, let conv = conv else {
            throw AACCodecError.converterCreate(status)
        }
        self.converter = conv

        // 64 kbps voice. Originally tried 32k — too aggressive,
        // tone reproduction had audible quantization noise even on
        // a clean sine. 64k is plenty for one-channel speech and
        // still under 8 KB/s on the wire.
        var bitrate: UInt32 = 64_000
        let bitrateStatus = AudioConverterSetProperty(
            conv,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )
        if bitrateStatus != noErr {
            print("AACEncoder: setting bitrate to \(bitrate) failed (OSStatus=\(bitrateStatus))")
        }
    }

    /// The encoder's magic cookie (AudioSpecificConfig wrapped in
    /// whatever blob AudioToolbox prefers — ESDS on macOS). The
    /// decoder must be primed with the same cookie before
    /// `AudioConverterFillComplexBuffer`, otherwise it decodes raw
    /// AAC AUs against a default config and produces well-formed
    /// noise instead of audio.
    func magicCookie() -> Data? {
        guard let converter = converter else { return nil }
        var size: UInt32 = 0
        let sizeStatus = AudioConverterGetPropertyInfo(
            converter,
            kAudioConverterCompressionMagicCookie,
            &size,
            nil
        )
        guard sizeStatus == noErr, size > 0 else { return nil }
        var data = Data(count: Int(size))
        let getStatus = data.withUnsafeMutableBytes { rawPtr -> OSStatus in
            guard let baseAddr = rawPtr.baseAddress else { return -1 }
            var sz = size
            return AudioConverterGetProperty(
                converter,
                kAudioConverterCompressionMagicCookie,
                &sz,
                baseAddr
            )
        }
        guard getStatus == noErr else { return nil }
        return data
    }

    deinit {
        if let conv = converter { AudioConverterDispose(conv) }
    }

    /// Encode exactly `frameCount` PCM samples. Returns the AAC AU on
    /// success, or nil if the encoder buffered the input without emitting
    /// (rare; usually exactly one AU per call).
    func encode(pcm: [Float]) throws -> Data? {
        guard pcm.count == Int(Self.frameCount) else {
            throw AACCodecError.unexpectedFrameCount(pcm.count)
        }
        guard let converter = converter else { return nil }

        let context = EncodeContext(buffer: pcm)
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()

        let outBufferSize: UInt32 = 4096
        let outPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(outBufferSize), alignment: 1)
        defer { outPointer.deallocate() }

        var outBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: outBufferSize,
                mData: outPointer
            )
        )
        var packetDesc = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: 0
        )
        var ioPackets: UInt32 = 1

        let status = withExtendedLifetime(context) {
            AudioConverterFillComplexBuffer(
                converter,
                { _, ioNumberDataPackets, ioData, _, inUserData in
                    guard let inUserData = inUserData else { return -1 }
                    let ctx = Unmanaged<AACEncoder.EncodeContext>.fromOpaque(inUserData).takeUnretainedValue()
                    if ctx.consumed {
                        // Signal "no more input THIS round" — NOT
                        // end-of-stream. Returning 0 packets + noErr
                        // would tell AudioConverter the stream is over,
                        // it would flush a final packet, and then
                        // permanently refuse further input. A non-zero
                        // status code keeps the encoder primed for the
                        // next FillComplexBuffer call.
                        ioNumberDataPackets.pointee = 0
                        return AACCodecError.kNoMoreInputThisCall
                    }
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(ctx.storage)
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.count * MemoryLayout<Float>.size)
                    ioData.pointee.mBuffers.mNumberChannels = 1
                    ioNumberDataPackets.pointee = AACEncoder.frameCount
                    ctx.consumed = true
                    return noErr
                },
                contextPtr,
                &ioPackets,
                &outBufferList,
                &packetDesc
            )
        }

        // The callback returns `kNoMoreInputThisCall` to indicate "no
        // more input right now". AudioConverterFillComplexBuffer
        // propagates that status when it can't produce a packet —
        // treat it as a benign nil-return rather than a hard error.
        if status != noErr && status != AACCodecError.kNoMoreInputThisCall {
            throw AACCodecError.encode(status)
        }
        guard ioPackets > 0 else { return nil }

        let outSize = Int(outBufferList.mBuffers.mDataByteSize)
        return Data(bytes: outPointer, count: outSize)
    }

    /// Hold the input buffer alive across the AudioConverter callback and
    /// signal one-shot consumption.
    private final class EncodeContext {
        let storage: UnsafeMutablePointer<Float>
        let count: Int
        var consumed: Bool = false

        init(buffer: [Float]) {
            self.count = buffer.count
            self.storage = UnsafeMutablePointer<Float>.allocate(capacity: buffer.count)
            buffer.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    self.storage.initialize(from: base, count: buffer.count)
                }
            }
        }

        deinit {
            storage.deinitialize(count: count)
            storage.deallocate()
        }
    }
}

/// Decodes AAC-LC AUs back into 48 kHz mono Float32 PCM, one block of
/// 1024 samples per AU.
final class AACDecoder {
    static let frameCount: UInt32 = 1024
    static let sampleRate: Double = 48_000

    private var converter: AudioConverterRef?

    init() throws {
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: Self.frameCount,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var conv: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &conv)
        guard status == noErr, let conv = conv else {
            throw AACCodecError.converterCreate(status)
        }
        self.converter = conv

        // Prime the decoder with the encoder's magic cookie. Both
        // ends configure AAC-LC mono 48kHz, so a freshly-built local
        // encoder produces the exact same cookie the remote sender
        // used. Without this, AudioConverter decodes raw AAC AUs
        // against an inferred-from-ASBD config and emits noise — so
        // fail init outright rather than silently producing garbage.
        guard let cookie = AACDecoder.sharedCookie else {
            AudioConverterDispose(conv)
            self.converter = nil
            throw AACCodecError.missingMagicCookie
        }
        let setStatus = cookie.withUnsafeBytes { rawPtr -> OSStatus in
            guard let baseAddr = rawPtr.baseAddress else { return -1 }
            return AudioConverterSetProperty(
                conv,
                kAudioConverterDecompressionMagicCookie,
                UInt32(cookie.count),
                baseAddr
            )
        }
        if setStatus != noErr {
            AudioConverterDispose(conv)
            self.converter = nil
            throw AACCodecError.setMagicCookie(setStatus)
        }
    }

    /// AAC-LC mono 48 kHz cookie, derived once from a throwaway
    /// encoder. Cached so we don't rebuild an encoder per decoder.
    private static let sharedCookie: Data? = {
        guard let enc = try? AACEncoder() else { return nil }
        return enc.magicCookie()
    }()

    deinit {
        if let conv = converter { AudioConverterDispose(conv) }
    }

    /// Decode one AAC AU into PCM samples. Returns up to `frameCount`
    /// samples; the encoder's primer may cause the first call to return
    /// fewer samples or zero.
    func decode(au: Data) throws -> [Float] {
        guard let converter = converter else { return [] }

        let context = DecodeContext(au: au)
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()

        var output = [Float](repeating: 0, count: Int(Self.frameCount))
        return try output.withUnsafeMutableBufferPointer { ptr in
            var outBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(ptr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(ptr.baseAddress)
                )
            )
            var ioPackets: UInt32 = Self.frameCount

            let status = withExtendedLifetime(context) {
                AudioConverterFillComplexBuffer(
                    converter,
                    { _, ioNumberDataPackets, ioData, ioPacketDesc, inUserData in
                        guard let inUserData = inUserData else { return -1 }
                        let ctx = Unmanaged<AACDecoder.DecodeContext>.fromOpaque(inUserData).takeUnretainedValue()
                        if ctx.consumed {
                            // See encoder callback for rationale —
                            // returning noErr+0 packets latches EOS.
                            ioNumberDataPackets.pointee = 0
                            return AACCodecError.kNoMoreInputThisCall
                        }
                        ioData.pointee.mBuffers.mData = ctx.storage
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.count)
                        ioData.pointee.mBuffers.mNumberChannels = 1
                        ioNumberDataPackets.pointee = 1
                        ctx.packetDesc = AudioStreamPacketDescription(
                            mStartOffset: 0,
                            mVariableFramesInPacket: 0,
                            mDataByteSize: UInt32(ctx.count)
                        )
                        if let ioPacketDesc = ioPacketDesc {
                            ioPacketDesc.pointee = withUnsafeMutablePointer(to: &ctx.packetDesc) { $0 }
                        }
                        ctx.consumed = true
                        return noErr
                    },
                    contextPtr,
                    &ioPackets,
                    &outBufferList,
                    nil
                )
            }
            if status != noErr && status != AACCodecError.kNoMoreInputThisCall {
                throw AACCodecError.decode(status)
            }
            return Array(ptr.prefix(Int(ioPackets)))
        }
    }

    private final class DecodeContext {
        let storage: UnsafeMutableRawPointer
        let count: Int
        var consumed: Bool = false
        var packetDesc = AudioStreamPacketDescription()

        init(au: Data) {
            self.count = au.count
            self.storage = UnsafeMutableRawPointer.allocate(byteCount: max(1, au.count), alignment: 1)
            au.withUnsafeBytes { src in
                if let base = src.baseAddress, !au.isEmpty {
                    self.storage.copyMemory(from: base, byteCount: au.count)
                }
            }
        }

        deinit {
            storage.deallocate()
        }
    }
}
