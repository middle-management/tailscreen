import CPipeWireFakeSource
import Foundation
import PortalCaptureKit

// The PipeWire half's gates — the two checks that need a running `pipewire`
// daemon but no compositor, no consent dialog and no person.
//
// Everything else in this package's CI leg is a compile, link or D-Bus check.
// These two are the first things here that put real pixels through
// `portal_stream.c`. What they cover, and the three things they still do not,
// is in Sources/CPipeWireFakeSource/include/pipewirefakesource.h — read that
// before quoting a green run at anybody.
//
// Neither check SKIPS. A missing daemon is a FAIL, on purpose: the handshake
// checks' `exit 0` when there is no session bus is the shape that lets a gate
// pass by not running, and this leg starts its own daemon precisely so it never
// has that excuse.

private let checkWidth = 320
private let checkHeight = 180
// Non-zero, because a producer that pads its rows is the ordinary case and a
// consumer that reads at width*4 does not fail — it smears the picture.
private let checkPadding = 64

func emitLine(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

/// Frames arrive on PipeWire's thread; the probe reads from its own.
final class FrameAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0
    private var badFrameCount = 0
    private var firstFailures: [String] = []
    private var geometry: (width: Int, height: Int, stride: Int)?
    private var sawStreaming = false
    private var sawEnded = false
    private var endedCount = 0
    private var stateLog: [String] = []

    func record(_ frame: PortalStream.Frame) {
        let failures = audit(frame)
        lock.lock()
        defer { lock.unlock() }
        frameCount += 1
        geometry = (frame.width, frame.height, frame.stride)
        if !failures.isEmpty {
            badFrameCount += 1
            if firstFailures.isEmpty { firstFailures = failures }
        }
    }

    func record(state: PortalStream.State) {
        lock.lock()
        defer { lock.unlock() }
        stateLog.append("\(state)")
        switch state {
        case .streaming: sawStreaming = true
        case .ended:
            sawEnded = true
            endedCount += 1
        default: break
        }
    }

    var snapshot:
        (
            frames: Int, badFrames: Int, failures: [String],
            geometry: (width: Int, height: Int, stride: Int)?, streaming: Bool, ended: Bool,
            endedCount: Int, states: [String]
        )
    {
        lock.lock()
        defer { lock.unlock() }
        return (
            frameCount, badFrameCount, firstFailures, geometry, sawStreaming, sawEnded, endedCount,
            stateLog
        )
    }
}

/// Everything that can be checked about one buffer while its pointer is alive.
///
/// The pattern is a different function of `(x, y)` per channel, which is what
/// makes this sharp rather than decorative: swapped red and blue (an RGBx
/// stream we should never have negotiated) and rows addressed at `width * 4`
/// instead of `stride` both land on values the pattern does not produce at that
/// coordinate.
private func audit(_ frame: PortalStream.Frame) -> [String] {
    var failures: [String] = []
    if frame.width != checkWidth || frame.height != checkHeight {
        failures.append(
            "geometry was \(frame.width)x\(frame.height), expected \(checkWidth)x\(checkHeight)")
    }
    let packed = frame.width * 4
    if frame.stride != packed + checkPadding {
        failures.append(
            "stride was \(frame.stride), expected \(packed + checkPadding) "
                + "(width*4 + \(checkPadding) of padding)")
    }
    // Everything below indexes with the reported stride, so a stride smaller
    // than one packed row means there is nothing safe to read.
    guard frame.stride >= packed, frame.width > 0, frame.height > 0 else { return failures }

    let samples = [
        (0, 0), (1, 0), (0, 1), (frame.width - 1, 0), (0, frame.height - 1),
        (frame.width - 1, frame.height - 1), (frame.width / 2, frame.height / 2), (17, 113)
    ]
    var expected = [UInt8](repeating: 0, count: 4)
    for (x, y) in samples {
        ts_pwfake_expected_pixel(Int32(x), Int32(y), &expected)
        let base = y * frame.stride + x * 4
        let actual = [frame.bgra[base], frame.bgra[base + 1], frame.bgra[base + 2]]
        guard actual != [expected[0], expected[1], expected[2]] else { continue }
        let hint =
            actual == [expected[2], expected[1], expected[0]]
            ? " — red and blue are swapped, i.e. an RGBx stream was negotiated" : ""
        failures.append(
            "pixel (\(x),\(y)) was BGR \(hexList(actual)), expected "
                + "\(hexList([expected[0], expected[1], expected[2]]))\(hint)")
        break
    }

    // The padding must still be poison. If it is not, the producer never
    // actually padded, and the stride check above proved nothing.
    let poison = ts_pwfake_padding_byte()
    for y in [0, frame.height / 2, frame.height - 1] {
        for offset in packed..<frame.stride where frame.bgra[y * frame.stride + offset] != poison {
            failures.append(
                "row \(y)'s padding at +\(offset) was "
                    + "0x\(String(frame.bgra[y * frame.stride + offset], radix: 16)), "
                    + "expected the poison byte 0x\(String(poison, radix: 16))")
            return failures
        }
    }
    return failures
}

private func hexList(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - Harness

/// A producer plus a consumer, linked, in the shape a real share has them: the
/// consumer reaches PipeWire through a descriptor it was handed, exactly as it
/// reaches it through OpenPipeWireRemote's.
private struct Harness {
    let producer: OpaquePointer
    let stream: PortalStream
    let audit: FrameAudit
}

private func fail(_ tag: String, _ message: String) -> Never {
    emitLine("\(tag) result=FAIL \(message)")
    exit(3)
}

private func waitUntil(_ deadline: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

private func startHarness(
    tag: String, rgbxOnly: Bool = false, corruptStride: Bool = false, markCorrupted: Bool = false
) -> Harness {
    var config = ts_pwfake_config_t()
    config.width = Int32(checkWidth)
    config.height = Int32(checkHeight)
    config.stride_padding = Int32(checkPadding)
    config.fps = 30
    config.offer_rgbx_only = rgbxOnly ? 1 : 0
    config.corrupt_stride = corruptStride ? 1 : 0
    config.mark_corrupted = markCorrupted ? 1 : 0

    guard let producer = ts_pwfake_start(&config) else {
        fail(tag, "no pipewire daemon reachable (start one and set XDG_RUNTIME_DIR)")
    }
    guard waitUntil(5, { ts_pwfake_node_id(producer) != 0 }) else {
        ts_pwfake_stop(producer)
        fail(tag, "the producer never got a node id: \(String(cString: ts_pwfake_last_error(producer)))")
    }
    let producerNode = ts_pwfake_node_id(producer)

    // The same kind of descriptor OpenPipeWireRemote returns, from a different
    // place: a socket connected to the daemon.
    let descriptor = ts_pwfake_open_daemon_fd()
    guard descriptor >= 0 else {
        ts_pwfake_stop(producer)
        fail(tag, "could not connect a descriptor to the pipewire daemon")
    }

    let audit = FrameAudit()
    let stream: PortalStream
    do {
        stream = try PortalStream(
            fileDescriptor: descriptor, nodeID: producerNode,
            onFrame: { audit.record($0) }, onState: { audit.record(state: $0) })
    } catch {
        ts_pwfake_stop(producer)
        fail(tag, "the consumer could not open a stream: \(error)")
    }

    // Stand in for the session manager. On a desktop, wireplumber links these
    // two in response to PW_STREAM_FLAG_AUTOCONNECT; there is none here, so the
    // autoconnect handshake itself stays unproven and everything downstream of
    // the link is what these checks cover.
    guard waitUntil(5, { stream.nodeID != 0 }) else {
        ts_pwfake_stop(producer)
        fail(tag, "the consumer's stream never got a node id")
    }
    guard ts_pwfake_link_to(producer, stream.nodeID) == 0 else {
        let detail = String(cString: ts_pwfake_last_error(producer))
        ts_pwfake_stop(producer)
        fail(tag, "could not link producer to consumer: \(detail)")
    }
    return Harness(producer: producer, stream: stream, audit: audit)
}

// MARK: - --pipewire-capture-test

func runPipeWireCaptureTest() -> Never {
    let tag = "PORTAL_PW_CAPTURE"
    let harness = startHarness(tag: tag)
    let audit = harness.audit

    guard waitUntil(15, { audit.snapshot.frames >= 10 }) else {
        let seen = audit.snapshot
        ts_pwfake_stop(harness.producer)
        fail(
            tag,
            "\(seen.frames) frames arrived in 15s, expected at least 10 "
                + "(the producer filled \(ts_pwfake_frames_produced(harness.producer)); "
                + "stream states: \(seen.states))")
    }

    let seen = audit.snapshot
    if seen.badFrames > 0 {
        ts_pwfake_stop(harness.producer)
        fail(tag, "\(seen.badFrames)/\(seen.frames) frames were wrong: \(seen.failures)")
    }
    guard seen.streaming else {
        ts_pwfake_stop(harness.producer)
        fail(tag, "frames arrived but the stream never reported .streaming: \(seen.states)")
    }
    guard let negotiated = harness.stream.size,
        negotiated.width == checkWidth, negotiated.height == checkHeight
    else {
        ts_pwfake_stop(harness.producer)
        fail(
            tag,
            "the negotiated size reads back as "
                + "\(harness.stream.size.map { "\($0.width)x\($0.height)" } ?? "nothing")")
    }
    guard harness.stream.frameCount >= 10 else {
        ts_pwfake_stop(harness.producer)
        fail(tag, "the stream's own frame counter says \(harness.stream.frameCount)")
    }

    // Second half: the source going away must read as ENDED. Written the
    // obvious way — trusting the stream state — this never fired at all, because
    // a producer's death drops the consumer to *paused*. A sharer would have sat
    // on a dead session showing viewers a frozen screen.
    ts_pwfake_stop(harness.producer)
    guard waitUntil(5, { audit.snapshot.ended }) else {
        fail(
            tag,
            "the producer went away and no .ended arrived within 5s "
                + "(states: \(audit.snapshot.states))")
    }
    let after = audit.snapshot
    guard after.endedCount == 1 else {
        fail(tag, ".ended was delivered \(after.endedCount) times, expected exactly once")
    }

    emitLine(
        "\(tag) result=PASS frames=\(seen.frames) geometry=\(checkWidth)x\(checkHeight) "
            + "stride=\(seen.geometry?.stride ?? -1) (packed would be \(checkWidth * 4)) "
            + "pattern=ok padding=intact ended=1")
    exit(0)
}

// MARK: - --pipewire-format-guard

func runPipeWireFormatGuard() -> Never {
    let tag = "PORTAL_PW_FORMAT"

    // Phase 1 is not decoration. Without it, "no frames arrived" is exactly what
    // a harness that never linked anything also produces, and the guard would
    // pass while proving nothing at all.
    let control = startHarness(tag: tag)
    let gotControlFrames = waitUntil(15, { control.audit.snapshot.frames >= 5 })
    let controlFrames = control.audit.snapshot.frames
    ts_pwfake_stop(control.producer)
    guard gotControlFrames else {
        fail(tag, "the control (BGRx) producer delivered \(controlFrames) frames; the harness is broken")
    }

    // Phase 2: the same harness, with a producer that offers ONLY RGBx. Nothing
    // may be negotiated. If it is, every frame reaching a viewer has red and
    // blue swapped, and nothing anywhere reports an error.
    let guarded = startHarness(tag: tag, rgbxOnly: true)
    Thread.sleep(forTimeInterval: 5)
    let seen = guarded.audit.snapshot
    ts_pwfake_stop(guarded.producer)

    if seen.frames > 0 {
        fail(
            tag,
            "\(seen.frames) frames were accepted from an RGBx-only producer — "
                + "the format constraint is not doing anything")
    }
    if seen.streaming {
        fail(tag, "the stream reached .streaming against an RGBx-only producer: \(seen.states)")
    }
    if guarded.stream.size != nil {
        fail(tag, "a format was negotiated with an RGBx-only producer")
    }
    emitLine(
        "\(tag) result=PASS control=\(controlFrames) frames, RGBx-only=\(seen.frames) frames, "
            + "no format negotiated")
    exit(0)
}

// MARK: - --pipewire-malformed-guard

/// The two branches in `on_process` that only a broken producer reaches, and
/// that therefore had never run: a `chunk->stride` wider than the mapping, and
/// a buffer the producer flagged as corrupted.
///
/// The first is a memory-safety branch — believing that stride is a read past
/// the end of somebody else's shared mapping, which is a crash at best. The
/// second is a correctness one: a torn frame encoded is a torn frame every
/// viewer keeps until the next keyframe.
func runPipeWireMalformedGuard() -> Never {
    let tag = "PORTAL_PW_MALFORMED"

    for (label, harness) in [
        ("stride wider than the buffer", startHarness(tag: tag, corruptStride: true)),
        ("SPA_CHUNK_FLAG_CORRUPTED", startHarness(tag: tag, markCorrupted: true))
    ] {
        Thread.sleep(forTimeInterval: 4)
        let seen = harness.audit.snapshot
        let produced = ts_pwfake_frames_produced(harness.producer)
        ts_pwfake_stop(harness.producer)
        // Without this the check passes whenever nothing flowed at all, which
        // is the same green a broken harness produces.
        guard produced > 0 else {
            fail(tag, "the producer never filled a buffer for the \(label) case; nothing was tested")
        }
        guard seen.frames == 0 else {
            fail(
                tag,
                "\(seen.frames) frames were delivered from a producer with \(label) "
                    + "(it queued \(produced))")
        }
    }
    emitLine("\(tag) result=PASS both malformed-buffer cases were dropped, not delivered")
    exit(0)
}
