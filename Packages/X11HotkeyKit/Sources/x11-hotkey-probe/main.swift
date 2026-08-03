import Foundation
import TailscreenProtocol
import X11HotkeyKit
import XTestInjectKit

// x11-hotkey-probe — the link check, and the one gate that presses a real key.
//
//   x11-hotkey-probe --live-check   grab the mute chord on the current display,
//                                   synthesize it through XTEST, and assert the
//                                   grab fired. Then grab it a SECOND time from
//                                   another connection and assert it is
//                                   REFUSED. Needs an X server (CI uses Xvfb).
//   x11-hotkey-probe --support      print the environment decision and exit 0.
//   x11-hotkey-probe                report what it found on this display.
//
// The link check is why this is an executable at all: a SwiftPM library target
// is compiled but never linked, so a missing `-lX11` stays invisible until
// something downstream links it.
//
// The live check exists because everything else about this feature is testable
// without a server — the mapping, the mask variants, the repeat latch — and
// the two things that are not are exactly the two that fail silently: a grab
// that was refused and reported as taken, and a grabbed key the server never
// delivers.

let args = Array(CommandLine.arguments.dropFirst())

func out(_ line: String) { FileHandle.standardOutput.write(Data("\(line)\n".utf8)) }

/// The chord under test: whatever the catalog says the mute hotkey is. Reading
/// it from the catalog rather than hard-coding ⌃⌥M is the point — if somebody
/// retunes the shortcut, this gate follows it instead of testing a chord the
/// app no longer uses.
guard let micEntry = ShortcutCatalog.entry(for: .toggleMicrophone) else {
    out("X11_HOTKEY result=FAIL the catalog has no toggleMicrophone entry")
    exit(3)
}

if args.contains("--support") {
    if let reason = X11HotkeySupport.decideFromEnvironment() {
        out("X11_HOTKEY_SUPPORT result=UNAVAILABLE reason=\(reason) detail=\(reason.reason)")
    } else {
        out("X11_HOTKEY_SUPPORT result=AVAILABLE")
    }
    exit(0)
}

if args.contains("--live-check") {
    if let reason = X11HotkeySupport.decideFromEnvironment() {
        out("X11_HOTKEY_LIVE result=FAIL environment says \(reason.reason)")
        exit(3)
    }
    guard let hotkey = X11Hotkey() else {
        out("X11_HOTKEY_LIVE result=FAIL could not open a display")
        exit(3)
    }
    if let failure = hotkey.grab(micEntry.chord) {
        out("X11_HOTKEY_LIVE result=FAIL grab refused: \(failure.reason)")
        exit(3)
    }
    out(
        "grabbed \(micEntry.chord.display(.words)) "
            + "detectableAutoRepeat=\(hotkey.honoursDetectableAutoRepeat)")

    // Phase 1 — a grabbed key must actually be delivered.
    //
    // Synthesized through XTEST because that is the only way to press a key
    // with nobody at the keyboard. It goes through the server's ordinary event
    // processing, grabs included, so what this proves is the real path.
    let injector = XTestInjector()
    guard injector.isTrusted(), let region = injector.rootRegion() else {
        out("X11_HOTKEY_LIVE result=FAIL no XTEST to synthesize the chord with")
        exit(3)
    }
    guard let usage = micEntry.chord.key.hidUsage else {
        out("X11_HOTKEY_LIVE result=FAIL the chord's key has no HID usage")
        exit(3)
    }
    var modifiers: KeyModifiers = []
    if micEntry.chord.modifiers.contains(.control) || micEntry.chord.modifiers.contains(.primary) {
        modifiers.insert(.control)
    }
    if micEntry.chord.modifiers.contains(.option) { modifiers.insert(.alt) }
    if micEntry.chord.modifiers.contains(.shift) { modifiers.insert(.shift) }

    injector.activate(region: region)

    /// Press the chord and wait for the grab to see it.
    ///
    /// Polls rather than sleeping once, so a slow Xvfb is a slower pass and
    /// not a flake.
    func pressChordAndCountActivations() -> Int {
        injector.apply(.keyDown(key: usage, modifiers: modifiers))
        injector.apply(.keyUp(key: usage, modifiers: modifiers))
        injector.drainSyncForTesting()
        var seen = 0
        for _ in 0..<50 {
            seen += hotkey.drain()
            if seen > 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return seen
    }

    /// Toggle a lock key (HID usage) and let the server settle.
    func toggleLock(hidUsage: UInt16) {
        injector.apply(.keyDown(key: hidUsage, modifiers: []))
        injector.apply(.keyUp(key: hidUsage, modifiers: []))
        injector.drainSyncForTesting()
        Thread.sleep(forTimeInterval: 0.1)
        _ = hotkey.drain()
    }

    let plainActivations = pressChordAndCountActivations()
    guard plainActivations == 1 else {
        out("X11_HOTKEY_LIVE result=FAIL activations=\(plainActivations) want=1")
        exit(3)
    }

    // Phase 1b — the same chord with NUM LOCK ON.
    //
    // `XGrabKey` matches modifier state EXACTLY, so a grab installed only
    // under Ctrl|Alt stops matching the instant Mod2 joins the state. Nothing
    // errors; the key just quietly does nothing, which is the single most
    // likely way for this feature to look broken while every unit test passes.
    // `X11HotkeyMapping.grabMasks` enumerates the variants and THIS is what
    // proves they are installed.
    toggleLock(hidUsage: 0x53)  // Num Lock
    let lockedActivations = pressChordAndCountActivations()
    toggleLock(hidUsage: 0x53)  // and back off, so the server is left as found
    injector.deactivate()

    guard lockedActivations == 1 else {
        out(
            "X11_HOTKEY_LIVE result=FAIL activations=\(lockedActivations) want=1 "
                + "with Num Lock on — the lock-mask grab variants are missing")
        exit(3)
    }

    // Phase 2 — a chord somebody else owns must be REFUSED, not reported as
    // taken. `XGrabKey` reports that asynchronously, so a shim without the
    // error handler + XSync returns success here and the user gets a hotkey
    // that never fires with nothing anywhere saying why.
    guard let rival = X11Hotkey() else {
        out("X11_HOTKEY_LIVE result=FAIL could not open a second display connection")
        exit(3)
    }
    let conflict = rival.grab(micEntry.chord)
    guard conflict == .alreadyOwned else {
        out(
            "X11_HOTKEY_LIVE result=FAIL a second grab of an owned chord reported "
                + String(describing: conflict))
        exit(3)
    }

    hotkey.release()
    out("X11_HOTKEY_LIVE result=PASS activations=1 withNumLock=1 conflictDetected=yes")
    exit(0)
}

if let reason = X11HotkeySupport.decideFromEnvironment() {
    out("support: unavailable — \(reason.reason)")
} else {
    out("support: available")
}
if let hotkey = X11Hotkey() {
    out("display: opened")
    out("detectableAutoRepeat: \(hotkey.honoursDetectableAutoRepeat)")
    if let failure = hotkey.grab(micEntry.chord) {
        out("grab \(micEntry.chord.display(.words)): refused — \(failure.reason)")
    } else {
        out("grab \(micEntry.chord.display(.words)): held")
        hotkey.release()
    }
} else {
    out("display: unavailable")
}
if let request = X11HotkeyMapping.grab(for: micEntry.chord) {
    let masks = X11HotkeyMapping.grabMasks(base: request.modifierMask)
        .map { "0x" + String($0, radix: 16) }
    out("keysym: 0x" + String(request.keysym, radix: 16))
    out("masks: \(masks.joined(separator: " "))")
}
