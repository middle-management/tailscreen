import CoreGraphics
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

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

    func testNonFiniteInputsMapAsZero() {
        // Swift's min/max PROPAGATE NaN, so a plain clamp would emit a NaN
        // CGPoint. globalPoint must not rely on the JSON decoder's
        // non-conforming-float rejection two layers away: non-finite input
        // maps as 0 (the captureRect origin), same policy as clampToInt32.
        let rect = CGRect(x: 100, y: 200, width: 800, height: 600)
        assertPoint(RemoteControlMapping.globalPoint(nx: .nan, ny: 0.5, captureRect: rect), 100, 500)
        assertPoint(RemoteControlMapping.globalPoint(nx: 0.5, ny: .nan, captureRect: rect), 500, 200)
        assertPoint(RemoteControlMapping.globalPoint(nx: .nan, ny: .nan, captureRect: rect), 100, 200)
        assertPoint(
            RemoteControlMapping.globalPoint(nx: .infinity, ny: -.infinity, captureRect: rect),
            100, 200)
        // And the results are always finite, whatever the input.
        let point = RemoteControlMapping.globalPoint(
            nx: .signalingNaN, ny: .infinity, captureRect: rect)
        XCTAssertTrue(point.x.isFinite)
        XCTAssertTrue(point.y.isFinite)
    }

    // MARK: - boundingRect union (app-share scoping)

    func testBoundingRectUnionsWindowRects() {
        let rects = [
            CGRect(x: 100, y: 100, width: 200, height: 150),
            CGRect(x: 400, y: 300, width: 100, height: 100)
        ]
        let union = try? XCTUnwrap(RemoteControlMapping.boundingRect(of: rects))
        XCTAssertEqual(union, CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    func testBoundingRectSingleRectIsIdentity() {
        let rect = CGRect(x: 5, y: 6, width: 7, height: 8)
        XCTAssertEqual(RemoteControlMapping.boundingRect(of: [rect]), rect)
    }

    func testBoundingRectEmptyIsNil() {
        XCTAssertNil(RemoteControlMapping.boundingRect(of: []))
    }

    // MARK: - captureRect scoping per share kind (injected resolvers)

    private func selection(_ kind: PickerSelection.Kind, windowID: UInt32? = nil) -> PickerSelection {
        PickerSelection(kind: kind, displayID: 1, windowID: windowID, bundleIDs: ["com.example.app"])
    }

    func testCaptureRectDisplayUsesDisplayBounds() {
        let displayRect = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let rect = RemoteControlMapping.captureRect(
            for: selection(.display),
            displayBounds: { _ in displayRect },
            windowBounds: { _ in nil },
            appWindowBounds: { _, _ in [] })
        XCTAssertEqual(rect, displayRect)
    }

    func testCaptureRectWindowUsesWindowBounds() {
        let windowRect = CGRect(x: 300, y: 200, width: 640, height: 480)
        let rect = RemoteControlMapping.captureRect(
            for: selection(.window, windowID: 42),
            displayBounds: { _ in .zero },
            windowBounds: { id in id == 42 ? windowRect : nil },
            appWindowBounds: { _, _ in [] })
        XCTAssertEqual(rect, windowRect)
    }

    func testCaptureRectApplicationUsesAppWindowUnionNotWholeDisplay() {
        // The whole display is far larger than the app's windows — an app
        // share must clamp to the app's window union, not the display, so a
        // granted viewer can't click the menu bar / Dock / other apps.
        let displayRect = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        let appWindows = [
            CGRect(x: 100, y: 100, width: 400, height: 300),
            CGRect(x: 700, y: 500, width: 300, height: 200)
        ]
        let rect = RemoteControlMapping.captureRect(
            for: selection(.application),
            displayBounds: { _ in displayRect },
            windowBounds: { _ in nil },
            appWindowBounds: { _, _ in appWindows })
        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 900, height: 600))
        XCTAssertNotEqual(rect, displayRect)
    }

    func testCaptureRectApplicationWithNoWindowsIsNil() {
        // No visible app windows → drop the event rather than leak onto the
        // rest of the display.
        let rect = RemoteControlMapping.captureRect(
            for: selection(.application),
            displayBounds: { _ in CGRect(x: 0, y: 0, width: 3000, height: 2000) },
            windowBounds: { _ in nil },
            appWindowBounds: { _, _ in [] })
        XCTAssertNil(rect)
    }

    func testCaptureRectWindowWithNoWindowIDIsNil() {
        let rect = RemoteControlMapping.captureRect(
            for: selection(.window, windowID: nil),
            displayBounds: { _ in .zero },
            windowBounds: { _ in CGRect(x: 1, y: 2, width: 3, height: 4) },
            appWindowBounds: { _, _ in [] })
        XCTAssertNil(rect)
    }
}
