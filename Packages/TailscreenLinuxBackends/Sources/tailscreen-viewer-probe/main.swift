import FFmpegKit
import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenViewer
import TailscreenViewerCore
import TailscreenViewerTsnet

// A headless viewer: dials a sharer over tsnet, decodes what arrives, and
// reports. No window, no GTK, no audio device — so it runs anywhere the GTK
// viewer can't, which is what makes it usable as an automated end-to-end probe
// against a real sharer.
//
// It is deliberately the *real* receive path: `TsnetTransport` +
// `ViewerSession` + the FFmpeg decoder the desktop viewer uses. Only the sink
// is different — instead of uploading to a GL texture it counts frames and
// checks they aren't blank.
//
// Usage:
//   tailscreen-viewer-probe --host SHARER --state-dir DIR
//                           [--control-url URL] [--auth-key KEY]
//                           [--frames N] [--timeout SECONDS]
//
// Exits 0 once `--frames` frames have decoded, printing a PROBE_OK line the
// harness greps for; exits 1 on timeout.

struct Config: Sendable {
    var host = "tailscreen-sharer"
    var hostname = "tailscreen-probe"
    var stateDir = FileManager.default.currentDirectoryPath + "/.probe-state"
    var controlURL: String?
    var authKey: String?
    var frames = 10
    var timeout = 60.0

    static func parse() -> Config {
        var c = Config()
        let env = ProcessInfo.processInfo.environment
        c.authKey = env["TAILSCREEN_TS_AUTHKEY"]
        c.controlURL = env["TAILSCREEN_TS_CONTROL_URL"]
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--host": c.host = it.next() ?? c.host
            case "--hostname": c.hostname = it.next() ?? c.hostname
            case "--state-dir": c.stateDir = it.next() ?? c.stateDir
            case "--control-url": c.controlURL = it.next()
            case "--auth-key": c.authKey = it.next()
            case "--frames": c.frames = Int(it.next() ?? "") ?? c.frames
            case "--timeout": c.timeout = Double(it.next() ?? "") ?? c.timeout
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
    FileHandle.standardOutput.write(Data("[probe] \(s)\n".utf8))
}

/// Counts decoded frames and samples their luma, so "we received video" means
/// real pixels rather than merely a frame-shaped object arriving.
final class CountingSink: VideoSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastSize = (0, 0)
    private var sawNonUniform = false

    var snapshot: (count: Int, size: (Int, Int), nonUniform: Bool) {
        lock.withLock { (count, lastSize, sawNonUniform) }
    }

    func present(_ frame: any DecodedFrame) {
        var uniform = true
        if let f = frame as? DecodedVideoFrame, let first = f.yPlane.first {
            // A blank capture (or a decoder handing back an empty buffer) is
            // still "a frame"; sampling the luma is what distinguishes real
            // screen content from a grey rectangle.
            uniform = !f.yPlane.contains { $0 != first }
        }
        lock.withLock {
            count += 1
            lastSize = (frame.width, frame.height)
            if !uniform { sawNonUniform = true }
            if count == 1 {
                log("first frame \(frame.width)x\(frame.height)")
            }
        }
    }
}

/// One-way "stop now" flag shared by the watchdog task and the run loop's
/// `shouldClose` poll.
final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

let sink = CountingSink()
let done = DoneFlag()

let viewerConfig = ViewerConfig(
    hostname: config.host,
    authKey: config.authKey,
    controlURL: config.controlURL ?? kDefaultControlURL,
    statePath: config.stateDir
)

// Watchdog: the run loop only ends when `shouldClose` says so, so a sharer that
// never sends video would otherwise hang forever.
let deadline = Date().addingTimeInterval(config.timeout)

Task {
    while !done.isSet {
        try? await Task.sleep(for: .milliseconds(200))
        let s = sink.snapshot
        if s.count >= config.frames {
            log("PROBE_OK frames=\(s.count) size=\(s.size.0)x\(s.size.1) nonUniform=\(s.nonUniform)")
            done.set()
        } else if Date() > deadline {
            log("PROBE_TIMEOUT frames=\(s.count) after \(Int(config.timeout))s")
            done.set()
        }
    }
}

let transport = TsnetTransport()
do {
    try await transport.run(
        config: viewerConfig,
        decoder: FFmpegVideoDecoder(),
        videoSink: sink,
        audioSink: nil,
        shouldClose: { done.isSet },
        onAdmitted: { caps in
            log("admitted by sharer (serverCaps=\(caps.rawValue))")
        },
        onAwaitingApproval: { log("awaiting sharer approval…") },
        onDeclined: { log("declined by sharer") }
    )
} catch {
    log("transport error: \(error)")
}
await transport.teardown()

let final = sink.snapshot
if final.count >= config.frames {
    log("done: \(final.count) frames decoded")
    exit(0)
}
log("done: only \(final.count) frames decoded (wanted \(config.frames))")
exit(1)
