import CGNotifySys
import Foundation
import GNotifyKit

// gnotify-probe — the link check and the live gate for GNotifyKit.
//
// Two jobs, and the first is the boring one that matters: a SwiftPM library
// target is COMPILED but never LINKED, so a missing `-lgio-2.0` stays invisible
// until something downstream links it. Running this binary at all proves the
// link.
//
// The second is the one no unit test can do. `Notify` takes `(susssasa{sv}i)` —
// eight fields, two of them containers — and a mistake in that signature is a
// D-Bus error at call time that nothing else in this repo would ever produce.
// Neither is the *signal* path testable in isolation: GDBus delivers to the
// thread-default main context captured at subscribe time, so a handle opened on
// a thread that never iterates one posts perfectly and reports nothing. That
// failure is invisible to every check except pressing a real button.

/// Pump the default main context until `condition` holds or the deadline
/// passes.
///
/// This is the whole point of the live check: `DesktopNotifier` subscribes on
/// the thread-default context, and here that is the same context this loop
/// iterates. A probe that slept instead would pass against a notifier whose
/// signals reach nobody.
@discardableResult
func pump(untilSeconds seconds: Double, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        // Non-blocking, so the deadline is honoured even when the bus is quiet.
        g_main_context_iteration(nil, 0)
        usleep(10_000)
    }
    return condition()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gnotify-probe: FAIL — \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
let wantsLive = arguments.contains("--live-check")
/// A command to run after posting the actionable notice, to press its button —
/// `dunstctl action` under dunst. Kept out of the probe so this stays
/// daemon-agnostic: the CI script names the daemon, not this file.
let invokeWith: [String] = {
    guard let index = arguments.firstIndex(of: "--invoke-with"), index + 1 < arguments.count
    else { return [] }
    return arguments[index + 1].split(separator: " ").map(String.init)
}()

guard let notifier = DesktopNotifier(appName: "Tailscreen probe", desktopEntry: "tailscreen")
else {
    let reason = DesktopNotifier.openError ?? "unknown"
    if wantsLive { fail("no notification daemon: \(reason)") }
    // Without --live-check this is the ordinary answer on a headless box, and
    // the binary having run at all is the link check.
    print("gnotify-probe: no notification daemon (\(reason)) — link check passed")
    exit(0)
}

print(
    "gnotify-probe: connected; actions=\(notifier.supportsActions) body=\(notifier.supportsBody)")
guard wantsLive else { exit(0) }

// A daemon that renders neither is one this feature cannot use, and CI runs a
// daemon chosen for advertising both. On a user's machine `supportsActions`
// being false is a legitimate state the host degrades into; here it means the
// capability read is broken.
guard notifier.supportsActions else { fail("daemon did not advertise the 'actions' capability") }
guard notifier.supportsBody else { fail("daemon did not advertise the 'body' capability") }

// MARK: 1 — post, and replace in place

guard
    let first = notifier.post(
        summary: "Someone wants to watch",
        body: "probe-host is waiting to be let in",
        urgency: .critical,
        expiresAutomatically: false)
else { fail("Notify returned no id: \(notifier.lastError ?? "unknown")") }
print("gnotify-probe: posted id=\(first)")

guard
    let replaced = notifier.post(
        summary: "Someone wants to watch",
        body: "probe-host is still waiting",
        urgency: .critical,
        replacing: first,
        expiresAutomatically: false)
else { fail("replacing Notify returned no id: \(notifier.lastError ?? "unknown")") }
// The spec says a replace returns the id it replaced. A daemon that minted a
// new one would mean every re-post stacks a second banner instead of updating
// the one already there.
guard replaced == first else { fail("replace minted a new id \(replaced), expected \(first)") }

// MARK: 2 — withdraw, and hear the signal

var closed: (id: UInt32, reason: DesktopNotifier.CloseReason)?
notifier.onClose = { id, reason in closed = (id, reason) }
notifier.withdraw(first)

guard pump(untilSeconds: 5, until: { closed != nil }) else {
    fail("no NotificationClosed signal after withdraw — is the main context being iterated?")
}
guard closed?.id == first else { fail("NotificationClosed carried id \(closed?.id ?? 0)") }
guard closed?.reason == .withdrawn else {
    fail("NotificationClosed reason was \(closed!.reason), expected .withdrawn")
}
print("gnotify-probe: withdraw round trip OK")

// MARK: 3 — a real button press

guard !invokeWith.isEmpty else {
    print("gnotify-probe: no --invoke-with, skipping the ActionInvoked leg")
    exit(0)
}

var invoked: (id: UInt32, key: String)?
notifier.onAction = { id, key in invoked = (id, key) }

guard
    let actionable = notifier.post(
        summary: "Someone wants to control this machine",
        body: "probe-host is asking to drive",
        actions: [
            // "default" first: most daemons treat that key as the one a plain
            // activation invokes, which is what `dunstctl action` presses.
            DesktopNotifier.Action(key: "default", label: "Accept"),
            DesktopNotifier.Action(key: "deny", label: "Deny")
        ],
        urgency: .critical,
        expiresAutomatically: false)
else { fail("actionable Notify returned no id: \(notifier.lastError ?? "unknown")") }

let press = Process()
press.executableURL = URL(fileURLWithPath: "/usr/bin/env")
press.arguments = invokeWith
do {
    try press.run()
    press.waitUntilExit()
} catch {
    fail("could not run \(invokeWith.joined(separator: " ")): \(error)")
}

guard pump(untilSeconds: 5, until: { invoked != nil }) else {
    fail("no ActionInvoked signal after \(invokeWith.joined(separator: " "))")
}
guard invoked?.id == actionable else {
    fail("ActionInvoked carried id \(invoked?.id ?? 0), expected \(actionable)")
}
guard invoked?.key == "default" else {
    fail("ActionInvoked carried key '\(invoked?.key ?? "")', expected 'default'")
}
print("gnotify-probe: action round trip OK (id=\(actionable) key=\(invoked!.key))")
print("gnotify-probe: PASS")
