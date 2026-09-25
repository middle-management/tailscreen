import Foundation
import TailscreenProtocol
import WinNotifyKit

// winnotify-probe — the link check, and the manual gate this repository
// cannot automate.
//
//   winnotify-probe          register, report what the desktop can do,
//                            release (the CI shape). No reachable Windows App
//                            Runtime reports "no platform" and exits 0 — a
//                            normal answer, not a failure.
//   winnotify-probe --post   post a toast with two buttons and leave it up —
//                            confirms a real button press reaches the app.
//   winnotify-probe --withdraw
//                            post, wait two seconds, withdraw — confirms a
//                            notice disappears when its subject ends.
//
// Off Windows every path reports SKIP and exits 0.

let args = Array(CommandLine.arguments.dropFirst())

func out(_ line: String) { FileHandle.standardOutput.write(Data("\(line)\n".utf8)) }

guard WindowsNotifier.isSupported else {
    out("WINNOTIFY result=SKIP no notification platform on this build")
    exit(0)
}

guard let notifier = WindowsNotifier(displayName: "Tailscreen") else {
    // Not a failure — an unpackaged run without a reachable runtime
    // legitimately lands here.
    out("WINNOTIFY result=SKIP not registered: \(WindowsNotifier.openError ?? "unknown")")
    exit(0)
}

out("WINNOTIFY result=PASS registered")
out("setting: \(notifier.setting)  canBeSeen=\(notifier.canBeSeen)")
out("urgent scenario supported: \(notifier.supportsUrgentScenario)")

guard args.contains("--post") || args.contains("--withdraw") else { exit(0) }

if !notifier.canBeSeen {
    // Posting still SUCCEEDS with notifications off, so say so explicitly.
    out("note: notifications are \(notifier.setting) — the post below will go nowhere")
}

let identity = "probe:\(WindowsToastPayload.openActionKey)-demo"
guard
    let tag = notifier.post(
        summary: "Someone wants to watch",
        body: "probe-peer is waiting to be let in.",
        buttons: [
            .init(key: "approve", label: "Accept"),
            .init(key: "deny", label: "Deny")
        ],
        identity: identity,
        blocksSomeone: true)
else {
    out("WINNOTIFY post=FAIL \(notifier.lastError ?? "unknown")")
    exit(3)
}
out("WINNOTIFY post=PASS tag=\(tag)")

if args.contains("--withdraw") {
    Thread.sleep(forTimeInterval: 2)
    notifier.withdraw(tag)
    out("WINNOTIFY withdraw=SENT tag=\(tag)")
} else {
    out("press a button — the app is activated with:")
    out("  \(WindowsToastPayload.arguments(action: "approve", identity: identity))")
}
