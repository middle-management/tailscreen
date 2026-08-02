import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerLinux

// A headless Linux sharer: the portable `TailscaleScreenShareServer` driven by
// the X11 `CaptureEncoding` backend, with no UI.
//
// It exists to prove the extraction end to end — a real sharer, on Linux,
// serving real viewers over a real tailnet — and to be the thing an eventual
// tray/desktop UI drives. Notice how little there is here: bringing up the
// tsnet node, admitting viewers, RTP fan-out, NACK/FEC, congestion control and
// the idle sweep are all `TailscaleScreenShareServer`, unchanged from what
// macOS ships. This file only says *what* to capture and *where* to sign in.
//
// Usage:
//   tailscreen-sharer-linux --hostname NAME --state-dir DIR
//                           [--control-url URL] [--auth-key KEY]
//                           [--display :N] [--fps N] [--seconds N]
//                           [--allow-control]
//
// TAILSCREEN_TS_AUTHKEY / TAILSCREEN_TS_CONTROL_URL are honoured as defaults,
// matching the rest of the repo's e2e tooling.

struct Config: Sendable {
    var hostname = "tailscreen-sharer"
    var stateDir = FileManager.default.currentDirectoryPath + "/.sharer-state"
    var controlURL: String?
    var authKey: String?
    var display: String?
    var fps = 15
    /// Offer remote control to viewers.
    ///
    /// **Off by default, unlike the app.** This binary is what automation and
    /// the e2e harness drive, often unattended and often on a box whose
    /// display nobody is watching — inviting a peer to take the pointer is not
    /// something an unattended process should do because it *can*. The GTK app
    /// has a person in front of it and offers control whenever XTEST is
    /// present; here it takes a flag. (Same asymmetry, same reasoning, as the
    /// approval gate: the server default is right for automation and wrong for
    /// anything with a user.)
    var allowControl = false
    /// Run for this long then stop. 0 = until killed. A bounded default keeps
    /// an automated harness from leaking a sharer if the viewer never arrives.
    var seconds = 0

    static func parse() -> Config {
        var c = Config()
        let env = ProcessInfo.processInfo.environment
        c.authKey = env["TAILSCREEN_TS_AUTHKEY"]
        c.controlURL = env["TAILSCREEN_TS_CONTROL_URL"]
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--hostname": c.hostname = it.next() ?? c.hostname
            case "--state-dir": c.stateDir = it.next() ?? c.stateDir
            case "--control-url": c.controlURL = it.next()
            case "--auth-key": c.authKey = it.next()
            case "--display": c.display = it.next()
            case "--fps": c.fps = Int(it.next() ?? "") ?? c.fps
            case "--allow-control": c.allowControl = true
            case "--seconds": c.seconds = Int(it.next() ?? "") ?? c.seconds
            default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
            }
        }
        return c
    }
}

let config = Config.parse()

/// Unbuffered by construction: `print` buffers when stdout is a pipe or file,
/// which is exactly how a harness runs this, and `setvbuf(stdout, …)` isn't
/// reachable under Swift 6 strict concurrency (`stdout` is shared mutable
/// state). Writing the bytes straight to the file handle sidesteps both.
func log(_ s: String) {
    FileHandle.standardOutput.write(Data("[sharer] \(s)\n".utf8))
}

// The selection the capture backend resolves. On X11 this means "the root
// window of the display we were pointed at"; the display ID is carried for
// shape only, since an X display is named by `$DISPLAY`, not by a number.
let selection = PickerSelection(kind: .display, displayID: 0, windowID: nil, bundleIDs: [])
guard let selectionData = try? JSONEncoder().encode(selection) else {
    log("could not encode the picker selection")
    exit(2)
}

// Built before the server because whether it exists is what the server
// advertises. `isTrusted()` is the real question: XTEST is an OPTIONAL X11
// extension, and without it every injected click silently vanishes.
let injector: X11InputInjector? = {
    guard config.allowControl else { return nil }
    let candidate = X11InputInjector(display: config.display)
    guard candidate.isTrusted() else {
        log("--allow-control given but this X server has no XTEST extension; control stays off")
        return nil
    }
    return candidate
}()

let server = TailscaleScreenShareServer(
    captureFactory: { X11CaptureEncoder(display: config.display) },
    // Present only with `--allow-control`, and only when this X server
    // actually has XTEST. The server derives `ScreenShareCaps.remoteControl`
    // from this being non-nil, so in every other case viewers hide their
    // Request Control affordance rather than sending requests nothing can
    // serve.
    inputInjector: injector
)

server.onViewersChanged = { viewers in
    log("viewers: \(viewers.count) [\(viewers.map(\.tailscaleIP).joined(separator: ", "))]")
}
server.onCaptureStopped = { error in
    log("capture stopped: \(error.map { "\($0)" } ?? "clean")")
}

var quality = QualitySettings.default
quality.fpsCap = config.fps

do {
    try await server.start(
        hostname: config.hostname,
        authKey: config.authKey,
        path: config.stateDir,
        controlURL: config.controlURL ?? kDefaultControlURL,
        filterData: selectionData,
        quality: quality
    )
} catch {
    log("failed to start: \(error)")
    exit(1)
}

let ips = try? await server.getIPAddresses()
log("READY hostname=\(config.hostname) ip4=\(ips?.ip4 ?? "?") fps=\(config.fps)")

if config.seconds > 0 {
    try? await Task.sleep(for: .seconds(config.seconds))
    log("time limit reached; stopping")
    await server.stop()
} else {
    // Park forever; the harness kills us.
    while true {
        try? await Task.sleep(for: .seconds(3600))
    }
}
