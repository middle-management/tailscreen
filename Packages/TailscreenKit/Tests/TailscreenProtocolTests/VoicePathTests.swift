import Foundation
import XCTest

@testable import TailscreenAudio
@testable import TailscreenProtocol

/// The voice path both endpoints share: the capture thread that pumps a
/// blocking device, the uplink that turns microphone buffers into RTP, and the
/// downlink that turns RTP back into PCM.
///
/// All three are driven here through fakes rather than a device, which is the
/// point: none of these decisions can be observed on a machine with a real
/// microphone (there is no CI runner with one, and a person listening cannot
/// tell a withheld packet from a quiet room).
final class VoicePathTests: XCTestCase {

    // MARK: - ThreadedMicrophone

    /// A blocking source under test control: hands out canned buffers, then
    /// parks until the test releases it or it is closed.
    private final class FakeSource: BlockingPCMSource, @unchecked Sendable {
        let inputFormat: AudioInputFormat
        private let lock = NSLock()
        private var queued: [[Float]]
        private var closed = false
        private let gate = DispatchSemaphore(value: 0)
        /// Set to have the next read throw instead of returning audio.
        var failWith: Error?
        private(set) var closeCount = 0

        init(format: AudioInputFormat = .wire, buffers: [[Float]] = []) {
            self.inputFormat = format
            self.queued = buffers
        }

        struct Closed: Error {}
        /// Set to have the next read report a device glitch alongside its audio.
        var glitchNext = false

        func readPCM() throws -> CapturedPCM {
            if let failWith { throw failWith }
            let glitched = lock.withLock { () -> Bool in
                let g = glitchNext
                glitchNext = false
                return g
            }
            let next = lock.withLock { queued.isEmpty ? nil : queued.removeFirst() }
            if let next { return CapturedPCM(samples: next, discontinuity: glitched) }
            // Nothing queued: park like a real device would, until closed.
            gate.wait()
            if lock.withLock({ closed }) { throw Closed() }
            return CapturedPCM(samples: [], discontinuity: glitched)
        }

        func closePCM() {
            lock.withLock {
                closed = true
                closeCount += 1
            }
            gate.signal()
        }
    }

    func testCaptureThreadDeliversEveryBuffer() throws {
        let source = FakeSource(buffers: [[0.1, 0.2], [0.3], [0.4, 0.5, 0.6]])
        let mic = ThreadedMicrophone(source: source)
        let received = Mutexish<[[Float]]>([])
        let done = expectation(description: "three buffers")
        done.expectedFulfillmentCount = 3
        mic.onPCM = { pcm, format in
            XCTAssertEqual(format, .wire)
            received.mutate { $0.append(pcm) }
            done.fulfill()
        }
        try mic.start()
        wait(for: [done], timeout: 5)
        mic.stop()
        XCTAssertEqual(received.value, [[0.1, 0.2], [0.3], [0.4, 0.5, 0.6]])
    }

    /// The guarantee the lock discipline exists for: a buffer captured just
    /// before `stop()` must not land just after, on a host that has already
    /// torn its encoder down.
    ///
    /// Asserted by *timing* rather than by watching for a stray delivery,
    /// which is the only version that can fail. The obvious wrong
    /// implementation — read the flag, then call the callback outside the lock
    /// — loses only in a window a few instructions wide, and a test that races
    /// for it passes every time against the bug. So this drives the property
    /// from the other end: if `stop()` truly cannot return while a delivery is
    /// in flight, then stopping *during* a slow delivery must block until it
    /// finishes. The check-then-call version returns immediately and fails
    /// here every time.
    func testStopWaitsForADeliveryAlreadyInFlight() throws {
        let source = FakeSource(buffers: [[0.5], [0.6]])
        let mic = ThreadedMicrophone(source: source)
        let deliveryStarted = DispatchSemaphore(value: 0)
        let deliveryFinished = Mutexish<Bool>(false)
        let deliveryDuration = 0.4
        mic.onPCM = { _, _ in
            deliveryStarted.signal()
            Thread.sleep(forTimeInterval: deliveryDuration)
            deliveryFinished.mutate { $0 = true }
        }
        try mic.start()
        XCTAssertEqual(deliveryStarted.wait(timeout: .now() + 5), .success)

        let began = Date()
        mic.stop()
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertTrue(
            deliveryFinished.value,
            "stop() returned while a buffer was still being delivered")
        XCTAssertGreaterThan(
            elapsed, deliveryDuration * 0.5,
            "stop() did not wait for the in-flight delivery (took \(elapsed)s)")
    }

    func testDeviceFailureIsReportedAsAnError() throws {
        struct Unplugged: Error {}
        let source = FakeSource()
        source.failWith = Unplugged()
        let mic = ThreadedMicrophone(source: source)
        let stopped = expectation(description: "onStopped")
        let reported = Mutexish<Bool>(false)
        mic.onStopped = { error in
            reported.mutate { $0 = error is Unplugged }
            stopped.fulfill()
        }
        try mic.start()
        wait(for: [stopped], timeout: 5)
        XCTAssertTrue(reported.value)
    }

    /// A read that fails *because we closed the device* is the stop we asked
    /// for. Reporting it as an error puts "your microphone disconnected" in
    /// front of somebody who clicked mute.
    func testAskedForStopIsNotReportedAsAnError() throws {
        let source = FakeSource()
        let mic = ThreadedMicrophone(source: source)
        let stopped = expectation(description: "onStopped")
        let sawError = Mutexish<Bool>(false)
        mic.onStopped = { error in
            sawError.mutate { $0 = error != nil }
            stopped.fulfill()
        }
        try mic.start()
        // Let the pump reach its park before stopping.
        Thread.sleep(forTimeInterval: 0.05)
        mic.stop()
        wait(for: [stopped], timeout: 5)
        XCTAssertFalse(sawError.value)
    }

    func testStopIsIdempotentAndStartDoesNotDoubleOpen() throws {
        let source = FakeSource()
        let mic = ThreadedMicrophone(source: source)
        try mic.start()
        try mic.start()  // second start must not spawn a second pump
        mic.stop()
        mic.stop()
        XCTAssertEqual(source.closeCount, 1)
    }

    func testDeviceGlitchIsForwardedToTheHost() throws {
        let source = FakeSource(buffers: [[0.1], [0.2]])
        source.glitchNext = true
        let mic = ThreadedMicrophone(source: source)
        let glitched = expectation(description: "onDiscontinuity")
        mic.onDiscontinuity = { glitched.fulfill() }
        mic.onPCM = { _, _ in }
        try mic.start()
        wait(for: [glitched], timeout: 5)
        mic.stop()
    }

    /// A glitch resets the resampler's carried neighbour and must NOT drop the
    /// framer's carry: those are samples the person actually said, and throwing
    /// them away turns one device hole into two.
    func testDiscontinuityKeepsCapturedAudioButResetsInterpolation() throws {
        let pipeline = MicrophonePipeline(encoder: try OpusVoiceEncoder())
        var emitted = 0
        pipeline.onAccessUnit = { _ in emitted += 1 }

        // 500 samples: not a whole 960-sample frame, so nothing is emitted and
        // all of it sits in the framer's carry.
        pipeline.ingest(Array(repeating: 0.1, count: 500), format: .wire)
        XCTAssertEqual(emitted, 0)

        pipeline.noteDiscontinuity()

        // 460 more completes exactly one frame — but only if the carry survived.
        pipeline.ingest(Array(repeating: 0.1, count: 460), format: .wire)
        XCTAssertEqual(emitted, 1, "noteDiscontinuity discarded audio it should have kept")
    }

    // MARK: - VoiceUplink

    /// A microphone the test drives by hand — no thread, so delivery is
    /// deterministic.
    private final class ManualMic: MicrophoneCapturing, @unchecked Sendable {
        var onPCM: (([Float], AudioInputFormat) -> Void)?
        var onStopped: ((Error?) -> Void)?
        private(set) var started = false
        private(set) var stopCount = 0
        func start() throws { started = true }
        func stop() { stopCount += 1 }

        /// Feed exactly one 20 ms frame of audible tone.
        func feedFrame(count: Int = 1) {
            for _ in 0..<count {
                let pcm = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
                onPCM?(pcm, .wire)
            }
        }
    }

    func testAudioIsWithheldUntilAnSSRCIsAssigned() throws {
        let mic = ManualMic()
        let sent = Mutexish<[Data]>([])
        let uplink = try VoiceUplink(
            microphone: mic, encoder: OpusVoiceEncoder(),
            send: { packet in sent.mutate { $0.append(packet) } })

        mic.feedFrame(count: 3)
        XCTAssertTrue(sent.value.isEmpty, "a viewer must not emit voice as SSRC 0")
        XCTAssertEqual(uplink.withheldPacketCount, 3)

        uplink.setSSRC(7)
        mic.feedFrame(count: 2)
        XCTAssertEqual(sent.value.count, 2)
        XCTAssertEqual(uplink.withheldPacketCount, 3, "the earlier frames stay withheld")

        // And they go out under the assigned SSRC, as PT 98.
        let header = try XCTUnwrap(RTPHeader.decode(from: sent.value[0])?.0)
        XCTAssertEqual(header.ssrc, 7)
        XCTAssertEqual(header.payloadType, RTPHeader.voicePayloadType)
    }

    func testSharerSendsUnderTheReservedSSRCImmediately() throws {
        let mic = ManualMic()
        let sent = Mutexish<[Data]>([])
        let uplink = try VoiceUplink(
            microphone: mic, encoder: OpusVoiceEncoder(),
            send: { packet in sent.mutate { $0.append(packet) } })
        uplink.setSSRC(VoiceUplink.sharerSSRC)
        mic.feedFrame()
        XCTAssertEqual(sent.value.count, 1)
        XCTAssertEqual(RTPHeader.decode(from: sent.value[0])?.0.ssrc, RTPHeader.sharerVoiceSSRC)
    }

    /// Mute is a privacy guarantee, so it is asserted on the wire rather than
    /// on a flag: a leak here would be indistinguishable from working software.
    func testMuteStopsAudioLeavingTheMachine() throws {
        let mic = ManualMic()
        let sent = Mutexish<[Data]>([])
        let uplink = try VoiceUplink(
            microphone: mic, encoder: OpusVoiceEncoder(),
            send: { packet in sent.mutate { $0.append(packet) } })
        uplink.setSSRC(3)

        mic.feedFrame(count: 2)
        XCTAssertEqual(sent.value.count, 2)

        uplink.isMuted = true
        mic.feedFrame(count: 10)
        XCTAssertEqual(sent.value.count, 2, "muted audio reached the wire")

        uplink.isMuted = false
        mic.feedFrame(count: 1)
        XCTAssertEqual(sent.value.count, 3)
    }

    /// A different SSRC is a different stream. Continuing the old sequence
    /// numbering hands the receiver a stream that appears to have jumped.
    func testReassigningTheSSRCRestartsTheStream() throws {
        let mic = ManualMic()
        let sent = Mutexish<[Data]>([])
        let uplink = try VoiceUplink(
            microphone: mic, encoder: OpusVoiceEncoder(),
            send: { packet in sent.mutate { $0.append(packet) } })
        uplink.setSSRC(3)
        mic.feedFrame(count: 3)
        let beforeSeq = try XCTUnwrap(RTPHeader.decode(from: sent.value[2])?.0.sequenceNumber)
        XCTAssertGreaterThan(beforeSeq, 0)

        uplink.setSSRC(4)
        mic.feedFrame()
        let after = try XCTUnwrap(RTPHeader.decode(from: sent.value[3])?.0)
        XCTAssertEqual(after.ssrc, 4)
        XCTAssertEqual(after.sequenceNumber, 0)
    }

    func testStopReleasesTheDevice() throws {
        let mic = ManualMic()
        let uplink = try VoiceUplink(
            microphone: mic, encoder: OpusVoiceEncoder(), send: { _ in })
        try uplink.start()
        XCTAssertTrue(mic.started)
        uplink.stop()
        XCTAssertEqual(mic.stopCount, 1)
    }

    // MARK: - VoiceDownlink

    func testDownlinkDecodesEachSSRCIndependently() throws {
        let downlink = VoiceDownlink()
        var heard: [(UInt32, Int)] = []
        downlink.onPCM = { ssrc, pcm in heard.append((ssrc, pcm.count)) }

        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))

        for ssrc in [UInt32(0), 1, 9] {
            let packetizer = AudioRTPPacketizer(
                ssrc: ssrc, payloadType: RTPHeader.voicePayloadType)
            downlink.ingest(packetizer.packetize(au: au))
        }
        XCTAssertEqual(heard.map(\.0), [0, 1, 9])
        XCTAssertTrue(heard.allSatisfy { $0.1 == 960 })
        XCTAssertEqual(downlink.voiceCount, 3)
    }

    func testGarbageIsDroppedWithoutAllocatingADecoder() {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onPCM = { _, _ in heard += 1 }
        downlink.ingest(Data())
        downlink.ingest(Data([0xFF, 0x00, 0x01]))
        XCTAssertEqual(heard, 0)
        XCTAssertEqual(downlink.voiceCount, 0)
    }

    /// The SSRC is a field in a datagram from the network, so an unbounded
    /// decoder map is a remote allocation primitive.
    func testDecoderMapIsBounded() throws {
        let downlink = VoiceDownlink()
        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))
        for ssrc in 0..<UInt32(VoiceDownlink.maxConcurrentVoices * 4) {
            let packetizer = AudioRTPPacketizer(
                ssrc: ssrc, payloadType: RTPHeader.voicePayloadType)
            downlink.ingest(packetizer.packetize(au: au))
        }
        XCTAssertLessThanOrEqual(downlink.voiceCount, VoiceDownlink.maxConcurrentVoices)
    }

    /// Eviction takes the quietest stream, so a participant who keeps talking
    /// is never the one dropped to make room for a stranger.
    func testEvictionDropsTheStalestStream() throws {
        let downlink = VoiceDownlink()
        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))
        func send(_ ssrc: UInt32) {
            let packetizer = AudioRTPPacketizer(
                ssrc: ssrc, payloadType: RTPHeader.voicePayloadType)
            downlink.ingest(packetizer.packetize(au: au))
        }

        // Fill to the bound; SSRC 0 is the oldest.
        for ssrc in 0..<UInt32(VoiceDownlink.maxConcurrentVoices) { send(ssrc) }
        XCTAssertEqual(downlink.voiceCount, VoiceDownlink.maxConcurrentVoices)

        // Everyone but 0 speaks again, so 0 is unambiguously the stalest.
        for ssrc in 1..<UInt32(VoiceDownlink.maxConcurrentVoices) { send(ssrc) }

        send(9999)  // a newcomer, forcing exactly one eviction
        XCTAssertEqual(downlink.voiceCount, VoiceDownlink.maxConcurrentVoices)
        // Asserted per stream, not just on the count: a bound that holds while
        // the policy drops whoever is currently talking is the failure this
        // test exists to catch.
        XCTAssertFalse(downlink.hasVoice(0), "the quiet stream should have been evicted")
        XCTAssertTrue(downlink.hasVoice(9999), "the newcomer should have a decoder")
        for ssrc in 1..<UInt32(VoiceDownlink.maxConcurrentVoices) {
            XCTAssertTrue(downlink.hasVoice(ssrc), "an active stream was evicted: \(ssrc)")
        }
    }

    func testResetForgetsEveryStream() throws {
        let downlink = VoiceDownlink()
        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))
        let packetizer = AudioRTPPacketizer(ssrc: 5, payloadType: RTPHeader.voicePayloadType)
        downlink.ingest(packetizer.packetize(au: au))
        XCTAssertEqual(downlink.voiceCount, 1)
        downlink.reset()
        XCTAssertEqual(downlink.voiceCount, 0)
    }

    // MARK: - VoiceDownlink loss resilience

    /// Milliseconds → the nanosecond clock `ingest` takes.
    private func ms(_ value: Int) -> UInt64 { UInt64(value) * 1_000_000 }

    /// Encode `count` phase-continuous 20 ms tone frames and packetize them
    /// under one sequence space, so tests can feed subsets and open real gaps.
    private func voicePackets(count: Int, ssrc: UInt32) throws -> [Data] {
        let encoder = try OpusVoiceEncoder()
        let packetizer = AudioRTPPacketizer(ssrc: ssrc, payloadType: RTPHeader.voicePayloadType)
        var packets: [Data] = []
        for frame in 0..<count {
            let tone = (0..<960).map { Float(sin(Double(frame * 960 + $0) * 0.05)) * 0.4 }
            if let au = try encoder.encode(pcm: tone) {
                packets.append(packetizer.packetize(au: au))
            }
        }
        return packets
    }

    func testGapConcealsWithOpusPLCUpToTheCapAndFadesOut() throws {
        let downlink = VoiceDownlink()
        var heard: [[Float]] = []
        downlink.onPCM = { _, pcm in heard.append(pcm) }
        let packets = try voicePackets(count: 10, ssrc: 7)
        try XCTSkipIf(packets.count < 10, "Opus encoder produced no usable output on this host")

        let base = ms(1000)
        for i in 0..<3 { downlink.ingest(packets[i], nowNs: base + ms(20 * i)) }
        XCTAssertEqual(heard.count, 3)

        // Packets 3...6 lost — a 4-frame gap. Concealment is capped at
        // playbackSlackBuffers - 1 == 2 frames, then the arrived packet.
        downlink.ingest(packets[7], nowNs: base + ms(140))
        XCTAssertEqual(heard.count, 6, "2 concealment frames + the decoded packet")
        XCTAssertEqual(downlink.concealedFrameCount, 2)
        XCTAssertEqual(downlink.discontinuityCount, 0, "a concealable gap is not a resync")

        let firstConcealed = heard[3]
        XCTAssertEqual(firstConcealed.count, 960, "PLC must synthesize a whole 20 ms frame")
        let rms = sqrt(firstConcealed.reduce(0) { $0 + $1 * $1 } / Float(firstConcealed.count))
        XCTAssertGreaterThan(rms, 0.01, "Opus PLC should extrapolate the tone, not emit silence")
        XCTAssertEqual(heard[4].last, 0, "a capped gap's last concealment frame must end at silence")

        // The first real frame after the uncovered remainder fades back in.
        XCTAssertLessThan(abs(heard[5][0]), 0.05, "the resume frame must start from (near) silence")
        XCTAssertGreaterThan(heard[5].map { abs($0) }.max() ?? 0, 0.05, "and still carry audio")

        // The stream keeps flowing normally afterwards.
        downlink.ingest(packets[8], nowNs: base + ms(160))
        downlink.ingest(packets[9], nowNs: base + ms(180))
        XCTAssertEqual(heard.count, 8)
        XCTAssertEqual(downlink.concealedFrameCount, 2)
    }

    func testLatePacketAfterConcealmentIsDroppedStale() throws {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onPCM = { _, _ in heard += 1 }
        let packets = try voicePackets(count: 6, ssrc: 9)
        try XCTSkipIf(packets.count < 6, "Opus encoder produced no usable output on this host")

        let base = ms(1000)
        downlink.ingest(packets[0], nowNs: base)
        downlink.ingest(packets[1], nowNs: base + ms(20))
        // Packet 2 lost; 3 arrives → one PLC frame (gap fully covered) + the
        // decoded packet itself.
        downlink.ingest(packets[3], nowNs: base + ms(60))
        XCTAssertEqual(heard, 4)
        XCTAssertEqual(downlink.concealedFrameCount, 1)

        // The lost packet finally straggles in — its 20 ms were already
        // played as concealment, so it must not play again.
        downlink.ingest(packets[2], nowNs: base + ms(80))
        XCTAssertEqual(heard, 4, "a late packet whose gap was concealed must not decode")
        XCTAssertEqual(downlink.concealedFrameCount, 1)

        downlink.ingest(packets[4], nowNs: base + ms(100))
        XCTAssertEqual(heard, 5, "the stream continues in order after the straggler")
        XCTAssertEqual(downlink.discontinuityCount, 0)
    }

    func testLargeGapResyncsInsteadOfConcealing() throws {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onPCM = { _, _ in heard += 1 }
        let packets = try voicePackets(count: 10, ssrc: 12)
        try XCTSkipIf(packets.count < 10, "Opus encoder produced no usable output on this host")

        let base = ms(1000)
        downlink.ingest(packets[0], nowNs: base)
        downlink.ingest(packets[9], nowNs: base + ms(180))
        XCTAssertEqual(heard, 2, "a resync decodes without filling the gap")
        XCTAssertEqual(downlink.concealedFrameCount, 0)
        XCTAssertEqual(downlink.discontinuityCount, 1)
    }

    func testDecoderInitFailureCooldownGatesThenRecovers() throws {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onPCM = { _, _ in heard += 1 }
        let packets = try voicePackets(count: 6, ssrc: 4)
        try XCTSkipIf(packets.count < 6, "Opus encoder produced no usable output on this host")

        let base = ms(1000)
        downlink.ingest(packets[0], nowNs: base)
        XCTAssertEqual(heard, 1)

        let record = VoiceReceiveDecisions.DecoderFailureRecord(
            consecutiveInitFailures: 1, lastFailureNs: base)
        downlink.injectDecoderFailureForTesting(ssrc: 4, record: record)
        downlink.ingest(packets[1], nowNs: base + ms(20))
        downlink.ingest(packets[2], nowNs: base + ms(40))
        XCTAssertEqual(heard, 1, "packets inside the cooldown must be dropped")
        XCTAssertEqual(
            downlink.decoderFailuresForTesting[4], record,
            "dropping packets must not mutate the failure record")

        // Past the 5 s cooldown the retry is allowed, decodes, and clears the
        // record — and the gate-dropped packets advanced the baseline, so the
        // resume is not misread as a gap.
        downlink.ingest(packets[3], nowNs: base + ms(6000))
        XCTAssertEqual(heard, 2, "an elapsed cooldown must allow the retry")
        XCTAssertNil(downlink.decoderFailuresForTesting[4])
        XCTAssertEqual(downlink.concealedFrameCount, 0, "the gated stretch must not read as a gap")
        XCTAssertEqual(downlink.discontinuityCount, 0)
    }

    func testIdleSSRCIsEvictedWhileTheActiveOneIsKept() throws {
        let downlink = VoiceDownlink()
        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))

        let base = ms(1000)
        let idle = AudioRTPPacketizer(ssrc: 2, payloadType: RTPHeader.voicePayloadType)
        downlink.ingest(idle.packetize(au: au), nowNs: base)
        XCTAssertTrue(downlink.hasVoice(2))

        // SSRC 3 keeps talking for 12 s; SSRC 2 stays silent past the 10 s
        // idle window, so the ~1 Hz sweep forgets it — a departed peer's
        // frozen jitter must not pin the target for the session.
        let active = AudioRTPPacketizer(ssrc: 3, payloadType: RTPHeader.voicePayloadType)
        for i in 1...600 {
            downlink.ingest(active.packetize(au: au), nowNs: base + ms(20 * i))
        }
        XCTAssertFalse(downlink.hasVoice(2), "an idle stream must be evicted")
        XCTAssertTrue(downlink.hasVoice(3), "the active stream must survive the sweep")
    }

    func testJitterTargetAdaptsUpUnderJitterAndDecaysWhenCalm() throws {
        let downlink = VoiceDownlink()
        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))

        // Hand-built RTP so the timestamps carry the deviation — the arrival
        // clock has to stay monotonic, so it cannot.
        var seq: UInt16 = 0
        var ts: UInt32 = 0
        func packet(tsStep: UInt32) -> Data {
            ts &+= tsStep
            var data = Data()
            let header = RTPHeader(
                marker: true, payloadType: RTPHeader.voicePayloadType,
                sequenceNumber: seq, timestamp: ts, ssrc: 6)
            header.encode(into: &data)
            data.append(au)
            seq &+= 1
            return data
        }

        XCTAssertEqual(
            downlink.currentJitterTargetDepth, VoiceReceiveDecisions.initialJitterTargetDepth)

        // 5 s of sustained ~100 ms deviation (RTP steps alternate 0 and 9600
        // samples against a steady 20 ms arrival cadence): the sweep deepens
        // the recommended queue one step per second.
        var now = ms(1000)
        for i in 0..<250 {
            downlink.ingest(packet(tsStep: i % 2 == 0 ? 0 : 9600), nowNs: now)
            now += ms(20)
        }
        let noisyTarget = downlink.currentJitterTargetDepth
        XCTAssertGreaterThanOrEqual(noisyTarget, 5, "sustained jitter must deepen the target")

        // 7 s of a perfectly paced stream: the estimator decays and the
        // target steps back down to its floor.
        for _ in 0..<350 {
            downlink.ingest(packet(tsStep: 960), nowNs: now)
            now += ms(20)
        }
        XCTAssertEqual(downlink.currentJitterTargetDepth, 2, "a calm stream must decay to the floor")
    }

    func testSystemAudioGapsAreNotConcealed() throws {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onPCM = { _, _ in heard += 1 }
        let encoder = try OpusVoiceEncoder(application: .audio)
        let packetizer = AudioRTPPacketizer(
            ssrc: RTPHeader.systemAudioSSRC, payloadType: RTPHeader.systemAudioPayloadType)
        var packets: [Data] = []
        for _ in 0..<6 {
            if let au = try encoder.encode(pcm: [Float](repeating: 0.15, count: 960)) {
                packets.append(packetizer.packetize(au: au))
            }
        }
        try XCTSkipIf(packets.count < 6, "Opus encoder produced no usable output on this host")

        let base = ms(1000)
        for (index, packet) in packets.enumerated() where !(2...3).contains(index) {
            downlink.ingest(packet, nowNs: base + ms(20 * index))
        }
        XCTAssertEqual(heard, 4, "system audio decodes straight through")
        XCTAssertEqual(downlink.concealedFrameCount, 0, "PT 99 must skip the voice concealment path")
        XCTAssertEqual(downlink.discontinuityCount, 0)
    }

    func testFadeToSilenceRampsMonotonicallyToZero() {
        var samples = [Float](repeating: 1, count: 8)
        VoiceDownlink.fadeToSilence(&samples)
        for i in 1..<samples.count {
            XCTAssertLessThan(samples[i], samples[i - 1], "the ramp must decrease monotonically")
        }
        XCTAssertEqual(samples.last, 0)
    }

    func testApplyFadeInRampsTheLeadingEdgeOnly() {
        var samples = [Float](repeating: 1, count: 960)
        VoiceDownlink.applyFadeIn(&samples)
        XCTAssertEqual(samples[0], 1.0 / 64.0, accuracy: 1e-6)
        XCTAssertEqual(samples[63], 1.0, accuracy: 1e-6)
        for i in 1..<64 {
            XCTAssertGreaterThan(samples[i], samples[i - 1], "the ramp must increase monotonically")
        }
        XCTAssertTrue(samples[64...].allSatisfy { $0 == 1.0 }, "everything past the ramp is untouched")
    }
}

/// A minimal lock box, so the capture-thread tests can read what the pump
/// wrote without tripping strict concurrency.
private final class Mutexish<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ initial: T) { storage = initial }
    var value: T { lock.withLock { storage } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}

/// The sharer's pairing: speak under the reserved SSRC, hear the viewers.
final class SharerVoiceTests: XCTestCase {
    private final class ManualMic: MicrophoneCapturing, @unchecked Sendable {
        var onPCM: (([Float], AudioInputFormat) -> Void)?
        var onStopped: ((Error?) -> Void)?
        private(set) var stopCount = 0
        func start() throws {}
        func stop() { stopCount += 1 }
        func feedFrame(count: Int = 1) {
            for _ in 0..<count {
                onPCM?((0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }, .wire)
            }
        }
    }

    /// The one thing a host must not be able to get wrong, and the reason the
    /// SSRC is not a parameter: viewers key their Opus decoders on it.
    func testSharerSpeaksUnderTheReservedSSRCAndStartsMuted() throws {
        let mic = ManualMic()
        var sent: [Data] = []
        let voice = try SharerVoice(
            microphone: mic, encoder: OpusVoiceEncoder(), send: { sent.append($0) })

        mic.feedFrame(count: 3)
        XCTAssertTrue(sent.isEmpty, "starting a share must not put somebody on the air")

        voice.isMuted = false
        mic.feedFrame()
        let header = try XCTUnwrap(RTPHeader.decode(from: sent[0])?.0)
        XCTAssertEqual(header.ssrc, RTPHeader.sharerVoiceSSRC)
        XCTAssertEqual(header.payloadType, RTPHeader.voicePayloadType)
    }

    func testViewerVoiceIsDecodedPerSSRC() throws {
        let voice = try SharerVoice(
            microphone: ManualMic(), encoder: OpusVoiceEncoder(), send: { _ in })
        var heard: [UInt32] = []
        voice.onRemotePCM = { ssrc, pcm in
            XCTAssertEqual(pcm.count, 960)
            heard.append(ssrc)
        }
        let encoder = try OpusVoiceEncoder()
        let au = try XCTUnwrap(
            encoder.encode(pcm: (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }))
        // Viewer SSRCs start at 2 — 0 is the sharer, 1 is system audio.
        for ssrc in [UInt32(2), 3] {
            let packetizer = AudioRTPPacketizer(
                ssrc: ssrc, payloadType: RTPHeader.voicePayloadType)
            voice.receive(packetizer.packetize(au: au))
        }
        XCTAssertEqual(heard, [2, 3])
        XCTAssertEqual(voice.voiceCount, 2)
    }

    /// An open capture device after Stop Sharing keeps the OS microphone
    /// indicator lit, which reads to everyone in the room as "still recording".
    func testStopReleasesTheDeviceAndForgetsTheViewers() throws {
        let mic = ManualMic()
        let voice = try SharerVoice(
            microphone: mic, encoder: OpusVoiceEncoder(), send: { _ in })
        let encoder = try OpusVoiceEncoder()
        let au = try XCTUnwrap(
            encoder.encode(pcm: (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }))
        let packetizer = AudioRTPPacketizer(ssrc: 2, payloadType: RTPHeader.voicePayloadType)
        voice.receive(packetizer.packetize(au: au))
        XCTAssertEqual(voice.voiceCount, 1)

        voice.stop()
        XCTAssertEqual(mic.stopCount, 1)
        XCTAssertEqual(voice.voiceCount, 0)
    }
}
