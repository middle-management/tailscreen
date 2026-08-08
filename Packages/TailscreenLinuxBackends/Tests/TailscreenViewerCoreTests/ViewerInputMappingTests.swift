import Foundation
import XCTest

@testable import TailscreenProtocol
@testable import TailscreenViewerCore

/// Pure-logic coverage for the GTK viewer's remote-control capture mapping
/// (`ViewerInputMapping`) — the half that's testable without a live display.
final class ViewerInputMappingTests: XCTestCase {

    // MARK: normalizePointer

    func testNormalizeCentreOfSquareInSquare() {
        // Video and widget same aspect → no letterbox; centre maps to (0.5,0.5).
        let (x, y) = ViewerInputMapping.normalizePointer(
            px: 100, py: 100, widgetW: 200, widgetH: 200, videoW: 640, videoH: 640)
        XCTAssertEqual(x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(y, 0.5, accuracy: 1e-9)
    }

    func testNormalizeLetterboxTopBottom() {
        // 16:9 video in a 1:1 widget → fit to width, letterbox top+bottom.
        // Content height = 200 * 9/16 = 112.5, offsetY = (200-112.5)/2 = 43.75.
        let w = 200.0
        let h = 200.0
        let vw = 1600
        let vh = 900
        // Top-left of the content rect maps to (0,0).
        let tl = ViewerInputMapping.normalizePointer(px: 0, py: 43.75, widgetW: w, widgetH: h, videoW: vw, videoH: vh)
        XCTAssertEqual(tl.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(tl.y, 0.0, accuracy: 1e-6)
        // Centre of widget is centre of content.
        let c = ViewerInputMapping.normalizePointer(px: 100, py: 100, widgetW: w, widgetH: h, videoW: vw, videoH: vh)
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-6)
    }

    func testNormalizeClampsLetterboxBarToEdge() {
        // A click in the top letterbox bar (py above the content rect) clamps to
        // the top edge (y == 0), never a negative/out-of-frame coordinate.
        let p = ViewerInputMapping.normalizePointer(
            px: 100, py: 5, widgetW: 200, widgetH: 200, videoW: 1600, videoH: 900)
        XCTAssertEqual(p.y, 0.0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(p.x, 0.0)
        XCTAssertLessThanOrEqual(p.x, 1.0)
    }

    func testNormalizeLetterboxLeftRight() {
        // Tall video in a wide widget → fit to height, letterbox left+right.
        // 9:16 video in 2:1 widget: content width = 200 * (9/16... ) via height.
        let w = 400.0
        let h = 200.0
        let vw = 900
        let vh = 1600
        let frameAspect = Double(vw) / Double(vh)  // 0.5625
        let contentW = h * frameAspect  // 112.5
        let offsetX = (w - contentW) / 2  // 143.75
        let mid = ViewerInputMapping.normalizePointer(
            px: offsetX + contentW / 2, py: 100, widgetW: w, widgetH: h, videoW: vw, videoH: vh)
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(mid.y, 0.5, accuracy: 1e-6)
    }

    func testNormalizeDegenerateInputs() {
        // Zero sizes must not divide-by-zero; return a safe (0,0).
        let z = ViewerInputMapping.normalizePointer(px: 10, py: 10, widgetW: 0, widgetH: 0, videoW: 0, videoH: 0)
        XCTAssertEqual(z.x, 0.0)
        XCTAssertEqual(z.y, 0.0)
    }

    // MARK: mouseButton

    func testMouseButtonMapping() {
        XCTAssertEqual(ViewerInputMapping.mouseButton(fromGdk: 1), .left)
        XCTAssertEqual(ViewerInputMapping.mouseButton(fromGdk: 2), .middle)
        XCTAssertEqual(ViewerInputMapping.mouseButton(fromGdk: 3), .right)
        XCTAssertNil(ViewerInputMapping.mouseButton(fromGdk: 8))  // back button dropped
        XCTAssertNil(ViewerInputMapping.mouseButton(fromGdk: 0))
    }

    // MARK: keyModifiers

    func testKeyModifiersFromGdkState() {
        XCTAssertEqual(ViewerInputMapping.keyModifiers(fromGdkState: 0), [])
        XCTAssertTrue(ViewerInputMapping.keyModifiers(fromGdkState: 1 << 0).contains(.shift))
        XCTAssertTrue(ViewerInputMapping.keyModifiers(fromGdkState: 1 << 1).contains(.capsLock))
        XCTAssertTrue(ViewerInputMapping.keyModifiers(fromGdkState: 1 << 2).contains(.control))
        XCTAssertTrue(ViewerInputMapping.keyModifiers(fromGdkState: 1 << 3).contains(.alt))
        XCTAssertTrue(ViewerInputMapping.keyModifiers(fromGdkState: 1 << 26).contains(.meta))
        // Combined shift+control, and an unknown bit that must be ignored.
        let combined = ViewerInputMapping.keyModifiers(fromGdkState: (1 << 0) | (1 << 2) | (1 << 5))
        XCTAssertEqual(combined, [.shift, .control])
    }

    // MARK: hidUsage (evdev → HID)

    func testHidUsageSpotRows() {
        // GDK hardware keycode = evdev + 8. 'A' is evdev 30 → keycode 38 → HID 0x04.
        XCTAssertEqual(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 30 + 8), 0x04)  // A
        XCTAssertEqual(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 44 + 8), 0x1D)  // Z
        XCTAssertEqual(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 2 + 8), 0x1E)  // '1'
        XCTAssertEqual(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 28 + 8), 0x28)  // Enter
        XCTAssertEqual(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 57 + 8), 0x2C)  // Space
        XCTAssertEqual(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 103 + 8), 0x52)  // Up arrow
        XCTAssertEqual(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 59 + 8), 0x3A)  // F1
    }

    func testHidUsageUnmappedIsNil() {
        // An evdev code with no table entry (e.g. 190, some vendor key) → nil.
        XCTAssertNil(ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: 190 + 8))
    }

    func testHidUsageTableHasNoDuplicates() {
        // A physical→HID table must be injective; a dup would mean two physical
        // keys collapse to one usage.
        let usages = Array(ViewerInputMapping.evdevToHID.values)
        XCTAssertEqual(usages.count, Set(usages).count, "duplicate HID usage in evdev→HID table")
    }

    // MARK: isModifierUsage

    func testIsModifierUsage() {
        XCTAssertTrue(ViewerInputMapping.isModifierUsage(0xE0))  // LeftCtrl
        XCTAssertTrue(ViewerInputMapping.isModifierUsage(0xE1))  // LeftShift
        XCTAssertTrue(ViewerInputMapping.isModifierUsage(0xE7))  // RightMeta
        XCTAssertFalse(ViewerInputMapping.isModifierUsage(0x04))  // A
        XCTAssertFalse(ViewerInputMapping.isModifierUsage(0x39))  // CapsLock is not a 0xEx modifier
    }
}
