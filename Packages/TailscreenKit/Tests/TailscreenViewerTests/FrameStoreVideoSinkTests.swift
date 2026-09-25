import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenViewer

/// Tests for `FrameStoreVideoSink` — the store-plus-callbacks sink both
/// swift-cross-ui viewers share. Covers the legs a per-host copy gets wrong:
/// double-announcing the first frame, missing the re-announce after a reset,
/// publishing stats per-frame instead of per-window, forwarding an unreadable
/// frame shape.
final class FrameStoreVideoSinkTests: XCTestCase {
    /// The case the `as?` guard exists for; nothing shipping emits one.
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

    /// `present` is documented as driven serially, so no lock is needed.
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

    func testFirstFrameIsAnnouncedExactlyOnce() {
        let counts = Counts()
        let sink = makeSink(counts, Clock())
        for _ in 0..<5 { sink.present(frame()) }
        XCTAssertEqual(counts.firstFrames, 1)
        XCTAssertEqual(counts.frames, 5, "the redraw poke fires for every frame")
    }

    /// The sink outlives one viewing session; without reset the next session
    /// never re-announces, leaving the connecting placard up.
    func testResetMakesTheNextSessionAnnounceAgain() {
        let counts = Counts()
        let sink = makeSink(counts, Clock())
        sink.present(frame())
        sink.resetForNewSession()
        sink.present(frame())
        XCTAssertEqual(counts.firstFrames, 2)
    }

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

    /// Colour info travels with the closing frame, not whatever the session
    /// started with — matters when a sharer changes colour settings mid-share.
    func testStatsCarryTheColorInfoOfTheClosingFrame() throws {
        let counts = Counts()
        let clock = Clock()
        let sink = makeSink(counts, clock)
        let full = VideoColorInfo(range: .full, primaries: .displayP3, transfer: .bt709)
        clock.nowNs &+= 500_000_000
        sink.present(frame(colorInfo: .unspecifiedLimited))
        clock.nowNs &+= 1_100_000_000
        sink.present(frame(colorInfo: full))
        let published = try XCTUnwrap(counts.stats.first)
        XCTAssertEqual(counts.stats.count, 1)
        XCTAssertEqual(published.color, full)
        XCTAssertEqual(published.color.shortLabel, "P3 · full")
    }

    func testResetForgetsTheOpenFpsWindow() {
        let counts = Counts()
        let clock = Clock()
        let sink = makeSink(counts, clock)
        sink.present(frame())
        sink.resetForNewSession()
        // An hour idle; must open a fresh window, not close the stale one.
        clock.nowNs &+= 3_600_000_000_000
        sink.present(frame())
        XCTAssertTrue(counts.stats.isEmpty)
    }

    /// Dropped whole rather than force-cast: dropping shows as a stall,
    /// force-casting shows as a crash.
    func testAFrameOfAnotherShapeIsDroppedEntirely() {
        let counts = Counts()
        let store = FrameStore()
        let sink = makeSink(counts, Clock(), store: store)
        sink.present(ForeignFrame())
        XCTAssertNil(store.current())
        XCTAssertEqual(counts.firstFrames, 0)
        XCTAssertEqual(counts.frames, 0)
    }

    /// GTK passes no `onFrame` at all — its repaint is requested inside
    /// `FrameStore.set`.
    func testCallbacksAreOptional() {
        let store = FrameStore()
        let sink = FrameStoreVideoSink(store: store)
        sink.present(frame(width: 16, height: 16))
        XCTAssertEqual(store.current()?.width, 16)
    }
}
