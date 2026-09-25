import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerLinux
import TailscreenTransport

// A headless Linux sharer: the portable `TailscaleScreenShareServer` driven
// by the X11 `CaptureEncoding` backend, with no UI. Node bring-up, admission,
// RTP fan-out, NACK/FEC and congestion control are all
// `TailscaleScreenShareServer`, unchanged from macOS; this file only says
// what to capture and where to sign in.
//
// Usage:
//   tailscreen-sharer-linux --hostname NAME --state-dir DIR
//                           [--control-url URL] [--auth-key KEY]
//                           [--display :N] [--fps N] [--seconds N]
//                           [--allow-control]
//   tailscreen-sharer-linux --link [--link-relay-map-url URL] [--approve-guests]
//                           [--allow-control [--grant-control]]
//                           [--display :N] [--fps N] [--seconds N]
//
// TAILSCREEN_TS_AUTHKEY / TAILSCREEN_TS_CONTROL_URL are honoured as defaults,
// matching the rest of the repo's e2e tooling.
//
// `--link` is the share-by-token path with no tailnet at all: a guest node
// bootstraps off a relay, the share runs over that tunnel alone
// (`startGuestOnly`), and the minted token is printed as
// `E2E_MARKER shareLink token=…` for a harness.

struct Config: Sendable {
    var hostname = "tailscreen-sharer"
    var stateDir = FileManager.default.currentDirectoryPath + "/.sharer-state"
    var controlURL: String?
    var authKey: String?
    var display: String?
    var fps = 15
    /// Offer remote control to viewers. Off by default, unlike the GTK
    /// app — this binary is what unattended automation drives, and inviting
    /// a peer to take the pointer is not something unattended should do
    /// because it can.
    var allowControl = false
    /// Run for this long then stop. 0 = until killed. Keeps an automated
    /// harness from leaking a sharer if the viewer never arrives.
    var seconds = 0
    /// Share by link only (see the header): a guest node instead of tsnet.
    var link = false
    /// Where the guest node fetches its DERP map. Nil = Tailscale's relays; a
    /// harness points it at a local relay so the run needs no internet.
    var linkRelayMapURL: String?
    /// Approve every guest the moment it parks — the automation escape hatch
    /// for mandatory per-join guest approval (guest-side twin of
    /// TAILSCREEN_OPEN_DOOR). Never on by default.
    var approveGuests = false
    /// Grant every control request the moment it arrives (needs
    /// `--allow-control` + XTEST) — for the browser e2e's remote-control leg.
    /// Never on by default.
    var grantControl = false

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
            case "--link": c.link = true
            case "--link-relay-map-url": c.linkRelayMapURL = it.next()
            case "--approve-guests": c.approveGuests = true
            case "--grant-control": c.grantControl = true
            default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
            }
        }
        return c
    }
}

let config = Config.parse()

/// Unbuffered by construction: `print` buffers when stdout is a pipe/file
/// (how a harness runs this), and `setvbuf` isn't reachable under Swift 6
/// strict concurrency. Writing bytes straight to the handle sidesteps both.
func log(_ s: String) {
    FileHandle.standardOutput.write(Data("[sharer] \(s)\n".utf8))
}

// On X11 this means the root window of `$DISPLAY`; displayID is carried for shape only.
let selection = PickerSelection(kind: .display, displayID: 0, windowID: nil, bundleIDs: [])
guard let selectionData = try? JSONEncoder().encode(selection) else {
    log("could not encode the picker selection")
    exit(2)
}

// Built before the server: whether it exists is what the server advertises.
// XTEST is optional — without it every injected click silently vanishes.
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
    // Server derives `ScreenShareCaps.remoteControl` from this being non-nil.
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

if config.approveGuests {
    // Hop off the callback before approving: it fires from inside the
    // server's own notification path, and `approveViewer` re-enters the same state.
    server.onPendingViewersChanged = { pending in
        for viewer in pending {
            log("auto-approving guest \(viewer.id)")
            Task { server.approveViewer(addr: viewer.id) }
        }
    }
}

if config.grantControl {
    // Same hop-off-the-callback shape as above.
    server.onControlRequestsChanged = { requests in
        for request in requests {
            log("auto-granting control to \(request.viewerIP)")
            Task { _ = server.grantControl(toConnectionID: request.id) }
        }
    }
}

/// The link's guest node, held for the life of the process — the server
/// adopts only its listeners, and the node itself closes on deinit, tearing
/// down the relay connection.
var linkNode: GuestServerNode?

if config.link {
    // Guest node up, both listeners through the tunnel, then the server with
    // those as its ONLY sockets — same shape as `SharerLinkSession.enable`.
    let port = NetworkConfig.tailscreenPort
    do {
        let guestNode = try GuestServerNode(derpMapURL: config.linkRelayMapURL)
        linkNode = guestNode
        try await guestNode.start()
        let packets = try await guestNode.listenPacket(port: port)
        let control = TailscreenControlListener(port: port)
        control.start(adopting: try await guestNode.listen(port: port))
        try await server.startGuestOnly(
            filterData: selectionData,
            quality: quality,
            guestPacketListener: packets,
            guestControlListener: control
        )
        let token = try await guestNode.token()
        log("READY link-only fps=\(config.fps)")
        // The one line a harness parses; same marker macOS prints under TAILSCREEN_AUTOSHARE_LINK.
        log("E2E_MARKER shareLink token=\(token)")
    } catch {
        log("failed to start link-only: \(error)")
        exit(1)
    }
} else {
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
}

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
