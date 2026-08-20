import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenViewer

/// Unit tests for `FrameStoreVideoSink` — the store-plus-callbacks sink both
/// swift-cross-ui viewers now share.
///
/// The legs here are the ones a per-host copy gets wrong: announcing the first
/// frame more than once, announcing it again for a reused sink without a
/// reset, publishing stats on every frame instead of once a window, and
/// forwarding a frame the CPU blit path cannot read.
final class FrameStoreVideoSinkTests: XCTestCase {
    /// A frame of another shape entirely — the case the `as?` guard exists
    /// for. Nothing shipping emits one; that is why it must be dropped rather
    /// than force-cast.
    private struct ForeignFrame: DecodedFrame {
        let width = 64
        let height = 64
    }

    private func frame(
        width: Int = 64, height: Int = 32,
        colorInfo: VideoColorInfo = .unspecifiedLimited
    ) -> DecodedVideoFrame {
        let chroma = ((width + 1) / 2) * ((height + 1) / 2)
        return DecodedVideoFrame(
            width: width, height: height,
            yPlane: [UInt8](repeating: 16, count: width * height),
            uPlane: [UInt8](repeating: 128, count: chroma),
            vPlane: [UInt8](repeating: 128, count: chroma),
            colorInfo: colorInfo)
    }

    /// Mutable counters shared with the sink's `@Sendable` callbacks. The sink
    /// documents that `present` is driven serially, which is the same reason
    /// its own state needs no lock.
    private final class Counts: @unchecked Sendable {
        var firstFrames = 0
        var frames = 0
        var stats: [(width: Int, height: Int, fps: Int, color: VideoColorInfo)] = []
    }

    private final class Clock: @unchecked Sendable {
        var nowNs: UInt64 = 0
    }

    private func makeSink(
        _ counts: Counts, _ clock: Clock, store: FrameStore = FrameStore()
    ) -> FrameStoreVideoSink {
        FrameStoreVideoSink(
            store: store,
            onFirstFrame: { counts.firstFrames += 1 },
            onFrame: { counts.frames += 1 },
            onStats: { width, height, fps, color in
                counts.stats.append((width, height, fps, color))
            },
            clock: { clock.nowNs })
    }

    func testStoresTheFrameForTheRenderer() {
        let store = FrameStore()
        let sink = makeSink(Counts(), Clock(), store: store)
        sink.present(frame(width: 128, height: 64))
        XCTAssertEqual(store.current()?.width, 128)
    }

    /// Announced once, then never again for the life of the session — a host
    /// that hides its connecting placard on this callback would otherwise
    /// re-run that transition sixty times a second.
    func testFirstFrameIsAnnouncedExactlyOnce() {
        let counts = Counts()
        let sink = makeSink(counts, Clock())
        for _ in 0..<5 { sink.present(frame()) }
        XCTAssertEqual(counts.firstFrames, 1)
        XCTAssertEqual(counts.frames, 5, "the redraw poke fires for every frame")
    }

    /// The sink outlives one viewing session on both hosts. Without the reset
    /// the next session never re-announces video, leaving the connecting
    /// placard up over a stream that is already running.
    func testResetMakesTheNextSessionAnnounceAgain() {
        let counts = Counts()
        let sink = makeSink(counts, Clock())
        sink.present(frame())
        sink.resetForNewSession()
        sink.present(frame())
        XCTAssertEqual(counts.firstFrames, 2)
    }

    /// Stats ride the fps window, not the frame — which is what keeps the
    /// common path a store plus a redraw request.
    func testStatsArePublishedOnlyWhenAWindowCloses() {
        let counts = Counts()
        let clock = Clock()
        let sink = makeSink(counts, clock)
        // Ten frames inside one second: the window has not closed.
        for _ in 0..<10 {
            clock.nowNs &+= 100_000_000
            sink.present(frame(width: 320, height: 240))
        }
        XCTAssertTrue(counts.stats.isEmpty)
        // The frame that crosses the second closes it.
        clock.nowNs &+= 100_000_000
        sink.present(frame(width: 320, height: 240))
        XCTAssertEqual(counts.stats.count, 1)
        XCTAssertEqual(counts.stats[0].width, 320)
        XCTAssertEqual(counts.stats[0].height, 240)
        XCTAssertGreaterThan(counts.stats[0].fps, 0)
    }

    /// The colour encoding travels with the stats window, and it is the
    /// CLOSING frame's — a host publishing this to its HUD would otherwise
    /// print whatever the session started with, which is the wrong answer
    /// exactly when it matters (a sharer that changed its colour settings
    /// mid-share and respawned its encoder).
    func testStatsCarryTheColorInfoOfTheClosingFrame() {
        let counts = Counts()
        let clock = Clock()
        let sink = makeSink(counts, clock)
        let full = VideoColorInfo(range: .full, primaries: .displayP3, transfer: .bt709)
        clock.nowNs &+= 500_000_000
        sink.present(frame(colorInfo: .unspecifiedLimited))
        clock.nowNs &+= 600_000_000
        sink.present(frame(colorInfo: full))
        XCTAssertEqual(counts.stats.count, 1)
        XCTAssertEqual(counts.stats[0].color, full)
        XCTAssertEqual(counts.stats[0].color.shortLabel, "P3 · full")
    }

    /// The fps window must survive a reset without carrying the idle gap
    /// between two sessions into the first reading of the second.
    func testResetForgetsTheOpenFpsWindow() {
        let counts = Counts()
        let clock = Clock()
        let sink = makeSink(counts, clock)
        sink.present(frame())
        sink.resetForNewSession()
        // An hour of idle between sessions; the next frame must open a fresh
        // window rather than close the stale one against that gap.
        clock.nowNs &+= 3_600_000_000_000
        sink.present(frame())
        XCTAssertTrue(counts.stats.isEmpty)
    }

    /// A frame the CPU blit path cannot read is dropped whole: not stored, not
    /// announced, not counted. Dropping shows as a stall; force-casting shows
    /// as a crash.
    func testAFrameOfAnotherShapeIsDroppedEntirely() {
        let counts = Counts()
        let store = FrameStore()
        let sink = makeSink(counts, Clock(), store: store)
        sink.present(ForeignFrame())
        XCTAssertNil(store.current())
        XCTAssertEqual(counts.firstFrames, 0)
        XCTAssertEqual(counts.frames, 0)
    }

    /// Every callback is optional, and a host that wires none of them still
    /// gets its frames stored. The GTK sink passes no `onFrame` at all — its
    /// repaint is requested inside `FrameStore.set`.
    func testCallbacksAreOptional() {
        let store = FrameStore()
        let sink = FrameStoreVideoSink(store: store)
        sink.present(frame(width: 16, height: 16))
        XCTAssertEqual(store.current()?.width, 16)
    }
}
