import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenSharer
import TailscreenSharerLinux
import TailscreenTransport

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
//   tailscreen-sharer-linux --link [--link-relay-map-url URL] [--approve-guests]
//                           [--allow-control [--grant-control]]
//                           [--display :N] [--fps N] [--seconds N]
//
// TAILSCREEN_TS_AUTHKEY / TAILSCREEN_TS_CONTROL_URL are honoured as defaults,
// matching the rest of the repo's e2e tooling.
//
// `--link` is the share-by-token path with no tailnet at all: no tsnet node,
// no sign-in, no control plane. A guest node bootstraps off a relay, the
// share runs over that tunnel alone (`startGuestOnly`), and the minted token
// is printed as `E2E_MARKER shareLink token=…` for a harness to hand to a
// viewer — the browser spike (plans/browser-viewer.md, Phase 2) is the first.

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
    /// Share by link only (see the header): a guest node instead of tsnet.
    var link = false
    /// Where the guest node fetches its DERP map when linking. Nil = the
    /// guest package's default (Tailscale's relays); a harness points it at a
    /// local relay so the run needs no internet.
    var linkRelayMapURL: String?
    /// Approve every guest the moment it parks. Guest approval is mandatory
    /// and per-join by policy (nothing StableNodeID-shaped exists to remember),
    /// and an unattended harness has nobody to click Accept — so this is the
    /// automation escape hatch, the guest-side twin of TAILSCREEN_OPEN_DOOR.
    /// Never on by default.
    var approveGuests = false
    /// Grant every control request the moment it arrives (needs
    /// `--allow-control`, and XTEST). The same automation escape hatch as
    /// `--approve-guests`, for the browser e2e's remote-control leg: nobody is
    /// there to press Grant. Never on by default.
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

if config.approveGuests {
    // Hop off the callback before approving: it fires from inside the
    // server's own notification path, and `approveViewer` re-enters the
    // same state. Guests never auto-admit otherwise (mandatory per-join
    // approval), so without this every viewer would park forever.
    server.onPendingViewersChanged = { pending in
        for viewer in pending {
            log("auto-approving guest \(viewer.id)")
            Task { server.approveViewer(addr: viewer.id) }
        }
    }
}

if config.grantControl {
    // Same hop-off-the-callback shape as the approval above; `grantControl`
    // returns false (and logs why) when no injector is present.
    server.onControlRequestsChanged = { requests in
        for request in requests {
            log("auto-granting control to \(request.viewerIP)")
            Task { _ = server.grantControl(toConnectionID: request.id) }
        }
    }
}

/// The link's guest node, held for the life of the process. It must be
/// retained somewhere: the server adopts only the node's *listeners*, and the
/// node itself closes on deinit — releasing it after minting the token tears
/// down the relay connection ("closing connection to derp-1, age 0s") and
/// every guest's handshake then goes unanswered. `SharerLinkSession` keeps it
/// in a property for the same reason.
var linkNode: GuestServerNode?

if config.link {
    // Link-only share: guest node up, both listeners through the tunnel,
    // then the server with those as its ONLY sockets. The same shape as
    // `SharerLinkSession.enable`, minus a running tailnet share to attach to.
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
        // The one line a harness parses; same marker the macOS app prints
        // under TAILSCREEN_AUTOSHARE_LINK.
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
