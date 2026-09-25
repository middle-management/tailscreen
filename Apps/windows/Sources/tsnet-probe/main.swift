import Foundation

import class TailscreenViewerTsnet.TsnetTransport
import struct TailscreenViewerTsnet.ViewerConfig

// A console program that does nothing but bring up a tsnet node, printing
// before each step.
//
// Answers one question the GUI app cannot: when bring-up hangs, is it the Go
// c-archive, or the app's environment (WinUI, COM apartment, run loop)? This
// carries none of that — same libtailscale.a, same Swift runtime, no UI.
//   * If this hangs too, the problem is in the Go archive.
//   * If this completes, the search narrows to COM/threading, not tsnet.
//
// `GODEBUG=inittrace=1` additionally prints Go package-init timings.
//
// No `@main`: Swift rejects that attribute in a file called main.swift.

// `[tsnet] prepare: …` lines go through unbuffered stderr, so the last step
// reached is always on screen even if this program's own prints are buffered.
print("tsnet-probe: starting")

let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSHomeDirectory()
let statePath = URL(fileURLWithPath: base)
    .appendingPathComponent("Tailscreen")
    .appendingPathComponent("tsnet-probe")
    .path
print("tsnet-probe: state dir \(statePath)")

// An auth key short-circuits the interactive login. Without one it waits for
// a browser login as the app does — fine, since the part under investigation
// is over long before then.
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
