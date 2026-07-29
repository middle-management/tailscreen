import XCTest

@testable import TailscreenProtocol

/// The Windows key ↔ HID table. Values are Windows-specific; the test is not,
/// and runs on Linux CI — which is the whole reason the table lives in the
/// portable tier rather than beside the injector that uses it.
final class WindowsKeyCodeMappingTests: XCTestCase {
    private typealias Key = WindowsKeyCodeMapping.WindowsKey

    /// The property that matters: every key survives HID → Windows → HID
    /// unchanged.
    ///
    /// A collision — two HID usages claiming one Windows key — would silently
    /// make one of them inject as the other, and only for the one that lost the
    /// dictionary race.
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

    /// No two HID usages may map to the same Windows key. Implied by the round
    /// trip, but asserted directly so a failure names the count rather than one
    /// arbitrary loser.
    func testWindowsKeysAreUnique() {
        let keys = WindowsKeyCodeMapping.windowsKeyByHIDUsage.values
        XCTAssertEqual(Set(keys).count, keys.count, "two HID usages map to one Windows key")
    }

    /// Return and keypad Enter share `VK_RETURN` and differ only in the
    /// extended bit. This is the case that forced the table to key on the pair
    /// rather than on the virtual-key code alone — if the model regresses, this
    /// is where it shows.
    func testKeypadEnterIsReturnPlusExtended() {
        let ret = WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x28)
        let keypad = WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x58)
        XCTAssertEqual(ret, Key(0x0D, extended: false))
        XCTAssertEqual(keypad, Key(0x0D, extended: true))
        XCTAssertEqual(ret?.virtualKey, keypad?.virtualKey)
        XCTAssertNotEqual(ret, keypad)
    }

    /// Spot rows, written independently of the table's construction.
    func testKnownKeys() {
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x04), Key(0x41))  // A
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x1D), Key(0x5A))  // Z
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x1E), Key(0x31))  // 1
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x26), Key(0x39))  // 9
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x2C), Key(0x20))  // Space
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x3A), Key(0x70))  // F1
    }

    /// '0' sits at the END of HID's digit run and the START of ASCII's. An
    /// off-by-one here shifts every digit and is invisible until someone types
    /// a number.
    func testDigitZeroIsNotOffByOne() {
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x27), Key(0x30))  // 0
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0x1E), Key(0x31))  // 1
    }

    /// The mac and Windows tables are reference tables for the same wire
    /// vocabulary, so every usage a mac can SEND must be one a Windows sharer
    /// can INJECT — or be explicitly listed as unmappable.
    ///
    /// This test found nine real gaps on first run, including keypad Enter,
    /// which is what exposed the virtual-key-code-alone model as wrong.
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

    /// The unmappable set must be exactly what a mac can send and Windows does
    /// not handle — no more. An entry for a usage that IS mapped, or that no
    /// peer sends, is dead documentation that reads as a considered decision.
    func testUnmappedSetIsExactlyTheRealGaps() {
        let windows = Set(WindowsKeyCodeMapping.windowsKeyByHIDUsage.keys)
        let mac = Set(MacKeyCodeMapping.hidUsageByMacKeyCode.values)
        XCTAssertEqual(
            WindowsKeyCodeMapping.deliberatelyUnmapped, mac.subtracting(windows),
            "the documented-unmappable set has drifted from the actual gap")
    }

    /// Nothing may be both mapped and documented as unmappable.
    func testUnmappedSetDoesNotOverlapTheTable() {
        for usage in WindowsKeyCodeMapping.deliberatelyUnmapped {
            XCTAssertNil(
                WindowsKeyCodeMapping.windowsKey(forHIDUsage: usage),
                "0x\(String(usage, radix: 16)) is both mapped and listed unmappable")
        }
    }

    // MARK: - The extended bit

    /// Keys sharing a virtual-key code with a keypad twin MUST carry the
    /// extended bit. Omitting it does not fail — it injects the numpad key
    /// instead, so Home arrives as keypad-7 whenever NumLock is off.
    func testNavigationClusterIsExtended() {
        // Insert, Home, PageUp, Delete, End, PageDown, →, ←, ↓, ↑
        for usage: UInt16 in [0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52] {
            let key = WindowsKeyCodeMapping.windowsKey(forHIDUsage: usage)
            XCTAssertEqual(
                key?.isExtended, true,
                "HID 0x\(String(usage, radix: 16)) needs KEYEVENTF_EXTENDEDKEY")
        }
    }

    /// Right-hand modifiers likewise: without the bit, right Alt injects as
    /// left Alt, which breaks AltGr layouts specifically.
    func testRightHandModifiersAreExtended() {
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE4)?.isExtended, true)  // RCtl
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE6)?.isExtended, true)  // RAlt
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE0)?.isExtended, false)  // LCtl
        XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: 0xE2)?.isExtended, false)  // LAlt
    }

    /// The main-row keys must NOT be extended: setting the bit on a plain
    /// letter is as wrong as omitting it on an arrow.
    func testOrdinaryKeysAreNotExtended() {
        for usage: UInt16 in [0x04, 0x1E, 0x28, 0x2C, 0x3A] {  // A, 1, Return, Space, F1
            XCTAssertEqual(WindowsKeyCodeMapping.windowsKey(forHIDUsage: usage)?.isExtended, false)
        }
    }

    // MARK: - Refusals

    /// An unmappable usage returns nil rather than a plausible neighbour.
    /// Guessing types the wrong character, which is worse than typing nothing.
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
