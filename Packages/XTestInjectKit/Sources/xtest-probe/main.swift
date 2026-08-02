import CXTestInject
import Foundation
import TailscreenProtocol
import XTestInjectKit

// xtest-probe — two jobs, both of which CI can do and neither of which a
// library target can.
//
//   xtest-probe --audit-keysyms   walk X11KeyCodeMapping through Xlib's own
//                                 keysym tables and fail on any name Xlib does
//                                 not know. Needs NO X server.
//   xtest-probe --live-check      inject a real pointer move against the
//                                 current display and read the pointer back.
//                                 Needs an X server (CI uses Xvfb) and MOVES
//                                 THE CURSOR, which is why it is opt-in.
//   xtest-probe                   open the display, report what it found, and
//                                 print what a sample gesture WOULD inject
//                                 (via the test seam — it moves no cursor).
//
// The link check is the reason this is an executable at all: a SwiftPM library
// target is compiled but never linked, so a missing `-lX11` stays invisible
// until something downstream links it. That is how WASAPIKit's missing GUIDs
// passed their own CI step and failed eleven minutes later in the app.

let args = Array(CommandLine.arguments.dropFirst())

func out(_ s: String) { FileHandle.standardOutput.write(Data("\(s)\n".utf8)) }

if args.contains("--audit-keysyms") {
    // Every value in the table is a hand-written hex constant, and a typo that
    // lands on an UNASSIGNED keysym fails completely silently: the mapping
    // succeeds, XKeysymToKeycode returns 0, the keystroke is dropped, and the
    // only symptom is that one key does nothing on Linux sharers. Xlib's own
    // tables are the authority, so ask them.
    //
    // It cannot catch a typo that lands on a DIFFERENT VALID keysym — Home
    // arriving as End would pass this. That class is covered by the unit
    // tests' spot rows, which assert specific pairs.
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
    // The one thing no unit test can check: that XTEST actually moves the
    // pointer on a real server. Everything up to the Xlib call is covered by
    // XTestInjectKitTests through the inject-nothing seam; this covers the
    // call, the flush (without which nothing reaches the server at all), and
    // the display/extension gate.
    let injector = XTestInjector()
    guard injector.isTrusted() else {
        out("XTEST_LIVE result=FAIL no display, or the server has no XTEST extension")
        exit(3)
    }
    guard let region = injector.rootRegion() else {
        out("XTEST_LIVE result=FAIL could not read the root window size")
        exit(3)
    }
    // A quarter in from the top-left, so the target is nowhere near wherever
    // the pointer already was — a test that passes because nothing moved is
    // not a test.
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

// Dry run through the test seam. Nothing is injected: the point is to show the
// translation, which is what a person debugging "the remote pointer is in the
// wrong place" actually wants to see.
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
