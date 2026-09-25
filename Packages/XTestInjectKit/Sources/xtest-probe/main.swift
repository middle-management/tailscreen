import CXTestInject
import Foundation
import TailscreenProtocol
import XTestInjectKit

// xtest-probe:
//   --audit-keysyms   check X11KeyCodeMapping against Xlib's keysym tables.
//                     No X server needed.
//   --live-check      inject a real pointer move and read it back. Needs an
//                     X server (CI: Xvfb) and MOVES THE CURSOR — opt-in.
//   (default)         open the display, report findings, print what a sample
//                     gesture would inject via the test seam (no cursor move).
//
// An executable so the link check itself is exercised: a library target is
// compiled but never linked, so a missing `-lX11` stays invisible until
// something downstream links it.

let args = Array(CommandLine.arguments.dropFirst())

func out(_ s: String) { FileHandle.standardOutput.write(Data("\(s)\n".utf8)) }

if args.contains("--audit-keysyms") {
    // A typo landing on an unassigned keysym fails silently (XKeysymToKeycode
    // returns 0, the keystroke is dropped) — check against Xlib's own tables.
    // Cannot catch a typo landing on a different VALID keysym; unit tests'
    // spot rows cover that.
    var bad: [(UInt16, UInt32)] = []
    for (hid, keysym) in X11KeyCodeMapping.keysymByHIDUsage.sorted(by: { $0.key < $1.key }) {
        if ts_xtest_keysym_name(keysym) == nil {
            bad.append((hid, keysym))
        }
    }
    let total = X11KeyCodeMapping.keysymByHIDUsage.count
    if bad.isEmpty {
        out("XTEST_KEYSYM_AUDIT result=PASS mapped=\(total)")
        exit(0)
    }
    for (hid, keysym) in bad {
        out(String(format: "  HID 0x%02X → keysym 0x%04X has no name in Xlib", hid, keysym))
    }
    out("XTEST_KEYSYM_AUDIT result=FAIL mapped=\(total) unnamed=\(bad.count)")
    exit(3)
}

if args.contains("--live-check") {
    // Covers what XTestInjectKitTests' inject-nothing seam can't: the real
    // Xlib call, the flush, and the display/extension gate.
    let injector = XTestInjector()
    guard injector.isTrusted() else {
        out("XTEST_LIVE result=FAIL no display, or the server has no XTEST extension")
        exit(3)
    }
    guard let region = injector.rootRegion() else {
        out("XTEST_LIVE result=FAIL could not read the root window size")
        exit(3)
    }
    // A quarter in from the top-left so a no-op wouldn't accidentally pass.
    let target = region.point(normalizedX: 0.25, normalizedY: 0.25)
    injector.activate(region: region)
    injector.apply(.mouseMove(x: 0.25, y: 0.25))
    injector.drainSyncForTesting()
    guard let landed = injector.pointerPosition() else {
        out("XTEST_LIVE result=FAIL could not read the pointer back")
        exit(3)
    }
    injector.deactivate()
    let matched = landed.x == target.x && landed.y == target.y
    let detail =
        "target=(\(target.x),\(target.y)) actual=(\(landed.x),\(landed.y)) "
        + "root=\(region.width)x\(region.height)"
    out("XTEST_LIVE result=\(matched ? "PASS" : "FAIL") \(detail)")
    exit(matched ? 0 : 3)
}

let injector = XTestInjector()
out("trusted (display opens and has XTEST): \(injector.isTrusted())")
if let region = injector.rootRegion() {
    out("root: \(region.width)x\(region.height)")
} else {
    out("root: unavailable")
}

// Dry run through the test seam: shows the translation without injecting.
var recorded: [XTestInjector.InjectedAction] = []
injector.onInjectForTesting = { recorded.append($0) }
let region = injector.rootRegion() ?? XTestInjector.Region(x: 0, y: 0, width: 1920, height: 1080)
injector.activate(region: region)
injector.apply(.mouseMove(x: 0.5, y: 0.5))
injector.apply(.mouseDown(x: 0.5, y: 0.5, button: .left, modifiers: []))
injector.apply(.mouseUp(x: 0.5, y: 0.5, button: .left, modifiers: []))
injector.apply(.scroll(x: 0.5, y: 0.5, deltaX: 0, deltaY: -3, modifiers: []))
injector.apply(.keyDown(key: 0x06, modifiers: [.control]))  // Ctrl+C
injector.apply(.keyUp(key: 0x06, modifiers: [.control]))
injector.drainSyncForTesting()
out("would inject \(recorded.count) actions against \(region.width)x\(region.height):")
for action in recorded { out("  \(action)") }
injector.deactivate()
