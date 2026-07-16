import XCTest

@testable import Tailscreen

/// Pins the mac virtual-keycode ↔ USB HID usage table that carries key
/// events across the platform-neutral wire (`InputEvent.keyDown/.keyUp`).
/// The viewer maps kVK → HID on capture; the injector maps HID → kVK on
/// injection — so a mac→mac session must reproduce the exact hardware
/// keycode, which is what the bijectivity leg guarantees.
final class MacKeyCodeMappingTests: XCTestCase {
    func testTableIsBijective() {
        let forward = MacKeyCodeMapping.hidUsageByMacKeyCode
        let backward = MacKeyCodeMapping.macKeyCodeByHIDUsage
        // No two mac keycodes may share a HID usage (inversion would
        // silently drop one and mac→mac injection would type a wrong key).
        XCTAssertEqual(Set(forward.values).count, forward.count)
        XCTAssertEqual(backward.count, forward.count)
        for (mac, hid) in forward {
            XCTAssertEqual(backward[hid], mac, "HID 0x\(String(hid, radix: 16)) must invert")
        }
    }

    func testMacToMacRoundTripReproducesKeycode() {
        for mac in MacKeyCodeMapping.hidUsageByMacKeyCode.keys {
            let hid = MacKeyCodeMapping.hidUsage(forMacKeyCode: mac)
            XCTAssertNotNil(hid)
            XCTAssertEqual(MacKeyCodeMapping.macKeyCode(forHIDUsage: hid ?? 0), mac)
        }
    }

    func testSpotValues() {
        // Letters: kVK_ANSI_A = 0x00 → HID 0x04; Z = 0x06 → 0x1D.
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x00), 0x04)
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x06), 0x1D)
        // Return → Enter, Escape, Space, Tab, Backspace.
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x24), 0x28)
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x35), 0x29)
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x31), 0x2C)
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x30), 0x2B)
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x33), 0x2A)
        // Arrows.
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x7B), 0x50)  // ←
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x7C), 0x4F)  // →
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x7D), 0x51)  // ↓
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x7E), 0x52)  // ↑
        // Modifier keys land on HID's 0xE0–0xE7 block.
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x37), 0xE3)  // ⌘
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x38), 0xE1)  // ⇧
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x3A), 0xE2)  // ⌥
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x3B), 0xE0)  // ⌃
        // Keypad Enter is distinct from Return.
        XCTAssertEqual(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x4C), 0x58)
    }

    func testUnmappableCodesReturnNil() {
        // fn (kVK_Function) has no HID keyboard-page usage.
        XCTAssertNil(MacKeyCodeMapping.hidUsage(forMacKeyCode: 0x3F))
        // Insert / PrintScreen / Pause exist in HID but not on mac keyboards.
        XCTAssertNil(MacKeyCodeMapping.macKeyCode(forHIDUsage: 0x49))
        XCTAssertNil(MacKeyCodeMapping.macKeyCode(forHIDUsage: 0x46))
        XCTAssertNil(MacKeyCodeMapping.macKeyCode(forHIDUsage: 0x48))
        // HID 0x00–0x03 are reserved/error usages, never keys.
        XCTAssertNil(MacKeyCodeMapping.macKeyCode(forHIDUsage: 0x00))
    }

    func testViewerCaptureModifierMapping() {
        XCTAssertEqual(RemoteControlInputView.keyModifiers(from: []), [])
        XCTAssertEqual(RemoteControlInputView.keyModifiers(from: [.shift]), [.shift])
        XCTAssertEqual(
            RemoteControlInputView.keyModifiers(from: [.command, .option, .control, .shift, .capsLock]),
            [.meta, .alt, .control, .shift, .capsLock])
        // fn deliberately has no neutral bit.
        XCTAssertEqual(RemoteControlInputView.keyModifiers(from: [.function]), [])
    }
}
