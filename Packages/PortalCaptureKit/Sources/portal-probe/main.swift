import CPortalFakeBus
import Foundation
import PortalCaptureKit

// portal-probe — the checks a library target cannot perform, in the shape
// xtest-probe and wasapi-probe already established here.
//
//   portal-probe --link-check     prove the two system libraries actually
//                                 link and that a call into each returns.
//                                 Needs nothing: no bus, no display, no
//                                 daemon. This is the CI gate.
//   portal-probe --handshake-test drive the real client-side handshake
//                                 against a FAKE portal on whatever session
//                                 bus this process can see. Proves the D-Bus
//                                 half; proves nothing about a real portal.
//                                 Run it under `dbus-run-session`.
//   portal-probe --capabilities   ask the REAL portal on this session bus what
//                                 it offers. Raises no dialog.
//   portal-probe --capture        the real thing: raise the consent dialog,
//                                 open a PipeWire stream, report frames.
//                                 Needs a desktop session and a human.
//
// The link check is the reason this is an executable at all: a SwiftPM library
// target is compiled but never linked, so a missing -lpipewire-0.3 stays
// invisible until something downstream links it. That is how WASAPIKit's
// missing GUIDs passed their own CI step and failed eleven minutes later in
// the app.

let arguments = Array(CommandLine.arguments.dropFirst())

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

// MARK: - --link-check

if arguments.contains("--link-check") {
    // Calls into BOTH system libraries. libpipewire via its version string;
    // libdbus via the request-path derivation, which lives in the same C
    // target as the libdbus calls, so a missing -ldbus-1 fails the link of
    // this binary regardless of which symbol is touched.
    let version = PortalCapture.pipewireVersion
    guard !version.isEmpty else {
        emit("PORTAL_LINK result=FAIL libpipewire reported no version")
        exit(3)
    }
    guard
        let path = PortalSession.requestPath(uniqueName: ":1.42", token: "probe"),
        path == "/org/freedesktop/portal/desktop/request/1_42/probe"
    else {
        emit("PORTAL_LINK result=FAIL request-path derivation is wrong")
        exit(3)
    }
    emit("PORTAL_LINK result=PASS pipewire=\(version)")
    exit(0)
}

// MARK: - --handshake-test

if arguments.contains("--handshake-test") {
    // What this proves, stated so nobody reads more into a green run than is
    // there: the CLIENT half of the D-Bus protocol. Options dicts a server can
    // read, the Request path derived and subscribed to BEFORE the call (the
    // fake answers with no pause, so a late subscription misses it and this
    // times out), the streams array parsed, a restore token picked up, and a
    // file descriptor surviving OpenPipeWireRemote.
    //
    // What it proves about a real portal: nothing. No consent dialog, no
    // compositor, no PipeWire, not one pixel.
    guard ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil else {
        emit("PORTAL_HANDSHAKE result=SKIP no DBUS_SESSION_BUS_ADDRESS (run under dbus-run-session)")
        exit(0)
    }

    var config = ts_fakeportal_config_t()
    config.node_id = 4242
    config.width = 1920
    config.height = 1080
    config.source_type = 1  // MONITOR
    config.start_answer = Int32(TS_FAKEPORTAL_ANSWER_OK)
    config.offer_restore_token = 1

    guard let fake = ts_fakeportal_start(&config) else {
        emit("PORTAL_HANDSHAKE result=FAIL could not allocate the fake portal")
        exit(3)
    }
    defer { ts_fakeportal_stop(fake) }
    let fakeError = String(cString: ts_fakeportal_last_error(fake))
    guard fakeError == "no error" else {
        emit("PORTAL_HANDSHAKE result=FAIL fake portal did not start: \(fakeError)")
        exit(3)
    }

    do {
        let session = try PortalSession()
        try session.connect()
        let streams = try session.negotiate(
            sources: [.monitor, .window], cursor: .embedded, persist: .untilRevoked,
            timeout: .seconds(10))
        guard let stream = streams.first else {
            emit("PORTAL_HANDSHAKE result=FAIL negotiate returned no streams")
            exit(3)
        }
        guard stream.nodeID == 4242, stream.width == 1920, stream.height == 1080 else {
            emit(
                "PORTAL_HANDSHAKE result=FAIL stream mismatch node=\(stream.nodeID) "
                    + "size=\(stream.width ?? -1)x\(stream.height ?? -1)")
            exit(3)
        }
        guard session.restoreToken == "fake-restore-token" else {
            emit("PORTAL_HANDSHAKE result=FAIL restore token was \(session.restoreToken ?? "nil")")
            exit(3)
        }
        // The fd round trip. A descriptor that arrives unusable is a classic
        // way to get D-Bus fd passing subtly wrong, and it would surface as
        // "PipeWire won't connect" much later.
        let fd = try session.openPipeWireFileDescriptor()
        var info = stat()
        let usable = fstat(fd, &info) == 0
        close(fd)
        guard usable else {
            emit("PORTAL_HANDSHAKE result=FAIL the received descriptor was not usable")
            exit(3)
        }
        // Four calls: CreateSession, SelectSources, Start, OpenPipeWireRemote.
        // Asserted so a client that skipped a step cannot pass.
        let calls = ts_fakeportal_call_count(fake)
        guard calls == 4 else {
            emit("PORTAL_HANDSHAKE result=FAIL the fake served \(calls) calls, expected 4")
            exit(3)
        }
        session.close()
        emit("PORTAL_HANDSHAKE result=PASS node=\(stream.nodeID) size=1920x1080 calls=4")
        exit(0)
    } catch {
        emit("PORTAL_HANDSHAKE result=FAIL \(error)")
        exit(3)
    }
}

// MARK: - --handshake-cancel

if arguments.contains("--handshake-cancel") {
    // The other half of the handshake gate, and the more important one: a user
    // who declines must produce `.cancelled`, not an error. A sharer UI that
    // shows a failure dialog because somebody said no to sharing their screen
    // is worse than one that shows nothing.
    guard ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil else {
        emit("PORTAL_CANCEL result=SKIP no DBUS_SESSION_BUS_ADDRESS (run under dbus-run-session)")
        exit(0)
    }
    var config = ts_fakeportal_config_t()
    config.node_id = 1
    config.start_answer = Int32(TS_FAKEPORTAL_ANSWER_CANCEL)
    guard let fake = ts_fakeportal_start(&config) else {
        emit("PORTAL_CANCEL result=FAIL could not allocate the fake portal")
        exit(3)
    }
    defer { ts_fakeportal_stop(fake) }
    let fakeError = String(cString: ts_fakeportal_last_error(fake))
    guard fakeError == "no error" else {
        emit("PORTAL_CANCEL result=FAIL fake portal did not start: \(fakeError)")
        exit(3)
    }
    do {
        let session = try PortalSession()
        _ = try session.negotiate(timeout: .seconds(10))
        emit("PORTAL_CANCEL result=FAIL a declined request succeeded")
        exit(3)
    } catch PortalSession.Failure.cancelled {
        emit("PORTAL_CANCEL result=PASS a declined request reported .cancelled")
        exit(0)
    } catch {
        emit("PORTAL_CANCEL result=FAIL declined request reported \(error), expected .cancelled")
        exit(3)
    }
}

// MARK: - --capabilities

if arguments.contains("--capabilities") {
    do {
        let session = try PortalSession()
        try session.connect()
        let sources = session.availableSourceTypes
        var names: [String] = []
        if sources.contains(.monitor) { names.append("monitor") }
        if sources.contains(.window) { names.append("window") }
        if sources.contains(.virtual) { names.append("virtual") }
        emit("portal source types: \(names.isEmpty ? ["(not reported)"] : names)")
        emit("portal cursor modes: \(session.availableCursorModes)")
        emit("pipewire: \(PortalCapture.pipewireVersion)")
        exit(0)
    } catch {
        emit("portal unavailable: \(error)")
        exit(3)
    }
}

// MARK: - --capture

if arguments.contains("--capture") {
    // The real path, and the one no CI anywhere can run: it puts a consent
    // dialog on a screen and waits for a person.
    do {
        let session = try PortalSession()
        try session.connect()
        emit("raising the portal's consent dialog…")
        let streams = try session.negotiate(timeout: .seconds(120))
        for stream in streams {
            emit(
                "stream node=\(stream.nodeID) "
                    + "size=\(stream.width.map(String.init) ?? "?")x\(stream.height.map(String.init) ?? "?")")
        }
        guard let first = streams.first else {
            emit("PORTAL_CAPTURE result=FAIL no streams")
            exit(3)
        }
        let fd = try session.openPipeWireFileDescriptor()
        let counter = FrameCounter()
        let stream = try PortalStream(
            fileDescriptor: fd, nodeID: first.nodeID,
            onFrame: { counter.record(stride: $0.stride, width: $0.width, height: $0.height) },
            onState: { emit("stream state: \($0)") })
        Thread.sleep(forTimeInterval: 3)
        let seen = counter.snapshot()
        emit(
            "PORTAL_CAPTURE result=\(seen.frames > 0 ? "PASS" : "FAIL") frames=\(seen.frames) "
                + "geometry=\(seen.width)x\(seen.height) stride=\(seen.stride) "
                + "negotiated=\(stream.size.map { "\($0.width)x\($0.height)" } ?? "none")")
        session.close()
        exit(seen.frames > 0 ? 0 : 3)
    } catch {
        emit("PORTAL_CAPTURE result=FAIL \(error)")
        exit(3)
    }
}

emit(
    """
    portal-probe — xdg-desktop-portal ScreenCast + PipeWire

      --link-check       both system libraries link and answer. Needs nothing.
      --handshake-test   the client handshake against a FAKE portal. Needs a
                         session bus (use dbus-run-session); proves the D-Bus
                         half only — no consent dialog, no PipeWire, no pixels.
      --handshake-cancel the same, asserting a declined request reads as
                         declined rather than as an error.
      --capabilities     ask the REAL portal what it offers. No dialog.
      --capture          the real thing. Raises a consent dialog and needs a
                         person to answer it.

    pipewire: \(PortalCapture.pipewireVersion)
    """)

/// Frames land on PipeWire's thread; the probe reads from its own.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: UInt64 = 0
    private var width = 0
    private var height = 0
    private var stride = 0

    func record(stride: Int, width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        self.stride = stride
        self.width = width
        self.height = height
    }

    func snapshot() -> (frames: UInt64, width: Int, height: Int, stride: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, width, height, stride)
    }
}
