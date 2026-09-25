import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenAudio

/// `SharerVoiceSession` — the start/stop/toggle triple both share engines
/// drive. Written once because GTK and WinUI each had it slightly
/// differently, and every difference was invisible at runtime: a route
/// published too late drops packets already sent, `onStopped` installed too
/// late loses the report that a device never opened, and a mute flag
/// surviving teardown is a live-microphone indicator over nothing.
final class SharerVoiceSessionTests: XCTestCase {

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
        func fail() { onStopped?(NoDevice()) }
    }

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

    /// The handler installed before `start()` is valid for the life of the
    /// session — routes through a long-lived `SharerVoiceRoute` rather than
    /// capturing a voice that doesn't exist yet, since reassigning
    /// `server.onAudioReceived` on a running share is a data race.
    func testInboundHandlerIsStableAcrossSharesAndSafeBeforeAnyDevice() throws {
        let (session, _) = makeSession()
        let handler = session.inboundHandler
        handler(Data([0, 1, 2, 3]))  // arrives before anything is open: dropped, not crashed

        try session.start(microphone: ManualMic(), send: { _ in })
        handler(Data([0, 1, 2, 3]))
        session.stop()
        handler(Data([0, 1, 2, 3]))
    }

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
        // Viewer SSRCs start at 2 — 0 is sharer voice, 1 system audio.
        let packetizer = AudioRTPPacketizer(
            ssrc: 2, payloadType: RTPHeader.voicePayloadType)
        session.inboundHandler(packetizer.packetize(au: au))
        XCTAssertEqual(framesLock.withLock { frames }, 1)
    }

    // MARK: Start / stop

    /// Starting must not put somebody on the air before they know the call
    /// is live.
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

    func testAFailedStartPublishesNothingAndLeavesTheRouteEmpty() {
        let (session, log) = makeSession()
        XCTAssertThrowsError(
            try session.start(microphone: ManualMic(failsToStart: true), send: { _ in }))
        XCTAssertEqual(log.count, 0, "the host words the failure; the latch never moved")
        XCTAssertFalse(session.isAvailable)
        session.inboundHandler(Data([0, 1, 2, 3]))
    }

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

    func testStopIsIdempotentAndSilentWhenNothingWasOpen() {
        let (session, log) = makeSession()
        session.stop()
        session.stop()
        XCTAssertEqual(log.count, 0)
    }

    // MARK: The device going away mid-share

    /// Both flags come down together — a live indicator over a device
    /// recording nothing is the one wrong answer here.
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

    /// Once gone, the toggle cannot bring the indicator back — the case both
    /// engines got wrong by guarding on the voice rather than availability.
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

    /// A caller-asked stop must not be reported as a device failure.
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

    func testToggleWithNoDeviceIsSilent() {
        let (session, log) = makeSession()
        session.toggleMic()
        session.toggleMic()
        XCTAssertEqual(log.count, 0)
        XCTAssertFalse(session.isOn)
    }
}
