import XCTest

@testable import TailscreenProtocol

/// The Windows key ↔ HID table. Values are Windows-specific; the test is not,
/// and runs on Linux CI — which is the whole reason the table lives in the
/// portable tier rather than beside the injector that uses it.
final class WindowsKeyCodeMappingTests: XCTestCase {
    private typealias Key = WindowsKeyCodeMapping.WindowsKey

    /// A collision (two HID usages claiming one Windows key) would silently
    /// make one inject as the other.
    func testRoundTripIsExact() {
        for (usage, key) in WindowsKeyCodeMapping.windowsKeyByHIDUsage {
            let back = WindowsKeyCodeMapping.hidUsage(
                forVirtualKey: key.virtualKey, extended: key.isExtended)
            XCTAssertEqual(
                back, usage,
                "HID 0x\(String(usage, radix: 16)) → VK 0x\(String(key.virtualKey, radix: 16))"
                    + "\(key.isExtended ? "+ext" : "") → HID 0x\(String(back ?? 0, radix: 16))")
        }
    }

    /// Implied by the round trip, but asserted directly so a failure names
    /// the count rather than one arbitrary loser.
    func testWindowsKeysAreUnique() {
        let keys = WindowsKeyCodeMapping.windowsKeyByHIDUsage.values
        XCTAssertEqual(Set(keys).count, keys.count, "two HID usages map to one Windows key")
    }

    /// Return and keypad Enter share `VK_RETURN`, differing only in the
    /// extended bit — the case that forced the table to key on the pair
    /// rather than the virtual-key code alone.
    func testKeypadEnterIsReturnPlusExtended() {
        let ret = WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x28)
        let keypad = WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x58)
        XCTAssertEqual(ret, Key(0x0D, extended: false))
        XCTAssertEqual(keypad, Key(0x0D, extended: true))
        XCTAssertEqual(ret?.virtualKey, keypad?.virtualKey)
        XCTAssertNotEqual(ret, keypad)
    }

    func testKnownKeys() {
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x04), Key(0x41))  // A
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x1D), Key(0x5A))  // Z
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x1E), Key(0x31))  // 1
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x26), Key(0x39))  // 9
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x2C), Key(0x20))  // Space
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x3A), Key(0x70))  // F1
    }

    /// '0' sits at the END of HID's digit run and the START of ASCII's.
    func testDigitZeroIsNotOffByOne() {
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x27), Key(0x30))  // 0
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x1E), Key(0x31))  // 1
    }

    /// Every usage a mac can SEND must be one Windows can INJECT, or be
    /// explicitly listed as unmappable.
    func testEveryUsageAMacCanSendIsHandled() {
        let windows = Set(WindowsKeyCodeMapping.windowsKeyByHIDUsage.keys)
        let mac = Set(MacKeyCodeMapping.hidUsageByMacKeyCode.values)

        let unhandled = mac.subtracting(windows)
            .subtracting(WindowsKeyCodeMapping.deliberatelyUnmapped)
        XCTAssertTrue(
            unhandled.isEmpty,
            "a mac peer can send HID usages Windows neither injects nor documents as unmappable: "
                + "\(unhandled.sorted().map { "0x" + String($0, radix: 16) })")
    }

    /// An entry for a usage that IS mapped, or that no peer sends, is dead
    /// documentation that reads as a considered decision.
    func testUnmappedSetIsExactlyTheRealGaps() {
        let windows = Set(WindowsKeyCodeMapping.windowsKeyByHIDUsage.keys)
        let mac = Set(MacKeyCodeMapping.hidUsageByMacKeyCode.values)
        XCTAssertEqual(
            WindowsKeyCodeMapping.deliberatelyUnmapped, mac.subtracting(windows),
            "the documented-unmappable set has drifted from the actual gap")
    }

    func testUnmappedSetDoesNotOverlapTheTable() {
        for usage in WindowsKeyCodeMapping.deliberatelyUnmapped {
            XCTAssertNil(
                WindowsKeyCodeMapping.windowsKey(forHIDUsage: usage),
                "0x\(String(usage, radix: 16)) is both mapped and listed unmappable")
        }
    }

    // MARK: - The extended bit

    /// Omitting the extended bit injects the numpad key instead — Home
    /// arrives as keypad-7 whenever NumLock is off.
    func testNavigationClusterIsExtended() {
        // Insert, Home, PageUp, Delete, End, PageDown, →, ←, ↓, ↑
        for usage: UInt16 in [0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52] {
            let key = WindowsKeyCodeMapping.windowsKey(forHIDUsage: usage)
            XCTAssertEqual(
                key?.isExtended, true,
                "HID 0x\(String(usage, radix: 16)) needs KEYEVENTF_EXTENDEDKEY")
        }
    }

    /// Without the bit, right Alt injects as left Alt, breaking AltGr layouts.
    func testRightHandModifiersAreExtended() {
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE4)?.isExtended, true)  // RCtl
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE6)?.isExtended, true)  // RAlt
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE0)?.isExtended, false)  // LCtl
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE2)?.isExtended, false)  // LAlt
    }

    func testOrdinaryKeysAreNotExtended() {
        for usage: UInt16 in [0x04, 0x1E, 0x28, 0x2C, 0x3A] {  // A, 1, Return, Space, F1
            XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: usage)?.isExtended, false)
        }
    }

    // MARK: - Refusals

    /// Guessing types the wrong character, worse than typing nothing.
    func testUnknownUsageIsNil() {
        XCTAssertNil(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x00))
        XCTAssertNil(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xFF))
    }

    /// The generic modifiers are deliberately absent from the reverse
    /// direction: `VK_SHIFT` without a side is ambiguous.
    func testGenericModifiersAreNotMapped() {
        XCTAssertNil(WindowsKeyCodeMapping.hidUsage(forVirtualKey: 0x10))  // VK_SHIFT
        XCTAssertNil(WindowsKeyCodeMapping.hidUsage(forVirtualKey: 0x11))  // VK_CONTROL
        XCTAssertNil(WindowsKeyCodeMapping.hidUsage(forVirtualKey: 0x12))  // VK_MENU
    }
}
