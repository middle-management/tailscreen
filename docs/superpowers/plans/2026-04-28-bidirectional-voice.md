# Bidirectional Voice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bidirectional voice between a sharer and any number of connected viewers, riding on the existing port-7447 UDP socket. Sharer acts as an SFU: forwards each viewer's audio RTP to all others without transcoding, plus mixes locally.

**Architecture:** AAC-LC over RTP/UDP, payload type 98, on existing port-7447 socket. New control byte `HELLO_ACK (0x04)` carries the audio SSRC the sharer assigns to each viewer. `VoiceChannel` owns capture (AVAudioEngine + VoiceProcessingIO for built-in AEC), encode, decode-per-SSRC, mixing, and playback; server/client just plumb RTP bytes in and out. Both ends muted by default; toolbar (viewer) and menu (sharer) toggles request mic permission lazily on first unmute.

**Tech Stack:** Swift 6, AVFoundation (AVAudioEngine, kAudioUnitSubType_VoiceProcessingIO), AudioToolbox (AudioConverterRef for AAC-LC), existing TailscaleKit `PacketListener`, existing RTP framing in `RTPPacket.swift`.

**Reference spec:** `docs/superpowers/specs/2026-04-28-bidirectional-voice-design.md`.

---

## File Structure

New:

| File | Responsibility |
|------|----------------|
| `Sources/AACCodec.swift` | `AACEncoder` (PCM Float32 mono 48 kHz → AAC AU bytes) and `AACDecoder` (AU → PCM). Thin AudioToolbox wrappers. |
| `Sources/RTPAudio.swift` | `AudioRTPPacketizer` (one AU per RTP packet, sequence + 48 kHz timestamp counters per outbound SSRC) and `AudioRTPDepacketizer` (unpack RTP audio packet → SSRC + AU bytes + timestamp). |
| `Sources/VoiceChannel.swift` | Owns mic capture, mute state, AAC encoders/decoders, mixer, playback. Emits outbound RTP via injected closure; ingests inbound RTP via `receive(_:)`. Process-side logic isolated from hardware so it's testable. |
| `Tests/TailscreenTests/AACCodecTests.swift` | Encode → decode roundtrip on a 440 Hz sine; assert RMS within tolerance. |
| `Tests/TailscreenTests/RTPAudioTests.swift` | Pack/unpack roundtrip; sequence wraparound; timestamp increment-by-1024-per-AU. |
| `Tests/TailscreenTests/VoiceChannelTests.swift` | Inject synthetic PCM frames; assert outbound closure receives valid RTP audio packets that round-trip back through the decoder. |

Modified:

| File | Change |
|------|--------|
| `Sources/RTPPacket.swift` | Add `RTPHeader.aacPayloadType = 98` and `audioClockHz = 48_000`. Add `ScreenShareControlMessage.helloAck = 0x04`. Add `helloAck` encode/decode helpers carrying a 4-byte SSRC payload. |
| `Sources/TailscaleScreenShareServer.swift` | Add `audioSSRC` field to `Viewer`. Send HELLO_ACK on registerOrRefresh-new. Accept inbound RTP V=2 with PT=98: relay to other viewers, hand local copy to a `VoiceChannel` via callback. Add `sendAudioRTP(_:)` for outbound (from sharer's mic). |
| `Sources/TailscaleScreenShareClient.swift` | Parse HELLO_ACK in receive loop; expose `assignedAudioSSRC`. Detect inbound RTP audio (PT=98) and dispatch via callback. Add `sendAudioRTP(_:)` for outbound (viewer's mic). |
| `Sources/AppState.swift` | `@Published var isMicOn`, `toggleMic()`. Construct/teardown `VoiceChannel` on share start/stop and connect/disconnect. Wire send/receive closures between `VoiceChannel` and the server/client. |
| `Sources/ViewerCommands.swift` | Add `toggleMicrophone(_:)` action that calls into `AppState`. |
| `Sources/ViewerToolbar.swift` | New `mic` toolbar item with `mic` / `mic.slash` SF Symbol, routed through `ViewerCommands`. |
| `Sources/AppMenu.swift` | New "Microphone" toggle menu item under the File menu (sharer side), wired through `AppState.toggleMic`. |
| `.github/workflows/release.yml` | Inject `NSMicrophoneUsageDescription` into the bundled `Info.plist`. |

---

## Task 1: Wire format constants + HELLO_ACK

**Files:**
- Modify: `Sources/RTPPacket.swift`
- Test: `Tests/TailscreenTests/RTPPacketTests.swift`

- [ ] **Step 1: Write failing test for HELLO_ACK encode/decode**

Add to `Tests/TailscreenTests/RTPPacketTests.swift`:

```swift
import XCTest
@testable import Tailscreen

final class HelloAckTests: XCTestCase {
    func testEncodeProducesFiveBytes() {
        let data = ScreenShareControlMessage.encodeHelloAck(ssrc: 0xDEADBEEF)
        XCTAssertEqual(data.count, 5)
        XCTAssertEqual(data[0], 0x04)
        XCTAssertEqual(data[1], 0xDE)
        XCTAssertEqual(data[2], 0xAD)
        XCTAssertEqual(data[3], 0xBE)
        XCTAssertEqual(data[4], 0xEF)
    }

    func testDecodeRoundtrip() {
        let data = ScreenShareControlMessage.encodeHelloAck(ssrc: 12345)
        XCTAssertEqual(ScreenShareControlMessage.decodeHelloAck(data), 12345)
    }

    func testDecodeRejectsWrongLength() {
        XCTAssertNil(ScreenShareControlMessage.decodeHelloAck(Data([0x04, 0x00, 0x00])))
    }

    func testDecodeRejectsWrongTag() {
        XCTAssertNil(ScreenShareControlMessage.decodeHelloAck(Data([0x00, 0x00, 0x00, 0x00, 0x00])))
    }

    func testLooksLikeControlStillTrueForHelloAck() {
        let data = ScreenShareControlMessage.encodeHelloAck(ssrc: 1)
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(data))
    }

    func testRTPHeaderAACPayloadType() {
        XCTAssertEqual(RTPHeader.aacPayloadType, 98)
        XCTAssertEqual(RTPHeader.audioClockHz, 48_000)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

```
make test 2>&1 | grep -E "(FAIL|error)" | head
```
Expected: `error: 'helloAck' is unavailable` or `Type 'ScreenShareControlMessage' has no member 'encodeHelloAck'`.

- [ ] **Step 3: Add the constants and helpers**

In `Sources/RTPPacket.swift`, edit the doc comment at the top of `ScreenShareControlMessage` to add the new control byte:

```
///     0x04 (HELLO_ACK) server → viewer: 4-byte SSRC payload — assigns the
///                       viewer's audio SSRC. Sent in response to HELLO.
```

Add the case to the enum:

```swift
case helloAck = 0x04
```

Add static helpers below the existing `encode` / `decode` methods:

```swift
    /// Encode a HELLO_ACK with a 4-byte big-endian SSRC payload.
    static func encodeHelloAck(ssrc: UInt32) -> Data {
        var data = Data(capacity: 5)
        data.append(helloAck.rawValue)
        data.append(UInt8((ssrc >> 24) & 0xFF))
        data.append(UInt8((ssrc >> 16) & 0xFF))
        data.append(UInt8((ssrc >> 8) & 0xFF))
        data.append(UInt8(ssrc & 0xFF))
        return data
    }

    /// Parse a HELLO_ACK datagram. Returns the SSRC, or nil if malformed.
    static func decodeHelloAck(_ data: Data) -> UInt32? {
        guard data.count == 5, data[data.startIndex] == helloAck.rawValue else { return nil }
        var ssrc: UInt32 = 0
        for i in 1...4 {
            ssrc = (ssrc << 8) | UInt32(data[data.startIndex + i])
        }
        return ssrc
    }
```

In `RTPHeader`, alongside `h264PayloadType` and `hevcPayloadType`, add:

```swift
    /// Dynamic payload type for AAC-LC voice. RFC 3640 reserves no fixed
    /// number for AAC; 98 follows H.264 (96) + HEVC (97).
    static let aacPayloadType: UInt8 = 98
    /// Audio sample-rate-derived RTP clock for AAC at 48 kHz mono.
    static let audioClockHz: UInt32 = 48_000
```

- [ ] **Step 4: Run the test and confirm it passes**

```
make test 2>&1 | tail -20
```
Expected: all tests in `HelloAckTests` pass.

- [ ] **Step 5: Commit**

```
git add Sources/RTPPacket.swift Tests/TailscreenTests/RTPPacketTests.swift
git commit -m "Voice wire: add HELLO_ACK control byte + AAC RTP constants"
```

---

## Task 2: AAC codec wrapper

**Files:**
- Create: `Sources/AACCodec.swift`
- Test: `Tests/TailscreenTests/AACCodecTests.swift`

- [ ] **Step 1: Write the failing roundtrip test**

Create `Tests/TailscreenTests/AACCodecTests.swift`:

```swift
import XCTest
import AVFoundation
@testable import Tailscreen

final class AACCodecTests: XCTestCase {
    func testEncodeDecodeRoundtripWaveformShape() throws {
        let encoder = try AACEncoder()
        let decoder = try AACDecoder()

        // 100 ms of 440 Hz sine at 48 kHz mono Float32 = ~5 frames of 1024.
        let sampleRate: Double = 48_000
        let frequency: Double = 440
        let frameCount = 1024
        let totalFrames = frameCount * 5
        var samples = [Float](repeating: 0, count: totalFrames)
        for i in 0..<totalFrames {
            samples[i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
        }

        // Feed in 1024-sample blocks; collect AAC AU bytes.
        var encoded: [Data] = []
        for blockIdx in 0..<5 {
            let block = Array(samples[blockIdx * frameCount ..< (blockIdx + 1) * frameCount])
            if let au = try encoder.encode(pcm: block) {
                encoded.append(au)
            }
        }
        XCTAssertGreaterThanOrEqual(encoded.count, 3, "encoder should emit something for 5 frames")

        // Decode all AUs back to PCM and check RMS energy is non-trivial.
        var decoded: [Float] = []
        for au in encoded {
            let pcm = try decoder.decode(au: au)
            decoded.append(contentsOf: pcm)
        }
        XCTAssertGreaterThan(decoded.count, 0, "decoder should produce samples")

        let rms = sqrt(decoded.reduce(0) { $0 + $1 * $1 } / Float(decoded.count))
        XCTAssertGreaterThan(rms, 0.1, "decoded sine should have meaningful RMS, got \(rms)")
        XCTAssertLessThan(rms, 1.5, "decoded sine should not be wildly clipped, got \(rms)")
    }
}
```

- [ ] **Step 2: Run and confirm it fails**

```
make test 2>&1 | grep -E "(FAIL|error)" | head
```
Expected: `cannot find 'AACEncoder' in scope`.

- [ ] **Step 3: Create the AAC codec wrappers**

Create `Sources/AACCodec.swift`:

```swift
import AudioToolbox
import AVFoundation
import Foundation

enum AACCodecError: Error {
    case converterCreate(OSStatus)
    case encode(OSStatus)
    case decode(OSStatus)
    case unexpectedFrameCount(Int)
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

        // Target ~32 kbps for voice — fine quality, low bandwidth.
        var bitrate: UInt32 = 32_000
        AudioConverterSetProperty(
            conv,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )
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

        var input = pcm
        let context = EncodeContext(buffer: input)
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()

        var outBufferSize: UInt32 = 4096
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

        let status = AudioConverterFillComplexBuffer(
            converter,
            { _, ioNumberDataPackets, ioData, _, inUserData in
                guard let inUserData = inUserData else { return -1 }
                let ctx = Unmanaged<EncodeContext>.fromOpaque(inUserData).takeUnretainedValue()
                if ctx.consumed {
                    ioNumberDataPackets.pointee = 0
                    return noErr
                }
                ctx.buffer.withUnsafeMutableBufferPointer { ptr in
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(ptr.baseAddress)
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(ptr.count * MemoryLayout<Float>.size)
                    ioData.pointee.mBuffers.mNumberChannels = 1
                }
                ioNumberDataPackets.pointee = AACEncoder.frameCount
                ctx.consumed = true
                return noErr
            },
            &ioPackets,
            &outBufferList,
            &packetDesc
        )

        // Consume the input variable's lifetime (silence "never read" warning).
        _ = input

        guard status == noErr else { throw AACCodecError.encode(status) }
        guard ioPackets > 0 else { return nil }

        let outSize = Int(outBufferList.mBuffers.mDataByteSize)
        return Data(bytes: outPointer, count: outSize)
    }

    /// Hold the input buffer alive across the AudioConverter callback and
    /// signal one-shot consumption.
    private final class EncodeContext {
        var buffer: [Float]
        var consumed: Bool = false
        init(buffer: [Float]) { self.buffer = buffer }
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
    }

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

            let status = AudioConverterFillComplexBuffer(
                converter,
                { _, ioNumberDataPackets, ioData, ioPacketDesc, inUserData in
                    guard let inUserData = inUserData else { return -1 }
                    let ctx = Unmanaged<DecodeContext>.fromOpaque(inUserData).takeUnretainedValue()
                    if ctx.consumed {
                        ioNumberDataPackets.pointee = 0
                        return noErr
                    }
                    ctx.au.withUnsafeBytes { raw in
                        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: raw.baseAddress)
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.au.count)
                        ioData.pointee.mBuffers.mNumberChannels = 1
                    }
                    ioNumberDataPackets.pointee = 1
                    ctx.packetDesc = AudioStreamPacketDescription(
                        mStartOffset: 0,
                        mVariableFramesInPacket: 0,
                        mDataByteSize: UInt32(ctx.au.count)
                    )
                    if let ioPacketDesc = ioPacketDesc {
                        ioPacketDesc.pointee = withUnsafeMutablePointer(to: &ctx.packetDesc) { $0 }
                    }
                    ctx.consumed = true
                    return noErr
                },
                &ioPackets,
                &outBufferList,
                nil
            )
            guard status == noErr else { throw AACCodecError.decode(status) }
            return Array(output.prefix(Int(ioPackets)))
        }
    }

    private final class DecodeContext {
        let au: Data
        var consumed: Bool = false
        var packetDesc = AudioStreamPacketDescription()
        init(au: Data) { self.au = au }
    }
}
```

- [ ] **Step 4: Run and confirm pass**

```
make test 2>&1 | grep -E "AACCodecTests" | head
```
Expected: `Test Case '-[TailscreenTests.AACCodecTests testEncodeDecodeRoundtripWaveformShape]' passed`.

- [ ] **Step 5: Commit**

```
git add Sources/AACCodec.swift Tests/TailscreenTests/AACCodecTests.swift
git commit -m "Voice: AudioToolbox AAC-LC encoder/decoder wrappers"
```

---

## Task 3: RTP audio packetizer/depacketizer

**Files:**
- Create: `Sources/RTPAudio.swift`
- Test: `Tests/TailscreenTests/RTPAudioTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/TailscreenTests/RTPAudioTests.swift`:

```swift
import XCTest
@testable import Tailscreen

final class RTPAudioTests: XCTestCase {
    func testRoundtripSingleAU() throws {
        let pack = AudioRTPPacketizer(ssrc: 0xCAFEBABE)
        let depack = AudioRTPDepacketizer()
        let au = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])

        let packet = pack.packetize(au: au)
        let parsed = depack.unpack(packet)

        XCTAssertEqual(parsed?.ssrc, 0xCAFEBABE)
        XCTAssertEqual(parsed?.au, au)
        XCTAssertEqual(parsed?.payloadType, 98)
    }

    func testTimestampIncrementsBy1024PerAU() {
        let pack = AudioRTPPacketizer(ssrc: 1)
        let au = Data([0x00])

        let p1 = pack.packetize(au: au)
        let p2 = pack.packetize(au: au)

        let ts1 = RTPHeader.decode(from: p1)?.header.timestamp
        let ts2 = RTPHeader.decode(from: p2)?.header.timestamp
        XCTAssertNotNil(ts1)
        XCTAssertNotNil(ts2)
        XCTAssertEqual(ts2! &- ts1!, 1024)
    }

    func testSequenceWraparound() {
        let pack = AudioRTPPacketizer(ssrc: 1, startSequence: 0xFFFF)
        let au = Data([0x00])

        let p1 = pack.packetize(au: au)
        let p2 = pack.packetize(au: au)

        XCTAssertEqual(RTPHeader.decode(from: p1)?.header.sequenceNumber, 0xFFFF)
        XCTAssertEqual(RTPHeader.decode(from: p2)?.header.sequenceNumber, 0x0000)
    }

    func testDepackRejectsNonAudioPayloadType() {
        // Build an RTP packet with PT=96 (H.264), feed to audio depack.
        var data = Data()
        let header = RTPHeader(
            marker: false,
            payloadType: RTPHeader.h264PayloadType,
            sequenceNumber: 0,
            timestamp: 0,
            ssrc: 1
        )
        header.encode(into: &data)
        data.append(contentsOf: [0xAA, 0xBB])

        let depack = AudioRTPDepacketizer()
        XCTAssertNil(depack.unpack(data))
    }
}
```

- [ ] **Step 2: Run and confirm fail**

```
make test 2>&1 | grep -E "(error|FAIL)" | head
```
Expected: `cannot find 'AudioRTPPacketizer' in scope`.

- [ ] **Step 3: Create the packetizer/depacketizer**

Create `Sources/RTPAudio.swift`:

```swift
import Foundation

/// Packs AAC-LC access units into RTP packets, one AU per packet, with a
/// 48 kHz audio clock and a stable per-channel SSRC. The RTP timestamp
/// advances by 1024 (the AU's frame count) per packet — this matches the
/// AAC frame rate at 48 kHz.
final class AudioRTPPacketizer {
    let ssrc: UInt32
    private var sequence: UInt16
    private var timestamp: UInt32

    init(ssrc: UInt32, startSequence: UInt16 = 0, startTimestamp: UInt32 = 0) {
        self.ssrc = ssrc
        self.sequence = startSequence
        self.timestamp = startTimestamp
    }

    func packetize(au: Data) -> Data {
        var packet = Data(capacity: RTPHeader.size + au.count)
        let header = RTPHeader(
            marker: true,
            payloadType: RTPHeader.aacPayloadType,
            sequenceNumber: sequence,
            timestamp: timestamp,
            ssrc: ssrc
        )
        header.encode(into: &packet)
        packet.append(au)
        sequence &+= 1
        timestamp &+= 1024
        return packet
    }
}

/// Stateless RTP audio unpacker. Stateless because mixing across multiple
/// SSRCs happens in the caller — VoiceChannel keeps a decoder per SSRC.
struct AudioRTPDepacketizer {
    struct Parsed {
        let ssrc: UInt32
        let timestamp: UInt32
        let sequenceNumber: UInt16
        let payloadType: UInt8
        let au: Data
    }

    func unpack(_ packet: Data) -> Parsed? {
        guard let (header, payloadOffset) = RTPHeader.decode(from: packet) else { return nil }
        guard header.payloadType == RTPHeader.aacPayloadType else { return nil }
        let payload = packet[packet.index(packet.startIndex, offsetBy: payloadOffset)..<packet.endIndex]
        guard !payload.isEmpty else { return nil }
        return Parsed(
            ssrc: header.ssrc,
            timestamp: header.timestamp,
            sequenceNumber: header.sequenceNumber,
            payloadType: header.payloadType,
            au: Data(payload)
        )
    }
}
```

- [ ] **Step 4: Run and confirm pass**

```
make test 2>&1 | grep RTPAudioTests | head
```
Expected: all four tests passing.

- [ ] **Step 5: Commit**

```
git add Sources/RTPAudio.swift Tests/TailscreenTests/RTPAudioTests.swift
git commit -m "Voice: RTP audio pack/unpack (PT=98, 48 kHz clock)"
```

---

## Task 4: VoiceChannel — process-side logic

**Files:**
- Create: `Sources/VoiceChannel.swift`
- Test: `Tests/TailscreenTests/VoiceChannelTests.swift`

This task implements only the **testable** piece — the process-side pipeline that takes inbound PCM, encodes, packetizes, sends; and inbound RTP, decodes per SSRC, returns mixed PCM. Hardware glue (AVAudioEngine + VPIO) lives in Task 7's `MicCapture` helper which can only be tested manually.

- [ ] **Step 1: Write failing test for outbound encode + packetize**

Create `Tests/TailscreenTests/VoiceChannelTests.swift`:

```swift
import XCTest
@testable import Tailscreen

final class VoiceChannelTests: XCTestCase {
    func testProcessOutboundFrameEmitsRTPPacket() throws {
        var sent: [Data] = []
        let channel = try VoiceChannel(
            localSSRC: 0xAA,
            onSend: { sent.append($0) }
        )

        // 1024 samples at 48 kHz = one AU.
        let pcm = (0..<1024).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
        channel.processOutboundFrame(pcm)

        XCTAssertEqual(sent.count, 1, "one frame should produce one RTP packet")

        // Packet PT must be 98 and SSRC must match.
        let parsed = AudioRTPDepacketizer().unpack(sent[0])
        XCTAssertEqual(parsed?.payloadType, 98)
        XCTAssertEqual(parsed?.ssrc, 0xAA)
        XCTAssertGreaterThan(parsed?.au.count ?? 0, 0)
    }

    func testInboundDecodesPerSSRC() throws {
        var sent: [Data] = []
        let speaker = try VoiceChannel(
            localSSRC: 0xBB,
            onSend: { sent.append($0) }
        )
        let pcm = (0..<1024).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
        // Need a few frames because AAC encoder primer drops first AU.
        for _ in 0..<5 { speaker.processOutboundFrame(pcm) }
        XCTAssertGreaterThanOrEqual(sent.count, 3)

        let listener = try VoiceChannel(
            localSSRC: 0xCC,
            onSend: { _ in }
        )
        var receivedAnyPCM = false
        listener.onMixedPCM = { samples in
            if !samples.isEmpty { receivedAnyPCM = true }
        }
        for packet in sent {
            listener.receive(packet)
        }
        XCTAssertTrue(receivedAnyPCM, "listener should decode and surface PCM")
    }

    func testMutedDoesNotSend() throws {
        var sent: [Data] = []
        let channel = try VoiceChannel(
            localSSRC: 1,
            onSend: { sent.append($0) }
        )
        channel.isMuted = true

        let pcm = [Float](repeating: 0, count: 1024)
        channel.processOutboundFrame(pcm)

        XCTAssertEqual(sent.count, 0)
    }
}
```

- [ ] **Step 2: Run and confirm fail**

```
make test 2>&1 | grep "(error|FAIL)" | head
```
Expected: `cannot find 'VoiceChannel' in scope`.

- [ ] **Step 3: Create VoiceChannel**

Create `Sources/VoiceChannel.swift`:

```swift
import Foundation

/// Process-side voice pipeline: PCM in → AAC enc → RTP out, and RTP in →
/// AAC dec (per SSRC) → mixed PCM out. Hardware capture/playback glue is
/// in `MicCapture` (added in Task 7) which feeds this class.
///
/// Thread-safe via an internal serial queue: capture callbacks (audio
/// thread) and network callbacks (TailscaleKit reader task) call into
/// public methods which dispatch onto the queue. State only mutates on
/// the queue.
final class VoiceChannel: @unchecked Sendable {
    let localSSRC: UInt32
    var isMuted: Bool {
        get { queue.sync { _isMuted } }
        set { queue.sync { _isMuted = newValue } }
    }

    /// Invoked on the internal queue every time the encoder produces an
    /// RTP packet. Caller should pass it to the network layer.
    private let onSend: (Data) -> Void

    /// Invoked on the internal queue every time the decoder produces a
    /// block of mixed PCM samples ready to render. The MicCapture glue
    /// schedules these into the playback engine.
    var onMixedPCM: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "VoiceChannel")
    private var _isMuted: Bool = true
    private let encoder: AACEncoder
    private let packetizer: AudioRTPPacketizer
    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: AACDecoder] = [:]

    init(localSSRC: UInt32, onSend: @escaping (Data) -> Void) throws {
        self.localSSRC = localSSRC
        self.onSend = onSend
        self.encoder = try AACEncoder()
        self.packetizer = AudioRTPPacketizer(ssrc: localSSRC)
    }

    /// Push exactly 1024 PCM samples (one AAC AU's worth) for outbound
    /// transmission. No-op when muted.
    func processOutboundFrame(_ pcm: [Float]) {
        queue.async {
            guard !self._isMuted else { return }
            do {
                guard let au = try self.encoder.encode(pcm: pcm) else { return }
                let packet = self.packetizer.packetize(au: au)
                self.onSend(packet)
            } catch {
                print("VoiceChannel: encode failed: \(error)")
            }
        }
    }

    /// Ingest one inbound RTP audio packet. Decodes per SSRC and emits
    /// PCM via `onMixedPCM`.
    func receive(_ packet: Data) {
        queue.async {
            guard let parsed = self.depacketizer.unpack(packet) else { return }
            // Drop our own loopback if the network somehow returned it.
            guard parsed.ssrc != self.localSSRC else { return }
            do {
                let decoder = try self.ensureDecoder(for: parsed.ssrc)
                let samples = try decoder.decode(au: parsed.au)
                if !samples.isEmpty {
                    self.onMixedPCM?(samples)
                }
            } catch {
                print("VoiceChannel: decode failed for ssrc=\(parsed.ssrc): \(error)")
            }
        }
    }

    /// Forget all per-SSRC decoders. Called when the share session ends
    /// so a future session starts fresh.
    func reset() {
        queue.async {
            self.decoders.removeAll()
        }
    }

    private func ensureDecoder(for ssrc: UInt32) throws -> AACDecoder {
        if let existing = decoders[ssrc] { return existing }
        let new = try AACDecoder()
        decoders[ssrc] = new
        return new
    }
}
```

- [ ] **Step 4: Run and confirm pass**

```
make test 2>&1 | grep VoiceChannelTests | head
```
Expected: all three tests passing.

- [ ] **Step 5: Commit**

```
git add Sources/VoiceChannel.swift Tests/TailscreenTests/VoiceChannelTests.swift
git commit -m "Voice: VoiceChannel — encode/decode/mux per-SSRC pipeline"
```

---

## Task 5: Server — HELLO_ACK + audio relay

**Files:**
- Modify: `Sources/TailscaleScreenShareServer.swift`

- [ ] **Step 1: Add `audioSSRC` to `Viewer` struct**

In `Sources/TailscaleScreenShareServer.swift`, locate the `Viewer` struct (currently around line 52) and add a new field:

```swift
    private struct Viewer {
        let addr: String
        let ssrc: UInt32
        /// SSRC the sharer assigns to this viewer for *audio* (sent in
        /// HELLO_ACK). Distinct from `ssrc` above, which the server uses
        /// when sending video *to* this viewer.
        let audioSSRC: UInt32
        var nextSequence: UInt16
        var lastSeenNs: UInt64
        var pliTimestampsNs: [UInt64] = []
    }
```

- [ ] **Step 2: Populate `audioSSRC` in `registerOrRefresh`**

Locate `registerOrRefresh` (around line 363) and add the field to the new-viewer branch:

```swift
            let v = Viewer(
                addr: addr,
                ssrc: UInt32.random(in: 1...UInt32.max),
                audioSSRC: UInt32.random(in: 1...UInt32.max),
                nextSequence: UInt16.random(in: 0...UInt16.max),
                lastSeenNs: now
            )
```

- [ ] **Step 3: Send HELLO_ACK on registration**

In `handleIncoming`'s `.hello` case, capture the viewer's audio SSRC after `registerOrRefresh` and send a HELLO_ACK back. Replace the `case .hello:` line and surrounding switch arm with:

```swift
        case .hello:
            registerOrRefresh(addr: addr, isNew: true)
            if let assignedSSRC = (viewers.withLock { $0[addr]?.audioSSRC }) {
                Task { [weak self] in
                    guard let pl = self?.packetListener else { return }
                    let ack = ScreenShareControlMessage.encodeHelloAck(ssrc: assignedSSRC)
                    try? await pl.send(ack, to: addr)
                }
            }
```

- [ ] **Step 4: Accept inbound RTP audio (PT=98) and relay**

Modify `handleIncoming` to handle inbound RTP audio. The current first guard drops RTP from viewers entirely; widen it to allow PT=98 RTP through. Replace the existing body with:

```swift
    private func handleIncoming(data: Data, from addr: String) {
        guard !data.isEmpty else { return }
        if !ScreenShareControlMessage.looksLikeControl(data) {
            // RTP from a viewer is only allowed for audio (PT=98). Anything
            // else (video PTs) is dropped.
            if let (header, _) = RTPHeader.decode(from: data),
               header.payloadType == RTPHeader.aacPayloadType {
                handleInboundAudioRTP(data, from: addr)
            }
            return
        }
        guard let kind = ScreenShareControlMessage.decode(data) else { return }
        switch kind {
        case .hello:
            registerOrRefresh(addr: addr, isNew: true)
            if let assignedSSRC = (viewers.withLock { $0[addr]?.audioSSRC }) {
                Task { [weak self] in
                    guard let pl = self?.packetListener else { return }
                    let ack = ScreenShareControlMessage.encodeHelloAck(ssrc: assignedSSRC)
                    try? await pl.send(ack, to: addr)
                }
            }
        case .keepalive:
            registerOrRefresh(addr: addr, isNew: false)
        case .bye:
            removeViewer(addr: addr)
        case .pli:
            registerOrRefresh(addr: addr, isNew: false)
            recordPLI(from: addr)
            encoder?.requestKeyframe()
        case .helloAck:
            // Server never receives HELLO_ACK from a viewer; ignore.
            return
        }
    }

    /// Relay one inbound audio RTP packet to all other viewers and pass
    /// a copy to the local VoiceChannel via `onAudioReceived`. The packet
    /// is forwarded byte-for-byte (no transcode) so the receiving viewer
    /// sees the original sender's SSRC.
    private func handleInboundAudioRTP(_ packet: Data, from sender: String) {
        // Verify the sender is registered; drop spoofed packets.
        let recipients = viewers.withLock { state -> [String] in
            guard state[sender] != nil else { return [] }
            return state.keys.filter { $0 != sender }
        }
        if let pl = packetListener {
            Task { [weak self] in
                guard self != nil else { return }
                for addr in recipients {
                    try? await pl.send(packet, to: addr)
                }
            }
        }
        onAudioReceived?(packet)
    }
```

- [ ] **Step 5: Add `onAudioReceived` callback and `sendAudioRTP`**

Near the other callbacks (around `var onAnnotationReceived` at line ~96) add:

```swift
    /// Fires on every inbound audio RTP packet from any viewer. AppState
    /// pipes these into the local VoiceChannel so the sharer can hear
    /// viewers.
    var onAudioReceived: ((Data) -> Void)?
```

After the existing `broadcast` method, add an outbound audio fan-out method:

```swift
    /// Send one outbound audio RTP packet (sharer's mic) to all viewers.
    /// VoiceChannel calls this from its onSend closure.
    func sendAudioRTP(_ packet: Data) {
        guard let pl = packetListener else { return }
        let recipients = viewers.withLock { Array($0.keys) }
        Task { [weak self] in
            guard self != nil else { return }
            for addr in recipients {
                try? await pl.send(packet, to: addr)
            }
        }
    }
```

- [ ] **Step 6: Build, run existing tests**

```
make build 2>&1 | tail -20
make test 2>&1 | grep -E "(Test Case|FAIL|passed)" | tail -20
```
Expected: clean build, all existing tests still pass.

- [ ] **Step 7: Commit**

```
git add Sources/TailscaleScreenShareServer.swift
git commit -m "Voice server: HELLO_ACK assignment + inbound RTP audio relay"
```

---

## Task 6: Client — HELLO_ACK + audio plumbing

**Files:**
- Modify: `Sources/TailscaleScreenShareClient.swift`

- [ ] **Step 1: Add audio state**

Near the existing fields (around line 48), add:

```swift
    /// Audio SSRC the sharer assigned via HELLO_ACK. nil until the ack
    /// arrives; the VoiceChannel waits on this before sending mic audio.
    private(set) var assignedAudioSSRC: UInt32?

    /// Fires when the sharer assigns us an audio SSRC. AppState uses this
    /// to lazily build the local VoiceChannel.
    var onAudioSSRCAssigned: ((UInt32) -> Void)?

    /// Fires on every inbound audio RTP packet (PT=98). AppState pipes
    /// this into VoiceChannel.receive(_:).
    var onAudioReceived: ((Data) -> Void)?
```

- [ ] **Step 2: Parse HELLO_ACK and route audio in `receiveLoop`**

In the existing `receiveLoop` at the line that currently reads:

```swift
                guard !ScreenShareControlMessage.looksLikeControl(datagram) else { continue }
```

Replace it with the multi-branch handler:

```swift
                if ScreenShareControlMessage.looksLikeControl(datagram) {
                    if let ssrc = ScreenShareControlMessage.decodeHelloAck(datagram) {
                        if assignedAudioSSRC != ssrc {
                            assignedAudioSSRC = ssrc
                            onAudioSSRCAssigned?(ssrc)
                        }
                    }
                    // Other control bytes from the server are ignored.
                    continue
                }

                if let (header, _) = RTPHeader.decode(from: datagram),
                   header.payloadType == RTPHeader.aacPayloadType {
                    onAudioReceived?(datagram)
                    continue
                }
```

- [ ] **Step 3: Add `sendAudioRTP`**

After `sendAnnotationOp` (around line 79), add:

```swift
    /// Send one outbound audio RTP packet up to the sharer. VoiceChannel
    /// calls this from its onSend closure.
    func sendAudioRTP(_ packet: Data) async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        try? await pl.send(packet, to: addr)
    }
```

- [ ] **Step 4: Build**

```
make build 2>&1 | tail -10
```
Expected: clean build.

- [ ] **Step 5: Commit**

```
git add Sources/TailscaleScreenShareClient.swift
git commit -m "Voice client: parse HELLO_ACK + audio RTP send/receive hooks"
```

---

## Task 7: AppState lifecycle + MicCapture (hardware glue)

**Files:**
- Modify: `Sources/AppState.swift`
- Append to: `Sources/VoiceChannel.swift` (add `MicCapture` class — lives in same file because it's a thin AVAudioEngine wrapper around VoiceChannel)

This task wires VoiceChannel to the existing share session, plus adds the hardware engine glue. Hardware paths can't be unit-tested — verify manually per the test guide in Task 11.

- [ ] **Step 1: Append MicCapture to VoiceChannel.swift**

At the bottom of `Sources/VoiceChannel.swift`, add:

```swift
import AVFoundation

/// AVAudioEngine glue: input from VoiceProcessingIO mic (with built-in
/// AEC), output through the same VPIO unit (so AEC has the right
/// reference signal). Feeds inbound PCM frames into the VoiceChannel
/// and renders outbound PCM blocks the channel decoded from RTP.
@MainActor
final class MicCapture {
    private let channel: VoiceChannel
    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    private let mixer: AVAudioMixerNode
    private let outputFormat: AVAudioFormat
    private var inputAccumulator: [Float] = []
    private var isRunning = false

    init(channel: VoiceChannel) {
        self.channel = channel
        self.mixer = engine.mainMixerNode
        // 48 kHz mono Float32 — matches the codec format.
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!

        // Force the input + output node onto the VoiceProcessingIO unit
        // so AEC works without us building it ourselves.
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        try? engine.outputNode.setVoiceProcessingEnabled(true)

        // Pipe decoded PCM (per-SSRC mix already done by VoiceChannel)
        // into a player node so the user hears it.
        channel.onMixedPCM = { [weak self] samples in
            Task { @MainActor [weak self] in self?.scheduleSamples(samples) }
        }
    }

    /// Start the engine (and request permission if not already granted).
    /// Throws if permission is denied or the engine fails to start.
    func start() async throws {
        guard !isRunning else { return }
        let granted = await Self.requestMicPermission()
        guard granted else {
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
            )
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: outputFormat)
        playerNodes.append(player)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer, format: inputFormat)
        }

        try engine.start()
        player.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        for node in playerNodes { node.stop() }
        engine.stop()
        playerNodes.removeAll()
        inputAccumulator.removeAll()
        isRunning = false
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        // Hardware may give us 16 kHz / 44.1 kHz / 48 kHz Float32 mono.
        // For v1 we trust VPIO to deliver 48 kHz — mismatched rates are
        // logged and dropped.
        guard format.sampleRate == 48_000,
              format.channelCount == 1,
              let channelData = buffer.floatChannelData?[0] else {
            return
        }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        inputAccumulator.append(contentsOf: samples)
        while inputAccumulator.count >= 1024 {
            let frame = Array(inputAccumulator.prefix(1024))
            inputAccumulator.removeFirst(1024)
            channel.processOutboundFrame(frame)
        }
    }

    private func scheduleSamples(_ samples: [Float]) {
        guard isRunning, let player = playerNodes.first else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return }
        for (i, sample) in samples.enumerated() {
            dst[i] = sample
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
```

- [ ] **Step 2: Add VoiceChannel + MicCapture lifecycle to AppState**

In `Sources/AppState.swift`, near the other published properties (around line 21), add:

```swift
    @Published var isMicOn = false

    private var voiceChannel: VoiceChannel?
    private var micCapture: MicCapture?
```

- [ ] **Step 3: Build VoiceChannel on share start (sharer)**

In `startSharing` (line ~146), after `srv.onAnnotationReceived = …` block (ends ~line 193) and before the `do { … srv.start … }` block, add:

```swift
                // Sharer's audio SSRC is fixed at 0. Build the channel up
                // front so HELLO_ACK assignment for viewers can route
                // through, and inbound viewer audio can be decoded.
                let voice = try VoiceChannel(localSSRC: 0) { [weak srv] packet in
                    srv?.sendAudioRTP(packet)
                }
                self.voiceChannel = voice
                srv.onAudioReceived = { [weak voice] packet in
                    voice?.receive(packet)
                }
```

- [ ] **Step 4: Tear down VoiceChannel on stopSharing**

In `stopSharing` (line ~246), after `await server?.stop()` line, add:

```swift
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
```

- [ ] **Step 5: Build VoiceChannel on viewer connect**

In `connect(to host:)` (line ~314), after `try await c.connect(to: host, port: 7447, existingNode: sharedNode)` and before `isConnected = true`, add:

```swift
            c.onAudioSSRCAssigned = { [weak self, weak c] ssrc in
                Task { @MainActor [weak self, weak c] in
                    guard let self = self, let c = c else { return }
                    do {
                        let voice = try VoiceChannel(localSSRC: ssrc) { [weak c] packet in
                            Task { await c?.sendAudioRTP(packet) }
                        }
                        self.voiceChannel = voice
                        c.onAudioReceived = { [weak voice] packet in
                            voice?.receive(packet)
                        }
                    } catch {
                        self.showAlertMessage(
                            title: "Voice Init Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
```

- [ ] **Step 6: Tear down on disconnect**

In `disconnect` (line ~454), after `await client?.disconnect()`, add:

```swift
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
```

- [ ] **Step 7: Add `toggleMic()`**

After `toggleSharerOverlay` (around line ~307), add:

```swift
    /// Toggle the local microphone. Lazily requests permission and starts
    /// the AVAudioEngine on first unmute. Voice plumbing is built when a
    /// share session begins; toggleMic just enables/disables capture.
    func toggleMic() async {
        guard let voice = voiceChannel else {
            showAlertMessage(
                title: "Voice Not Ready",
                message: "Voice is only available during an active share."
            )
            return
        }
        if isMicOn {
            micCapture?.stop()
            voice.isMuted = true
            isMicOn = false
            return
        }
        do {
            if micCapture == nil {
                micCapture = MicCapture(channel: voice)
            }
            try await micCapture?.start()
            voice.isMuted = false
            isMicOn = true
        } catch {
            micCapture = nil
            showAlertMessage(
                title: "Microphone Unavailable",
                message: "Tailscreen could not start the microphone: \(error.localizedDescription). Check System Settings → Privacy & Security → Microphone."
            )
            isMicOn = false
        }
    }
```

- [ ] **Step 8: Build**

```
make build 2>&1 | tail -20
```
Expected: clean build. (No new automated tests — `MicCapture` is hardware-bound; verify manually in Task 11.)

- [ ] **Step 9: Commit**

```
git add Sources/VoiceChannel.swift Sources/AppState.swift
git commit -m "Voice: AppState lifecycle + AVAudioEngine VPIO mic capture"
```

---

## Task 8: Toolbar mic button + sharer menu toggle

**Files:**
- Modify: `Sources/ViewerCommands.swift`
- Modify: `Sources/ViewerToolbar.swift`
- Modify: `Sources/AppMenu.swift`

- [ ] **Step 1: Add `toggleMicrophone` action to ViewerCommands**

Read `Sources/ViewerCommands.swift` first to find the existing action pattern, then add a new selector that calls `AppState.toggleMic()` on the shared instance. The exact form depends on how `ViewerCommands` reaches `AppState` (likely through a weak ref set by `MenuBarView` / `TailscreenApp`); follow the existing wiring.

If `ViewerCommands.shared` already holds an `appState` weak ref, the addition is:

```swift
    @objc func toggleMicrophone(_ sender: Any?) {
        Task { @MainActor in
            await self.appState?.toggleMic()
        }
    }
```

If no such ref exists yet, post a notification name and observe it in `AppState.init`:

```swift
    @objc func toggleMicrophone(_ sender: Any?) {
        NotificationCenter.default.post(name: .tailscreenToggleMicrophone, object: nil)
    }
```

And in `AppState.init`, wire:

```swift
        NotificationCenter.default.addObserver(
            forName: .tailscreenToggleMicrophone,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.toggleMic() }
        }
```

Plus declare the notification at the bottom of the file:

```swift
extension Notification.Name {
    static let tailscreenToggleMicrophone = Notification.Name("tailscreen.toggleMicrophone")
}
```

- [ ] **Step 2: Add mic toolbar item**

In `Sources/ViewerToolbar.swift`, add a new identifier near the existing ones (line ~13-18):

```swift
    private static let microphone = NSToolbarItem.Identifier("action.microphone")
```

In `toolbarDefaultItemIdentifiers`, append:

```swift
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolGroup, .flexibleSpace, Self.microphone, Self.undo, Self.clearAll]
    }
```

In `toolbarAllowedItemIdentifiers`, include `Self.microphone`:

```swift
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolGroup, Self.microphone, Self.undo, Self.clearAll, .flexibleSpace, .space]
    }
```

In the switch in `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`, add:

```swift
        case Self.microphone:
            return makeButton(
                id: itemIdentifier,
                label: "Mic",
                symbol: "mic.slash",
                action: #selector(ViewerCommands.toggleMicrophone(_:))
            )
```

The icon flips between `mic` (on) and `mic.slash` (off) — driven by an `AppState.isMicOn` observer set up in `MenuBarView` / wherever the toolbar is rebuilt; for a v1 simplification, leave the static `mic.slash` symbol and rely on the menu's checkmark to disambiguate state. Wire the live icon in a follow-up commit.

- [ ] **Step 3: Add sharer-side menu item**

In `Sources/AppMenu.swift`, find where the File menu is built (look for `File` and `Disconnect`), then insert a Microphone toggle. Example (matching whatever pattern is already used — probably an `NSMenuItem` with selector):

```swift
        let micItem = NSMenuItem(
            title: "Microphone",
            action: #selector(ViewerCommands.toggleMicrophone(_:)),
            keyEquivalent: ""
        )
        micItem.target = ViewerCommands.shared
        fileMenu.addItem(micItem)
```

The menu will route through `ViewerCommands.toggleMicrophone(_:)` which posts the notification or calls `AppState.toggleMic()` directly per Step 1. A future commit can hook `validateMenuItem(_:)` to set the checkmark from `appState.isMicOn`.

- [ ] **Step 4: Build and run manually**

```
make build 2>&1 | tail -10
make run &
```

Verify (manually):
- The viewer window's toolbar shows a mic icon when connected to a sharer.
- Clicking it triggers a microphone permission prompt the first time.
- The sharer's File menu shows "Microphone" while sharing.

Kill the running app: `pkill -f Tailscreen`.

- [ ] **Step 5: Commit**

```
git add Sources/ViewerCommands.swift Sources/ViewerToolbar.swift Sources/AppMenu.swift
git commit -m "Voice UI: viewer toolbar mic + sharer menu mic toggle"
```

---

## Task 9: Info.plist — `NSMicrophoneUsageDescription`

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Inject the usage description**

In `.github/workflows/release.yml`, find where the `Info.plist` is built (look for `PlistBuddy` or `defaults write`). Add an entry alongside the existing keys:

```bash
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Tailscreen uses your microphone for two-way voice during screen sharing.'" "$PLIST_PATH"
```

The exact integration depends on the existing plist build steps — read the workflow first and insert in the same block. Match the style of nearby keys (e.g. `LSUIElement`).

- [ ] **Step 2: Verify the workflow file parses**

```
yq eval '.jobs' .github/workflows/release.yml > /dev/null
```
Expected: clean parse, no error.

(If `yq` is not installed, GitHub will validate on push.)

- [ ] **Step 3: Commit**

```
git add .github/workflows/release.yml
git commit -m "Voice: add NSMicrophoneUsageDescription to release plist"
```

---

## Task 10: E2E voice test (optional — gated on auth key)

**Files:**
- Modify: `Tests/TailscreenTests/TailscaleConnectivityTests.swift` (add new test method)

- [ ] **Step 1: Add an end-to-end audio test**

Append a new test method to `TailscaleConnectivityTests`:

```swift
    func testVoiceRoundtripBetweenTwoNodes() async throws {
        // Skip when the e2e harness env vars aren't set, matching the
        // existing pattern in the rest of this file.
        guard ProcessInfo.processInfo.environment["TAILSCREEN_TS_AUTHKEY"] != nil else {
            throw XCTSkip("TAILSCREEN_TS_AUTHKEY not set")
        }

        let server = TailscaleScreenShareServer()
        var receivedAudioPackets = 0
        server.onAudioReceived = { _ in receivedAudioPackets += 1 }
        try await server.start(hostname: "voice-test-server")
        defer { Task { await server.stop() } }

        // Connect a viewer, force HELLO_ACK to be processed.
        let renderer = await MainActor.run { MetalViewerRenderer() }
        let client = TailscaleScreenShareClient(renderer: renderer)
        let ips = try await server.getIPAddresses()
        guard let serverIP = ips.ip4 ?? ips.ip6 else {
            XCTFail("server has no tailnet IP")
            return
        }

        let assigned = expectation(description: "HELLO_ACK assigned")
        client.onAudioSSRCAssigned = { _ in assigned.fulfill() }
        try await client.connect(to: serverIP, port: 7447)
        await fulfillment(of: [assigned], timeout: 10)
        defer { Task { await client.disconnect() } }

        // Send synthetic AAC AUs as RTP from the viewer.
        let voice = try VoiceChannel(localSSRC: client.assignedAudioSSRC ?? 1) { packet in
            Task { await client.sendAudioRTP(packet) }
        }
        voice.isMuted = false
        let pcm = (0..<1024).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
        for _ in 0..<10 { voice.processOutboundFrame(pcm) }

        // Allow time for packets to flow.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertGreaterThan(receivedAudioPackets, 0, "server should receive audio RTP")
    }
```

- [ ] **Step 2: Run the e2e suite**

```
make test-e2e
```
Expected: all existing tests still pass, and the new test reports ≥1 received audio packet.

If running outside CI, the test no-ops via XCTSkip — fine.

- [ ] **Step 3: Commit**

```
git add Tests/TailscreenTests/TailscaleConnectivityTests.swift
git commit -m "Voice tests: e2e audio RTP roundtrip via real tsnet"
```

---

## Task 11: Manual test guide

**Files:**
- Modify: `README.md` (small "Voice testing" subsection)

- [ ] **Step 1: Document manual checks**

Append a short subsection to `README.md` under the existing "Testing" or "Manual testing" section:

```markdown
### Voice (manual)

1. Start two instances locally: `./test-local.sh 2`.
2. Sharer: open menubar → Share my screen.
3. Viewer (other instance): open menubar → connect to the sharer.
4. On the viewer, click the toolbar mic icon. macOS prompts for microphone access; grant it.
5. Speak — the sharer should hear you (use headphones to keep AEC honest).
6. Sharer: open File → Microphone. Speak — the viewer should hear you.
7. Add a third instance (`./test-local.sh 3`); have all three speak in turn. Each should hear the other two without echo.
```

- [ ] **Step 2: Commit**

```
git add README.md
git commit -m "Voice: manual test guide in README"
```

---

## Self-Review Checklist

Run these before declaring the plan complete:

1. **Spec coverage:**
   - HELLO_ACK control byte and 4-byte SSRC payload — Task 1.
   - PT=98 / 48 kHz constants — Task 1.
   - AAC encode/decode — Task 2.
   - RTP audio framing — Task 3.
   - VoiceChannel pipeline — Task 4.
   - SFU relay on sharer + HELLO_ACK send — Task 5.
   - Client HELLO_ACK parsing + audio plumbing — Task 6.
   - VoiceChannel lifecycle in AppState + VPIO AEC — Task 7.
   - Toolbar + menu UI — Task 8.
   - Mic permission key — Task 9.
   - E2E test — Task 10.
   - Manual test guide — Task 11.
   - Spec items "voice only during share" → enforced by lifecycle in Task 7 (channel exists only between share-start and stop).
   - Spec items "muted by default" → `_isMuted = true` in Task 4.
   - Spec items "mute via toolbar/menu" → Task 8.
   - Spec items "VPIO AEC" → Task 7's MicCapture forces VPIO on input + output node.

2. **Type consistency:**
   - `VoiceChannel.localSSRC: UInt32` — used consistently in Tasks 4, 7, 10.
   - `AudioRTPPacketizer(ssrc:)` — Task 3 + 4 + 10.
   - `RTPHeader.aacPayloadType: UInt8 = 98` — Tasks 1, 3, 5, 6.
   - `ScreenShareControlMessage.helloAck` — Tasks 1, 5, 6.
   - `assignedAudioSSRC: UInt32?` on client — Tasks 6, 7, 10.
   - `onAudioReceived: ((Data) -> Void)?` on both server and client — Tasks 5, 6, 7, 10.
   - `sendAudioRTP(_:)` on server (sync `func`) and client (`async func`) — different by design (client serializes through PacketListener actor; server fires-and-forgets). Document in code comments where they diverge.

3. **Placeholder scan:** no TBDs, no "implement later", no skipped code blocks. The only "follow the existing pattern" hand-waves are in Task 8 step 1 and step 3 — these are unavoidable because the wiring depends on the existing AppMenu / ViewerCommands shape, which the implementer needs to read first.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-28-bidirectional-voice.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
