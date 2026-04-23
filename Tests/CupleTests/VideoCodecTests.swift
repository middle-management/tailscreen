import XCTest
import CoreVideo
import CoreMedia
@testable import Cuple

/// End-to-end: encode a synthetic frame with VideoEncoder, feed the captured
/// SPS/PPS plus the AVCC output into VideoDecoder, and check we get a
/// pixel buffer back at the original resolution. Catches regressions in the
/// parameter-set handoff and AVCC/Annex-B framing — the exact bug class the
/// pipeline rewrite was fixing.
final class VideoCodecTests: XCTestCase {
    func testEncodeKeyframeDecodesBack() throws {
        let width = 640
        let height = 480
        let pixelBuffer = try Self.makePixelBuffer(width: width, height: height)

        let encoder = VideoEncoder()
        try encoder.setup(width: width, height: height, fps: 30, bitsPerPixel: 0.2)

        let collector = Collector()
        let encodedKeyframe = expectation(description: "encoder emits keyframe with parameter sets")

        encoder.onParameterSets = { sps, pps in
            collector.setParams(sps: sps, pps: pps)
        }
        encoder.onEncodedData = { data, isKeyframe in
            if collector.recordFirstKeyframe(data: data, isKeyframe: isKeyframe) {
                encodedKeyframe.fulfill()
            }
        }

        // First frame is forced IDR by setup(); encode a few so VT's callback fires promptly.
        for _ in 0..<3 {
            encoder.encode(pixelBuffer: pixelBuffer)
        }
        wait(for: [encodedKeyframe], timeout: 10.0)

        let snapshot = collector.snapshot()
        let sps = try XCTUnwrap(snapshot.sps, "encoder never emitted SPS")
        let pps = try XCTUnwrap(snapshot.pps, "encoder never emitted PPS")
        let frame = try XCTUnwrap(snapshot.frame, "encoder never emitted a keyframe")
        XCTAssertFalse(sps.isEmpty)
        XCTAssertFalse(pps.isEmpty)
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(snapshot.isKey)

        let decoder = VideoDecoder()
        let decoded = expectation(description: "decoder emits a frame")
        decoder.onDecodedFrame = { pb in
            XCTAssertEqual(CVPixelBufferGetWidth(pb), width)
            XCTAssertEqual(CVPixelBufferGetHeight(pb), height)
            decoded.fulfill()
        }

        decoder.setParameterSets(sps: sps, pps: pps)
        decoder.decode(data: frame, isKeyframe: true)
        wait(for: [decoded], timeout: 10.0)

        encoder.shutdown()
        decoder.shutdown()
    }

    func testCachedParameterSetsAvailableAfterKeyframe() throws {
        let width = 320
        let height = 240
        let pixelBuffer = try Self.makePixelBuffer(width: width, height: height)

        let encoder = VideoEncoder()
        try encoder.setup(width: width, height: height, fps: 30, bitsPerPixel: 0.2)

        let gotCallback = expectation(description: "encoder callback fired at least once")
        gotCallback.assertForOverFulfill = false
        encoder.onEncodedData = { _, _ in gotCallback.fulfill() }

        for _ in 0..<3 {
            encoder.encode(pixelBuffer: pixelBuffer)
        }
        wait(for: [gotCallback], timeout: 10.0)

        let cached = encoder.cachedParameterSets
        XCTAssertNotNil(cached, "cachedParameterSets should be populated after a keyframe")
        XCTAssertFalse(cached?.sps.isEmpty ?? true)
        XCTAssertFalse(cached?.pps.isEmpty ?? true)

        encoder.shutdown()
    }

    // MARK: - Helpers

    /// Thread-safe capture of the encoder's async output.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var sps: Data?
        private var pps: Data?
        private var frame: Data?
        private var isKey = false

        func setParams(sps: Data, pps: Data) {
            lock.lock(); defer { lock.unlock() }
            self.sps = sps
            self.pps = pps
        }

        /// Returns true exactly once, on the first keyframe we see (and only if
        /// the parameter sets are already cached).
        func recordFirstKeyframe(data: Data, isKeyframe: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard frame == nil, isKeyframe, sps != nil, pps != nil else { return false }
            frame = data
            isKey = isKeyframe
            return true
        }

        func snapshot() -> (sps: Data?, pps: Data?, frame: Data?, isKey: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (sps, pps, frame, isKey)
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
