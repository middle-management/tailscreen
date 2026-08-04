import Foundation
import TailscreenProtocol
import WinNotifyKit

// winnotify-probe — the link check, and the manual gate this repository cannot
// automate.
//
//   winnotify-probe          register, report what the desktop can do, release.
//                            The CI shape: it proves the binary LINKS and that
//                            the notification platform answered. A machine
//                            without a reachable Windows App Runtime reports
//                            "no platform" and exits 0 — that is a NORMAL
//                            answer, and making it a failure would turn the
//                            zip build's honest degradation into a red gate.
//   winnotify-probe --post   post a toast with two buttons and leave it up.
//                            The only way to see what any of this LOOKS like,
//                            and the only way to confirm a real button press
//                            reaches the app — both need a person at a desk.
//   winnotify-probe --withdraw
//                            post, wait two seconds, withdraw. Confirms a
//                            notice disappears when the thing it is about ends,
//                            which is the half that is wrong-by-omission rather
//                            than visibly broken.
//
// Off Windows every path reports SKIP and exits 0: this file exists there to be
// typechecked, not to pass judgment on a platform it is not running on.

let args = Array(CommandLine.arguments.dropFirst())

func out(_ line: String) { FileHandle.standardOutput.write(Data("\(line)\n".utf8)) }

guard WindowsNotifier.isSupported else {
    out("WINNOTIFY result=SKIP no notification platform on this build")
    exit(0)
}

guard let notifier = WindowsNotifier(displayName: "Tailscreen") else {
    // Not a failure. `AppNotificationManager` needs a Windows App Runtime the
    // process can reach, and an unpackaged run without one legitimately lands
    // here — which is the whole point of the runtime probe.
    out("WINNOTIFY result=SKIP not registered: \(WindowsNotifier.openError ?? "unknown")")
    exit(0)
}

out("WINNOTIFY result=PASS registered")
out("setting: \(notifier.setting)  canBeSeen=\(notifier.canBeSeen)")
out("urgent scenario supported: \(notifier.supportsUrgentScenario)")

guard args.contains("--post") || args.contains("--withdraw") else { exit(0) }

if !notifier.canBeSeen {
    // Said rather than assumed: posting still SUCCEEDS with notifications off,
    // so a probe that skipped this line would print PASS over a toast nobody
    // could have seen.
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
