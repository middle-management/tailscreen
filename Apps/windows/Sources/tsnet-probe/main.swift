import Foundation

import class TailscreenViewerTsnet.TsnetTransport
import struct TailscreenViewerTsnet.ViewerConfig

// A console program that does nothing but bring up a tsnet node, printing
// before each step.
//
// It exists to answer one question the GUI app cannot: when node bring-up
// hangs, is the Go c-archive itself the problem, or the environment the app
// runs it in? The app carries WinUI, the Windows App SDK, a COM apartment on
// its main thread and swift-cross-ui's run loop. This carries none of them —
// same libtailscale.a, same Swift runtime, same machine, no UI.
//
//   * If this hangs too, the problem is in the Go archive on Windows and the
//     app is an innocent bystander.
//   * If this completes, the problem is something the app's environment does to
//     it, and the search narrows to COM and threading rather than to tsnet.
//
// The same shape as `wasapi-probe`: a small executable whose value is in what
// it EXCLUDES. Run it from a console; `GODEBUG=inittrace=1` in the environment
// additionally prints Go package-init timings, which names the package if the
// stall is in runtime init.
//
// No `@main`: Swift rejects that attribute in a file called main.swift, which
// is itself top-level code. Top-level `await` is what makes this work.

// The lines that matter for a hang are the `[tsnet] prepare: …` ones, and
// those go through `FileHandle.standardError.write`, which is unbuffered — so
// the last step reached is always on screen even if this program's own
// `print`s are still sitting in a buffer.
print("tsnet-probe: starting")

let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSHomeDirectory()
let statePath = URL(fileURLWithPath: base)
    .appendingPathComponent("Tailscreen")
    .appendingPathComponent("tsnet-probe")
    .path
print("tsnet-probe: state dir \(statePath)")

// An auth key short-circuits the interactive login, so TAILSCREEN_TS_AUTHKEY
// turns this into an unattended check. Without one it waits for a browser
// login exactly as the app does — which is fine, because the part under
// investigation is over long before then.
let authKey = ProcessInfo.processInfo.environment["TAILSCREEN_TS_AUTHKEY"]
let controlURL = ProcessInfo.processInfo.environment["TAILSCREEN_TS_CONTROL_URL"]

let transport = TsnetTransport()
var config = ViewerConfig(hostname: "", statePath: statePath)
config.authKey = authKey
if let controlURL { config.controlURL = controlURL }

print("tsnet-probe: calling prepare() — every step logs to stderr as [tsnet]")
do {
    try await transport.prepare(config: config)
    print("tsnet-probe: prepare() returned — node is up")
} catch {
    print("tsnet-probe: prepare() failed: \(error)")
}
await transport.teardown()
print("tsnet-probe: done")
