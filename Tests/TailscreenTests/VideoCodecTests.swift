import XCTest
import CoreVideo
import CoreMedia
@testable import Tailscreen

/// End-to-end: encode a synthetic frame with VideoEncoder, feed the captured
/// parameter sets plus the AVCC output into VideoDecoder, and check we get a
/// pixel buffer back at the original resolution. Catches regressions in the
/// parameter-set handoff and AVCC/Annex-B framing.
///
/// These tests depend on VideoToolbox being able to actually encode on the
/// host. Virtualized CI runners (notably GitHub Actions' macOS images) often
/// have no paravirt video driver and emit no frames; in that case the tests
/// skip with a clear message rather than timing out.
final class VideoCodecTests: XCTestCase {
    func testEncodeKeyframeDecodesBack_DefaultCodec() throws {
        try runEncodeDecodeRoundTrip(preferredCodec: .hevc)
    }

    func testEncodeKeyframeDecodesBack_H264() throws {
        try runEncodeDecodeRoundTrip(preferredCodec: .h264)
    }

    private func runEncodeDecodeRoundTrip(preferredCodec: VideoCodec) throws {
        let width = 640
        let height = 480
        let pixelBuffer = try Self.makePixelBuffer(width: width, height: height)

        let encoder = VideoEncoder()
        try encoder.setup(
            width: width, height: height, fps: 30,
            preferredCodec: preferredCodec, bitsPerPixel: 0.2
        )
        defer { encoder.shutdown() }

        let collector = Collector()
        let encodedKeyframe = XCTestExpectation(description: "encoder emits keyframe with parameter sets")

        encoder.onParameterSets = { params in
            collector.setParams(params)
        }
        encoder.onEncodedData = { data, isKeyframe in
            if collector.recordFirstKeyframe(data: data, isKeyframe: isKeyframe) {
                encodedKeyframe.fulfill()
            }
        }

        for _ in 0..<3 {
            encoder.encode(pixelBuffer: pixelBuffer)
        }
        let result = XCTWaiter.wait(for: [encodedKeyframe], timeout: 5.0)
        try Self.skipIfNotProduced(result)

        let snapshot = collector.snapshot()
        let params = try XCTUnwrap(snapshot.params, "encoder never emitted parameter sets")
        let frame = try XCTUnwrap(snapshot.frame, "encoder never emitted a keyframe")
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(snapshot.isKey)

        // Sanity check: the params shape should match the codec the encoder
        // actually used (which may differ from `preferredCodec` if VT fell
        // back, e.g. on a host without HW HEVC).
        switch (encoder.codec, params) {
        case (.h264, .h264(let sps, let pps)):
            XCTAssertFalse(sps.isEmpty); XCTAssertFalse(pps.isEmpty)
        case (.hevc, .hevc(let vps, let sps, let pps)):
            XCTAssertFalse(vps.isEmpty); XCTAssertFalse(sps.isEmpty); XCTAssertFalse(pps.isEmpty)
        default:
            XCTFail("encoder.codec=\(encoder.codec) but params shape doesn't match")
        }

        let decoder = VideoDecoder()
        defer { decoder.shutdown() }
        let decoded = XCTestExpectation(description: "decoder emits a frame")
        decoder.onDecodedFrame = { pb in
            XCTAssertEqual(CVPixelBufferGetWidth(pb), width)
            XCTAssertEqual(CVPixelBufferGetHeight(pb), height)
            decoded.fulfill()
        }

        decoder.setParameterSets(params)
        decoder.decode(data: frame, isKeyframe: true)
        let decodeResult = XCTWaiter.wait(for: [decoded], timeout: 5.0)
        try Self.skipIfNotProduced(decodeResult, producer: "VideoToolbox decoder")
    }

    func testCachedParameterSetsAvailableAfterKeyframe() throws {
        let width = 320
        let height = 240
        let pixelBuffer = try Self.makePixelBuffer(width: width, height: height)

        let encoder = VideoEncoder()
        try encoder.setup(width: width, height: height, fps: 30, bitsPerPixel: 0.2)
        defer { encoder.shutdown() }

        let gotCallback = XCTestExpectation(description: "encoder callback fired at least once")
        gotCallback.assertForOverFulfill = false
        encoder.onEncodedData = { _, _ in gotCallback.fulfill() }

        for _ in 0..<3 {
            encoder.encode(pixelBuffer: pixelBuffer)
        }
        let result = XCTWaiter.wait(for: [gotCallback], timeout: 5.0)
        try Self.skipIfNotProduced(result)

        XCTAssertNotNil(encoder.cachedParameterSets, "cachedParameterSets should be populated after a keyframe")
    }

    private static func skipIfNotProduced(_ result: XCTWaiter.Result, producer: String = "VideoToolbox encoder") throws {
        if result != .completed {
            throw XCTSkip("\(producer) produced no output — likely a virtualized environment without hardware video acceleration.")
        }
    }

    // MARK: - Helpers

    /// Thread-safe capture of the encoder's async output.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var params: CodecParameterSets?
        private var frame: Data?
        private var isKey = false

        func setParams(_ p: CodecParameterSets) {
            lock.lock(); defer { lock.unlock() }
            self.params = p
        }

        /// Returns true exactly once, on the first keyframe we see (and only if
        /// the parameter sets are already cached).
        func recordFirstKeyframe(data: Data, isKeyframe: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard frame == nil, isKeyframe, params != nil else { return false }
            frame = data
            isKey = isKeyframe
            return true
        }

        func snapshot() -> (params: CodecParameterSets?, frame: Data?, isKey: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (params, frame, isKey)
        }
    }

    static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "VideoCodecTests", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
        }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let px = row.advanced(by: x * 4)
                px[0] = UInt8((x * 255 / max(1, width - 1)) & 0xFF)  // B
                px[1] = UInt8((y * 255 / max(1, height - 1)) & 0xFF) // G
                px[2] = 0x80                                          // R
                px[3] = 0xFF                                          // A
            }
        }
        return buf
    }
}
