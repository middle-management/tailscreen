import CoreGraphics
import XCTest

@testable import Tailscreen

/// Pure coordinate-mapping tests for the remote-control injector — the
/// normalized `[0, 1]` video point → global-Quartz transform, per share kind
/// (display / window / app map onto a rect), including non-zero and negative
/// origins (multi-display layouts) and out-of-range clamping. No display
/// hardware, so CI-able.
final class RemoteControlMappingTests: XCTestCase {
    private func assertPoint(_ point: CGPoint, _ x: Double, _ y: Double, line: UInt = #line) {
        XCTAssertEqual(point.x, x, accuracy: 1e-6, line: line)
        XCTAssertEqual(point.y, y, accuracy: 1e-6, line: line)
    }

    func testDisplayOriginRectCorners() {
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        assertPoint(RemoteControlMapping.globalPoint(nx: 0, ny: 0, captureRect: rect), 0, 0)
        assertPoint(RemoteControlMapping.globalPoint(nx: 1, ny: 1, captureRect: rect), 1920, 1080)
        assertPoint(RemoteControlMapping.globalPoint(nx: 0.5, ny: 0.5, captureRect: rect), 960, 540)
    }

    func testWindowRectWithNonZeroOrigin() {
        // A window share's live rect can sit anywhere on the desktop.
        let rect = CGRect(x: 100, y: 200, width: 800, height: 600)
        assertPoint(RemoteControlMapping.globalPoint(nx: 0, ny: 0, captureRect: rect), 100, 200)
        assertPoint(RemoteControlMapping.globalPoint(nx: 1, ny: 1, captureRect: rect), 900, 800)
        assertPoint(RemoteControlMapping.globalPoint(nx: 0.25, ny: 0.75, captureRect: rect), 300, 650)
    }

    func testSecondDisplayNegativeOrigin() {
        // A display to the left of the primary has a negative Quartz origin.
        let rect = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        assertPoint(RemoteControlMapping.globalPoint(nx: 0, ny: 0, captureRect: rect), -1920, 0)
        assertPoint(RemoteControlMapping.globalPoint(nx: 0.5, ny: 0.5, captureRect: rect), -960, 540)
        assertPoint(RemoteControlMapping.globalPoint(nx: 1, ny: 1, captureRect: rect), 0, 1080)
    }

    func testOutOfRangeInputsClampIntoRect() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 200)
        // Above 1 clamps to the far edge; below 0 clamps to the origin.
        assertPoint(RemoteControlMapping.globalPoint(nx: 1.5, ny: 2.0, captureRect: rect), 110, 220)
        assertPoint(RemoteControlMapping.globalPoint(nx: -0.5, ny: -3.0, captureRect: rect), 10, 20)
    }
}
