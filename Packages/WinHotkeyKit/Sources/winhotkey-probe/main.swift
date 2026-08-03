import Foundation
import TailscreenProtocol
import WinHotkeyKit

// winhotkey-probe — the link check, and the manual gate this repository cannot
// automate.
//
//   winhotkey-probe          report whether the chord could be registered, then
//                            release it. This is the CI shape: it proves the
//                            binary LINKS and that `RegisterHotKey` answered.
//   winhotkey-probe --hold   hold the chord and print every press until Ctrl+C.
//                            The only way to confirm the hotkey fires while
//                            ANOTHER application is focused, which is the whole
//                            point of it and needs a person at a desk.
//
// Off Windows both paths report `unsupportedPlatform` and exit 0: this file
// exists there to be typechecked, not to pass judgment on a platform it is not
// running on.

let args = Array(CommandLine.arguments.dropFirst())

func out(_ line: String) { FileHandle.standardOutput.write(Data("\(line)\n".utf8)) }

guard let entry = ShortcutCatalog.entry(for: .toggleMicrophone) else {
    out("WINHOTKEY result=FAIL the catalog has no toggleMicrophone entry")
    exit(3)
}

guard WindowsHotkey.isSupported else {
    out("WINHOTKEY result=SKIP no RegisterHotKey on this platform")
    exit(0)
}

if let registration = WindowsHotkeyMapping.registration(for: entry.chord) {
    out(
        "chord: \(entry.chord.display(.words)) "
            + "vk=0x\(String(registration.virtualKey, radix: 16)) "
            + "fsModifiers=0x\(String(registration.modifiers, radix: 16))")
}

switch WindowsHotkey.hold(entry.chord) {
case .failure(let reason):
    out("WINHOTKEY result=FAIL \(reason.reason)")
    exit(3)
case .success(let hotkey):
    out("WINHOTKEY result=PASS registered")
    guard args.contains("--hold") else {
        hotkey.release()
        exit(0)
    }
    out("holding \(entry.chord.display(.words)) — press it from any app; Ctrl+C to stop")
    while true {
        let count = hotkey.drain()
        if count > 0 { out("activations: \(count)") }
        Thread.sleep(forTimeInterval: 0.05)
    }
}
