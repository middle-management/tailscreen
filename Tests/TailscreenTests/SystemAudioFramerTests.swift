import XCTest

@testable import Tailscreen

/// Pure framing math for the helper-side system-audio tap. Mirrors
/// `TapBuffer.appendAndDrain`'s 1024-sample boundary semantics without any
/// CoreMedia buffers, so it runs on CI.
final class SystemAudioFramerTests: XCTestCase {
    func testExactBoundaryEmitsOneFrame() {
        var framer = SystemAudioFramer()
        let frames = framer.append([Float](repeating: 0.5, count: 1024))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.count, 1024)
        XCTAssertEqual(framer.pendingCount, 0)
    }

    func testRemainderIsCarried() {
        var framer = SystemAudioFramer()
        let frames = framer.append([Float](repeating: 0, count: 1500))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(framer.pendingCount, 1500 - 1024)
    }

    func testMultiFrameDrain() {
        var framer = SystemAudioFramer()
        let frames = framer.append([Float](repeating: 0, count: 1024 * 3 + 10))
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(framer.pendingCount, 10)
    }

    func testAccumulatesAcrossCalls() {
        var framer = SystemAudioFramer()
        XCTAssertTrue(framer.append([Float](repeating: 0, count: 500)).isEmpty)
        XCTAssertEqual(framer.pendingCount, 500)
        let frames = framer.append([Float](repeating: 0, count: 600))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(framer.pendingCount, 500 + 600 - 1024)
    }

    func testFrameContentsPreserveOrder() {
        var framer = SystemAudioFramer()
        let input = (0..<1024).map { Float($0) }
        let frames = framer.append(input)
        XCTAssertEqual(frames.first, input)
    }

    func testEmptyAppendDrainsNothing() {
        var framer = SystemAudioFramer()
        XCTAssertTrue(framer.append([]).isEmpty)
        XCTAssertEqual(framer.pendingCount, 0)
    }
}
