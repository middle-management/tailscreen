import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenSharer
import XCTest

@testable import TailscreenSharerLinux

/// Drives `X11CaptureEncoder` through the **real `CaptureEncoding` seam** —
/// the same protocol the portable `TailscaleScreenShareServer` talks to — and
/// decodes what comes out. This is the Linux sharer's counterpart to the
/// viewer's `PipelineIntegrationTests`: proof that capture → encode → the wire
/// format actually closes, rather than that the pieces compile.
///
/// Needs an X display, so it self-skips without one and runs under Xvfb in CI.
final class CaptureEncoderTests: XCTestCase {

    private func skipWithoutDisplay() throws {
        guard ProcessInfo.processInfo.environment["DISPLAY"] != nil else {
            throw XCTSkip("no DISPLAY — run under Xvfb for the capture tests")
        }
        guard FFmpeg.firstAvailableEncoder(for: .h264, preferring: ["libx264"]) != nil else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }
    }

    private func displaySelection() throws -> Data {
        try JSONEncoder().encode(PickerSelection(kind: .display, displayID: 0, windowID: nil, bundleIDs: []))
    }

    /// Collector for the seam's callbacks, since they fire on the capture
    /// thread and the assertions run on the test's.
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var aus: [(Data, Bool)] = []
        var params: CodecParameterSets?
        var resolution: (Int, Int)?
        var activityTicks = 0
        var exitReason: String?

        func attach(to backend: X11CaptureEncoder) {
            backend.onAccessUnit = { [self] data, key in
                lock.withLock { aus.append((data, key)) }
            }
            backend.onParameterSets = { [self] p in lock.withLock { params = p } }
            backend.onEncoderResolution = { [self] w, h in lock.withLock { resolution = (w, h) } }
            backend.onActivity = { [self] in lock.withLock { activityTicks += 1 } }
            backend.onUnexpectedExit = { [self] r in lock.withLock { exitReason = r } }
        }
    }

    private func runCapture(
        fps: Int = 30, seconds: Double = 1.0,
        configure: (X11CaptureEncoder) -> Void = { _ in }
    ) throws -> (Sink, X11CaptureEncoder) {
        let backend = X11CaptureEncoder()
        let sink = Sink()
        sink.attach(to: backend)
        configure(backend)
        try backend.start(
            selectionData: try displaySelection(), forceH264: true,
            qualityEnv: [QualitySettings.fpsCapEnvKey: String(fps)])
        Thread.sleep(forTimeInterval: seconds)
        return (sink, backend)
    }

    func testCaptureProducesDecodableAccessUnits() throws {
        try skipWithoutDisplay()
        let (sink, backend) = try runCapture()
        let waiter = expectation(description: "stopped")
        Task {
            await backend.stop()
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 5)

        let (aus, params, resolution, ticks) = sink.lock.withLock {
            (sink.aus, sink.params, sink.resolution, sink.activityTicks)
        }
        XCTAssertFalse(aus.isEmpty, "no access units produced")
        XCTAssertTrue(aus[0].1, "first access unit must be a keyframe")
        XCTAssertGreaterThan(ticks, 0, "onActivity never fired — the watchdog would kill this share")

        // The resolution the server anchors its bitrate on must be even (4:2:0)
        // and must match what the decoder actually reports.
        let res = try XCTUnwrap(resolution)
        XCTAssertEqual(res.0 % 2, 0)
        XCTAssertEqual(res.1 % 2, 0)

        // Parameter sets are what the server caches the codec from, and the
        // ordering contract says they arrive before the resolution.
        switch try XCTUnwrap(params) {
        case .h264(let sps, let pps):
            XCTAssertFalse(sps.isEmpty)
            XCTAssertFalse(pps.isEmpty)
        case .hevc:
            XCTFail("forceH264 was set but HEVC parameter sets were emitted")
        }

        // The payload is what goes on the wire: decode it exactly as a viewer
        // would, with no conversion in between.
        let decoder = try FFmpeg.VideoDecoder(codec: .h264)
        var frames: [FFmpeg.Frame] = []
        for (data, _) in aus { frames += try decoder.decode(avcc: data) }
        frames += try decoder.flush()
        XCTAssertFalse(frames.isEmpty, "captured stream did not decode")
        XCTAssertEqual(frames[0].width, res.0)
        XCTAssertEqual(frames[0].height, res.1)
    }

    /// A viewer PLI becomes `requestKeyframe()`. If that doesn't produce an
    /// IDR promptly, a viewer that loses sync waits for the GOP backstop —
    /// which is exactly the multi-second freeze the PLI path exists to avoid.
    func testRequestKeyframeProducesAnIDR() throws {
        try skipWithoutDisplay()
        let (sink, backend) = try runCapture(seconds: 0.5)
        let before = sink.lock.withLock { sink.aus.count }
        XCTAssertGreaterThan(before, 0)

        backend.requestKeyframe()
        Thread.sleep(forTimeInterval: 0.5)
        let waiter = expectation(description: "stopped")
        Task {
            await backend.stop()
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 5)

        let after = sink.lock.withLock { Array(sink.aus.dropFirst(before)) }
        XCTAssertFalse(after.isEmpty, "no frames after requestKeyframe")
        XCTAssertTrue(
            after.prefix(4).contains { $0.1 },
            "requestKeyframe() did not produce an IDR within four frames")
    }

    /// Every keyframe must carry its parameter sets in-band — that's what lets
    /// a viewer join mid-share. A backend that emitted them only once would
    /// pass the callback assertion above and still leave late joiners black.
    func testEveryKeyframeCarriesParameterSetsInBand() throws {
        try skipWithoutDisplay()
        let (sink, backend) = try runCapture(seconds: 0.5)
        backend.requestKeyframe()
        Thread.sleep(forTimeInterval: 0.4)
        let waiter = expectation(description: "stopped")
        Task {
            await backend.stop()
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 5)

        let keyframes = sink.lock.withLock { sink.aus.filter(\.1) }
        XCTAssertGreaterThanOrEqual(keyframes.count, 2, "expected the initial IDR plus the requested one")
        for (data, _) in keyframes {
            let annexB = try XCTUnwrap(NALUnit.avccToAnnexB(data))
            let types = Set(NALUnit.annexBNALs(annexB).compactMap { $0.first.map { $0 & 0x1F } })
            XCTAssertTrue(types.contains(7), "keyframe without SPS — a late joiner can't decode it")
            XCTAssertTrue(types.contains(8), "keyframe without PPS")
        }
    }

    /// Window and application shares aren't implementable on plain X11 without
    /// the compositor. Falling back to the whole screen would leak everything
    /// the user didn't choose to share, so `start` must refuse.
    func testNonDisplaySelectionsAreRefused() throws {
        try skipWithoutDisplay()
        let backend = X11CaptureEncoder()
        let windowSelection = try JSONEncoder().encode(
            PickerSelection(kind: .window, displayID: nil, windowID: 42, bundleIDs: []))
        XCTAssertThrowsError(
            try backend.start(selectionData: windowSelection, forceH264: true, qualityEnv: [:])
        ) { error in
            guard case X11CaptureEncoder.StartError.unsupportedSelection = error else {
                return XCTFail("expected unsupportedSelection, got \(error)")
            }
        }
    }

    func testMalformedSelectionIsRefused() {
        let backend = X11CaptureEncoder()
        XCTAssertThrowsError(
            try backend.start(selectionData: Data([0xDE, 0xAD]), forceH264: true, qualityEnv: [:])
        ) { error in
            guard case X11CaptureEncoder.StartError.malformedSelection = error else {
                return XCTFail("expected malformedSelection, got \(error)")
            }
        }
    }

    /// `stop()` must actually stop: the mac backend relies on process death,
    /// this one doesn't have that safety net, so a leaked capture thread would
    /// keep grabbing the screen after the share ended.
    func testStopHaltsProduction() throws {
        try skipWithoutDisplay()
        let (sink, backend) = try runCapture(seconds: 0.4)
        let waiter = expectation(description: "stopped")
        Task {
            await backend.stop()
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 5)

        let atStop = sink.lock.withLock { sink.aus.count }
        Thread.sleep(forTimeInterval: 0.5)
        let later = sink.lock.withLock { sink.aus.count }
        XCTAssertEqual(atStop, later, "capture thread still running after stop()")
    }

    /// Guards the whole point of the seam: this type is substitutable for the
    /// macOS capture helper wherever the server expects a backend.
    func testConformsToCaptureEncoding() {
        let backend: any CaptureEncoding = X11CaptureEncoder()
        backend.setAudioEnabled(true)  // no-op here, must not trap
        backend.setFrameInterval(15)
        backend.setBitrate(500_000)
        backend.requestKeyframe()
    }
}
