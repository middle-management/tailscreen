import ALSAKit
import FFmpegKit
import Foundation
import SDLKit
import TailscaleKit
import TailscreenProtocol
import TailscreenViewer
import TailscreenViewerCore

// tailscreen-viewer — the portable screen-share viewer entry point. It wires
// the FFmpeg decoder, SDL renderer, and ALSA audio sink into the portable
// `ViewerSession` core and drives it from a tsnet UDP transport.
//
// Usage:
//   tailscreen-viewer <sharer-host> [--port N] [--no-audio]
//                     [--state-dir PATH] [--control-url URL]
//   Env: TAILSCREEN_TS_AUTHKEY, TAILSCREEN_TS_CONTROL_URL
//
// The decode → render → audio pipeline is covered by the package's integration
// test; the live tsnet leg here needs a real tailnet and is run locally.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    FileHandle.standardError.write(
        Data(
            "usage: tailscreen-viewer <sharer-host> [--port N] [--no-audio] [--state-dir PATH] [--control-url URL]\n"
                .utf8))
    exit(2)
}

func parseArguments() -> (config: ViewerConfig, wantAudio: Bool) {
    var args = Array(CommandLine.arguments.dropFirst())
    var host: String?
    var port: UInt16 = 7447
    var wantAudio = true
    var statePath = FileManager.default.currentDirectoryPath + "/.tailscreen-viewer-state"
    let env = ProcessInfo.processInfo.environment
    var controlURL = env["TAILSCREEN_TS_CONTROL_URL"] ?? kDefaultControlURL
    let authKey = env["TAILSCREEN_TS_AUTHKEY"]

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--port":
            guard let raw = args.first, let value = UInt16(raw) else { fail("--port needs a number") }
            port = value
            args.removeFirst()
        case "--no-audio":
            wantAudio = false
        case "--state-dir":
            guard let value = args.first else { fail("--state-dir needs a path") }
            statePath = value
            args.removeFirst()
        case "--control-url":
            guard let value = args.first else { fail("--control-url needs a URL") }
            controlURL = value
            args.removeFirst()
        case let other where other.hasPrefix("--"):
            fail("unknown option \(other)")
        default:
            guard host == nil else { fail("unexpected extra argument \(arg)") }
            host = arg
        }
    }

    guard let host else { fail("a sharer host is required") }
    let config = ViewerConfig(
        hostname: host, port: port, authKey: authKey,
        controlURL: controlURL, statePath: statePath)
    return (config, wantAudio)
}

let (config, wantAudio) = parseArguments()

// The renderer opens at a default size and resizes to the first decoded frame.
// Default to SDL's software renderer: the common path (X11 forwarded to XQuartz
// over OrbStack) has no usable GLX FBConfig, so the accelerated `opengl` driver
// dlopens libGL, creates a GLX context, and fatally X-errors the process before
// any window shows. Set TAILSCREEN_SDL_ACCELERATED=1 on a native Linux desktop
// with working GL to opt back into GPU-accelerated scaling.
let useAccelerated = ProcessInfo.processInfo.environment["TAILSCREEN_SDL_ACCELERATED"] == "1"
let window: SDL.VideoWindow
do {
    window = try SDL.VideoWindow(
        title: "Tailscreen — \(config.hostname)",
        width: 1280,
        height: 720,
        softwareRenderer: !useAccelerated
    )
} catch {
    fail("could not open a video window: \(error)")
}
let videoSink = SDLVideoSink(window: window)

var audioSink: AudioSink?
if wantAudio {
    do {
        audioSink = ALSAAudioSink(player: try ALSA.PCMPlayer())
    } catch {
        // Audio is best-effort — a missing/busy device shouldn't block viewing.
        FileHandle.standardError.write(Data("warning: audio disabled (\(error))\n".utf8))
    }
}

let decoder = FFmpegVideoDecoder()

// Offline render self-test: decode a local AVCC access-unit file and display it
// in a loop through the real SDL window — no network, no sharer, no approval.
// Isolates the decode+display path from transport, e.g. to verify an X server /
// XQuartz / Xvfb setup shows anything at all.
//   TAILSCREEN_PLAY_FILE=/path/to/keyframe.avcc   (HEVC; TAILSCREEN_PLAY_H264=1 for H.264)
if let playFile = ProcessInfo.processInfo.environment["TAILSCREEN_PLAY_FILE"] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: playFile)) else {
        fail("play-file: could not read \(playFile)")
    }
    let codec: VideoCodec = ProcessInfo.processInfo.environment["TAILSCREEN_PLAY_H264"] == "1" ? .h264 : .hevc
    let frames = (try? decoder.decode(accessUnit: data, codec: codec, isKeyframe: true)) ?? []
    guard let frame = frames.first else { fail("play-file: decoded 0 frames from \(playFile)") }
    FileHandle.standardError.write(
        Data("play-file: showing \(frame.width)×\(frame.height) — close the window to quit\n".utf8))
    while !videoSink.pollShouldClose() {
        videoSink.present(frame)
        try? await Task.sleep(nanoseconds: 33_000_000)
    }
    exit(0)
}

let transport = TsnetTransport()

// `main.swift` supports top-level `await`; the whole run stays on the main
// actor (see TsnetTransport) so the single-thread SDL/decoder contract holds.
do {
    try await transport.run(
        config: config,
        decoder: decoder,
        videoSink: videoSink,
        audioSink: audioSink,
        shouldClose: {
            // Called once per run-loop iteration: keep the window painted (an
            // X window blanks to white on expose if not redrawn) and report a
            // close request.
            videoSink.repaint()
            return videoSink.pollShouldClose()
        }
    )
} catch {
    fail("session failed: \(error)")
}
