import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenAudio

/// `SharerVoiceSession` — the start/stop/toggle triple both share engines drive,
/// and the ordering inside it that is the whole of the correctness.
///
/// Written once because the GTK and WinUI engines each had it, each had it
/// slightly differently, and every difference was invisible at runtime: a route
/// published a moment too late drops the packets a viewer already sent, an
/// `onStopped` installed a moment too late loses the report that the device
/// never opened, and a mute flag that survives teardown is a live-microphone
/// indicator over nothing.
final class SharerVoiceSessionTests: XCTestCase {

    /// A microphone that is only ever asked to start and stop.
    private final class ManualMic: MicrophoneCapturing, @unchecked Sendable {
        var onPCM: (([Float], AudioInputFormat) -> Void)?
        var onStopped: ((Error?) -> Void)?
        private let lock = NSLock()
        private var stops = 0
        var stopCount: Int { lock.withLock { stops } }
        let failsToStart: Bool

        init(failsToStart: Bool = false) { self.failsToStart = failsToStart }

        struct NoDevice: Error {}
        func start() throws { if failsToStart { throw NoDevice() } }
        func stop() { lock.withLock { stops += 1 } }

        func feedFrame() {
            onPCM?((0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }, .wire)
        }
        /// The device going away underneath a running stream.
        func fail() { onStopped?(NoDevice()) }
    }

    /// Collects `@Sendable` state pushes — the callback fires from whichever
    /// thread moved the device.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(Bool, Bool)] = []
        var all: [(Bool, Bool)] { lock.withLock { entries } }
        var count: Int { lock.withLock { entries.count } }
        var last: (Bool, Bool)? { lock.withLock { entries.last } }
        func append(_ state: (Bool, Bool)) { lock.withLock { entries.append(state) } }
    }

    private func makeSession() -> (SharerVoiceSession, StateLog) {
        let session = SharerVoiceSession()
        let log = StateLog()
        session.onStateChanged = { available, on in log.append((available, on)) }
        return (session, log)
    }

    // MARK: The route

    /// The handler installed on the server before `start()` is valid for the
    /// life of the session — that is the whole reason it routes through a
    /// long-lived `SharerVoiceRoute` rather than capturing a voice that does
    /// not exist yet. Reassigning `server.onAudioReceived` on a running share
    /// is a data race on a bare stored var its receive thread reads with no
    /// lock.
    func testInboundHandlerIsStableAcrossSharesAndSafeBeforeAnyDevice() throws {
        let (session, _) = makeSession()
        let handler = session.inboundHandler
        // Arrives before anything is open: dropped, not crashed. It is the only
        // thing a packet from before there is a voice could be.
        handler(Data([0, 1, 2, 3]))

        try session.start(microphone: ManualMic(), send: { _ in })
        // Still the same handler, and now it reaches a live voice.
        handler(Data([0, 1, 2, 3]))
        session.stop()
        handler(Data([0, 1, 2, 3]))
    }

    /// A viewer already speaking is heard from the first packet, not from the
    /// first packet after the device finished opening.
    func testAViewerIsHeardThroughTheRoute() throws {
        let (session, _) = makeSession()
        let heard = StateLog()
        var frames = 0
        let framesLock = NSLock()
        session.onRemotePCM = { pcm in
            XCTAssertEqual(pcm.count, 960)
            framesLock.withLock { frames += 1 }
        }
        _ = heard

        try session.start(microphone: ManualMic(), send: { _ in })

        let encoder = try OpusVoiceEncoder()
        let au = try XCTUnwrap(
            encoder.encode(pcm: (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }))
        // Viewer SSRCs start at 2 — 0 is the sharer's own voice, 1 system audio.
        let packetizer = AudioRTPPacketizer(
            ssrc: 2, payloadType: RTPHeader.voicePayloadType)
        session.inboundHandler(packetizer.packetize(au: au))
        XCTAssertEqual(framesLock.withLock { frames }, 1)
    }

    // MARK: Start / stop

    /// Starting publishes available-and-muted, and the microphone really is
    /// muted: a share that put somebody on the air the moment it came up would
    /// be a person talking into a call they did not know was live.
    func testStartPublishesAvailableAndSendsNothingUntilUnmuted() throws {
        let (session, log) = makeSession()
        let mic = ManualMic()
        let sent = StateLog()
        var packets = 0
        let packetsLock = NSLock()
        _ = sent

        try session.start(microphone: mic, send: { _ in packetsLock.withLock { packets += 1 } })
        XCTAssertEqual(log.last?.0, true)
        XCTAssertEqual(log.last?.1, false)

        mic.feedFrame()
        XCTAssertEqual(packetsLock.withLock { packets }, 0, "still muted")

        session.toggleMic()
        XCTAssertEqual(log.last?.1, true)
        mic.feedFrame()
        XCTAssertGreaterThan(packetsLock.withLock { packets }, 0)
    }

    /// A device that will not open leaves nothing behind — no published
    /// availability, and no route pointing at a voice that never ran.
    func testAFailedStartPublishesNothingAndLeavesTheRouteEmpty() {
        let (session, log) = makeSession()
        XCTAssertThrowsError(
            try session.start(microphone: ManualMic(failsToStart: true), send: { _ in }))
        XCTAssertEqual(log.count, 0, "the host words the failure; the latch never moved")
        XCTAssertFalse(session.isAvailable)
        // The route must not have been left pointing at the dead voice.
        session.inboundHandler(Data([0, 1, 2, 3]))
    }

    /// Stopping releases the device and drops both flags together — and the
    /// device really is released, because an open capture device after Stop
    /// Sharing keeps the OS microphone indicator lit.
    func testStopReleasesTheDeviceAndClearsBothFlags() throws {
        let (session, log) = makeSession()
        let mic = ManualMic()
        try session.start(microphone: mic, send: { _ in })
        session.toggleMic()
        XCTAssertTrue(session.isOn)

        session.stop()
        XCTAssertEqual(mic.stopCount, 1)
        XCTAssertEqual(log.last?.0, false)
        XCTAssertEqual(log.last?.1, false)
        XCTAssertFalse(session.isAvailable)
        XCTAssertFalse(session.isOn)
    }

    /// Every teardown path calls `stop()`, including ones that never opened a
    /// device. A second call must not push a status nothing changed.
    func testStopIsIdempotentAndSilentWhenNothingWasOpen() {
        let (session, log) = makeSession()
        session.stop()
        session.stop()
        XCTAssertEqual(log.count, 0)
    }

    // MARK: The device going away mid-share

    /// The report the WinUI engine could previously miss, because it installed
    /// `onStopped` *after* `start()`. Both flags come down together: a live
    /// indicator over a device recording nothing is the one wrong answer here.
    func testADeviceLostMidShareClearsBothFlags() throws {
        let (session, log) = makeSession()
        let mic = ManualMic()
        try session.start(microphone: mic, send: { _ in })
        session.toggleMic()
        XCTAssertEqual(log.last.map { [$0.0, $0.1] }, [true, true])

        mic.fail()
        XCTAssertEqual(log.last.map { [$0.0, $0.1] }, [false, false])
        XCTAssertFalse(session.isAvailable)
    }

    /// And once it is gone, the toggle cannot bring the indicator back — the
    /// exact case both engines got wrong by guarding on the voice rather than
    /// on availability.
    func testToggleAfterTheDeviceIsLostChangesNothing() throws {
        let (session, log) = makeSession()
        let mic = ManualMic()
        try session.start(microphone: mic, send: { _ in })
        mic.fail()
        let after = log.count

        session.toggleMic()
        XCTAssertEqual(log.count, after, "nothing moved, so nothing is published")
        XCTAssertFalse(session.isOn)
    }

    /// A caller-asked stop must not be reported as a device failure — the host
    /// has already published, and a second "your microphone went away" over a
    /// share the person ended themselves reads as a fault.
    func testAnAskedForStopIsNotReportedAsAFailure() throws {
        let (session, log) = makeSession()
        let mic = ManualMic()
        try session.start(microphone: mic, send: { _ in })
        let afterStart = log.count

        session.stop()
        XCTAssertEqual(
            log.count, afterStart + 1,
            "exactly one transition: the teardown, not a teardown plus a failure")
    }

    /// A toggle with no device open publishes nothing at all, so a host can
    /// wire `onStateChanged` straight into whatever re-renders.
    func testToggleWithNoDeviceIsSilent() {
        let (session, log) = makeSession()
        session.toggleMic()
        session.toggleMic()
        XCTAssertEqual(log.count, 0)
        XCTAssertFalse(session.isOn)
    }
}
