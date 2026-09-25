import Foundation
import XCTest

@testable import TailscreenAudio
@testable import TailscreenProtocol

/// The voice path both endpoints share: the capture thread that pumps a
/// blocking device, the uplink turning mic buffers into RTP, the downlink
/// turning RTP back into PCM. Driven through fakes rather than a device —
/// none of this is observable on a machine with a real microphone.
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
        var failWith: Error?
        private(set) var closeCount = 0

        init(format: AudioInputFormat = .wire, buffers: [[Float]] = []) {
            self.inputFormat = format
            self.queued = buffers
        }

        struct Closed: Error {}
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
            // Nothing queued: park like a real device, until closed.
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

    /// A buffer captured just before `stop()` must not land just after, on a
    /// host that already tore its encoder down. Asserted by timing (stopping
    /// during a slow delivery must block until it finishes) rather than
    /// watching for a stray delivery — a check-then-call implementation
    /// races a window too narrow for the latter to reliably catch.
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

    /// A read that fails because we closed the device is the stop we asked
    /// for, not an error to surface as "your microphone disconnected".
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

    /// A glitch resets the resampler's carried neighbour but must NOT drop
    /// the framer's carry — those are real samples, and discarding them
    /// turns one device hole into two.
    func testDiscontinuityKeepsCapturedAudioButResetsInterpolation() throws {
        let pipeline = MicrophonePipeline(encoder: try OpusVoiceEncoder())
        var emitted = 0
        pipeline.onAccessUnit = { _ in emitted += 1 }

        // 500 samples: less than a 960-sample frame, sits in the framer's carry.
        pipeline.ingest(Array(repeating: 0.1, count: 500), format: .wire)
        XCTAssertEqual(emitted, 0)

        pipeline.noteDiscontinuity()

        // 460 more completes one frame — but only if the carry survived.
        pipeline.ingest(Array(repeating: 0.1, count: 460), format: .wire)
        XCTAssertEqual(emitted, 1, "noteDiscontinuity discarded audio it should have kept")
    }

    // MARK: - VoiceUplink

    /// No thread, so delivery is deterministic.
    private final class ManualMic: MicrophoneCapturing, @unchecked Sendable {
        var onPCM: (([Float], AudioInputFormat) -> Void)?
        var onStopped: ((Error?) -> Void)?
        private(set) var started = false
        private(set) var stopCount = 0
        func start() throws { started = true }
        func stop() { stopCount += 1 }

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

    /// Mute is a privacy guarantee, so it's asserted on the wire, not a flag.
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

    /// A different SSRC is a different stream — continuing the old sequence
    /// numbering would hand the receiver an apparent jump.
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

    /// One decoder per SSRC, but ONE frame per playout slot: three voices
    /// speaking at once come out as a single summed frame, not three.
    func testDownlinkDecodesEachSSRCIndependentlyAndMixesTheSlot() throws {
        let downlink = VoiceDownlink()
        var heard: [[Float]] = []
        downlink.onMixedPCM = { pcm in heard.append(pcm) }

        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))

        let now = ms(1000)
        // One packetizer per SSRC so a second packet continues its sequence.
        let zero = AudioRTPPacketizer(ssrc: 0, payloadType: RTPHeader.voicePayloadType)
        let one = AudioRTPPacketizer(ssrc: 1, payloadType: RTPHeader.voicePayloadType)
        let nine = AudioRTPPacketizer(ssrc: 9, payloadType: RTPHeader.voicePayloadType)
        for packetizer in [zero, one, nine] {
            downlink.ingest(packetizer.packetize(au: au), nowNs: now)
        }
        XCTAssertEqual(downlink.voiceCount, 3, "each SSRC gets its own decoder")
        // First voice passed straight through; the slot the second/third
        // joined is still open, closing on the next frame, not a timer.
        XCTAssertEqual(heard.count, 1, "three voices in one slot must not emit three frames")
        XCTAssertEqual(heard[0].count, 960)

        // The next frame of voice 1 closes the slot: sum of 1 and 9, double
        // for two identical decodes.
        downlink.ingest(one.packetize(au: au), nowNs: now + ms(20))
        XCTAssertEqual(heard.count, 2)
        for i in stride(from: 0, to: 960, by: 97) {
            XCTAssertEqual(heard[1][i], 2 * heard[0][i], accuracy: 1e-6, "slot frame must be the SUM")
        }
    }

    /// End-to-end with real Opus packets: two viewers talking over each
    /// other must reach the host as one frame per 20ms, not two interleaved
    /// 50Hz streams.
    func testTwoVoicesInTheSameSlotAreSummedIntoOneFrame() throws {
        let frames = 10
        let a = try voicePackets(count: frames, ssrc: 2)
        let b = try voicePackets(count: frames, ssrc: 3)
        try XCTSkipIf(a.count < frames || b.count < frames, "Opus encoder produced no usable output on this host")

        func solo(_ packets: [Data]) -> [[Float]] {
            let downlink = VoiceDownlink()
            var heard: [[Float]] = []
            downlink.onMixedPCM = { heard.append($0) }
            for (i, packet) in packets.enumerated() { downlink.ingest(packet, nowNs: ms(1000 + 20 * i)) }
            return heard
        }
        let soloA = solo(a)
        let soloB = solo(b)
        XCTAssertEqual(soloA.count, frames, "a lone voice is unchanged: one frame in, one frame out")
        XCTAssertEqual(soloB.count, frames)

        // B runs 5 ms behind A, the way two peers' clocks do.
        let downlink = VoiceDownlink()
        var heard: [[Float]] = []
        downlink.onMixedPCM = { heard.append($0) }
        for i in 0..<frames {
            downlink.ingest(a[i], nowNs: ms(1000 + 20 * i))
            downlink.ingest(b[i], nowNs: ms(1005 + 20 * i))
        }
        XCTAssertLessThan(heard.count, 2 * frames, "two voices must not double the frame rate")
        XCTAssertEqual(heard.count, frames, "one frame per 20 ms slot, whoever spoke in it")

        // Each slot after the first is opened by B's frame k, joined by A's
        // frame k+1, released when B's next frame arrives.
        XCTAssertEqual(heard[0], soloA[0], "a frame that passes through alone is byte-identical")
        for k in 0..<(frames - 1) {
            let mixed = heard[k + 1]
            XCTAssertEqual(mixed.count, 960)
            for i in stride(from: 0, to: 960, by: 61) {
                let expected = max(-1, min(1, soloA[k + 1][i] + soloB[k][i]))
                XCTAssertEqual(mixed[i], expected, accuracy: 1e-6, "slot \(k + 1) is not the sum of its two voices")
            }
        }
        XCTAssertEqual(downlink.voiceCount, 2, "mixing must not collapse the per-SSRC decoders")
    }

    func testGarbageIsDroppedWithoutAllocatingADecoder() {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onMixedPCM = { _ in heard += 1 }
        downlink.ingest(Data())
        downlink.ingest(Data([0xFF, 0x00, 0x01]))
        XCTAssertEqual(heard, 0)
        XCTAssertEqual(downlink.voiceCount, 0)
    }

    /// SSRC is a field in a network datagram — an unbounded decoder map is
    /// a remote allocation primitive.
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

    /// Eviction takes the quietest stream, never a participant still talking.
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
        // Per-stream, not just count: catches a policy that drops whoever's
        // currently talking while the bound still holds.
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

    /// `reset()` genuinely races `ingest` in production: `SharerVoice.stop()`
    /// runs while the server still delivers inbound audio (`onAudioReceived`'s
    /// contract forbids detaching mid-share). Passing here is necessary, not
    /// sufficient — it's the `--sanitize=thread` leg that reads the accesses.
    func testResetIsSafeAgainstConcurrentIngest() throws {
        let downlink = VoiceDownlink()
        downlink.onMixedPCM = { _ in }
        let encoder = try OpusVoiceEncoder()
        let tone = (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let au = try XCTUnwrap(encoder.encode(pcm: tone))
        let packets = (0..<8).map { ssrc in
            AudioRTPPacketizer(ssrc: UInt32(ssrc), payloadType: RTPHeader.voicePayloadType)
                .packetize(au: au)
        }

        let ingesting = expectation(description: "ingest loop finished")
        let resetting = expectation(description: "reset loop finished")
        DispatchQueue.global().async {
            for _ in 0..<200 { for packet in packets { downlink.ingest(packet) } }
            ingesting.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<400 { downlink.reset() }
            resetting.fulfill()
        }
        wait(for: [ingesting, resetting], timeout: 60)

        XCTAssertLessThanOrEqual(downlink.voiceCount, packets.count)
        downlink.reset()
        XCTAssertEqual(downlink.voiceCount, 0)
    }

    // MARK: - VoiceDownlink loss resilience

    /// Milliseconds → the nanosecond clock `ingest` takes.
    private func ms(_ value: Int) -> UInt64 { UInt64(value) * 1_000_000 }

    /// Encodes `count` tone frames under one sequence space, so tests can
    /// feed subsets and open real gaps.
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
        downlink.onMixedPCM = { pcm in heard.append(pcm) }
        let packets = try voicePackets(count: 10, ssrc: 7)
        try XCTSkipIf(packets.count < 10, "Opus encoder produced no usable output on this host")

        let base = ms(1000)
        for i in 0..<3 { downlink.ingest(packets[i], nowNs: base + ms(20 * i)) }
        XCTAssertEqual(heard.count, 3)

        // Packets 3...6 lost. Concealment caps at playbackSlackBuffers - 1 == 2 frames.
        downlink.ingest(packets[7], nowNs: base + ms(140))
        XCTAssertEqual(heard.count, 6, "2 concealment frames + the decoded packet")
        XCTAssertEqual(downlink.concealedFrameCount, 2)
        XCTAssertEqual(downlink.discontinuityCount, 0, "a concealable gap is not a resync")

        let firstConcealed = heard[3]
        XCTAssertEqual(firstConcealed.count, 960, "PLC must synthesize a whole 20 ms frame")
        let rms = sqrt(firstConcealed.reduce(0) { $0 + $1 * $1 } / Float(firstConcealed.count))
        XCTAssertGreaterThan(rms, 0.01, "Opus PLC should extrapolate the tone, not emit silence")
        XCTAssertEqual(heard[4].last, 0, "a capped gap's last concealment frame must end at silence")

        XCTAssertLessThan(abs(heard[5][0]), 0.05, "the resume frame must start from (near) silence")
        XCTAssertGreaterThan(heard[5].map { abs($0) }.max() ?? 0, 0.05, "and still carry audio")

        downlink.ingest(packets[8], nowNs: base + ms(160))
        downlink.ingest(packets[9], nowNs: base + ms(180))
        XCTAssertEqual(heard.count, 8)
        XCTAssertEqual(downlink.concealedFrameCount, 2)
    }

    func testLatePacketAfterConcealmentIsDroppedStale() throws {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onMixedPCM = { _ in heard += 1 }
        let packets = try voicePackets(count: 6, ssrc: 9)
        try XCTSkipIf(packets.count < 6, "Opus encoder produced no usable output on this host")

        let base = ms(1000)
        downlink.ingest(packets[0], nowNs: base)
        downlink.ingest(packets[1], nowNs: base + ms(20))
        // Packet 2 lost; 3 arrives → one PLC frame + the decoded packet.
        downlink.ingest(packets[3], nowNs: base + ms(60))
        XCTAssertEqual(heard, 4)
        XCTAssertEqual(downlink.concealedFrameCount, 1)

        // The lost packet straggles in — already played as concealment.
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
        downlink.onMixedPCM = { _ in heard += 1 }
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
        downlink.onMixedPCM = { _ in heard += 1 }
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

        // Past the 5s cooldown the retry is allowed and clears the record.
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

        // SSRC 3 keeps talking; SSRC 2 stays silent past the 10s idle window.
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

        // Hand-built RTP so timestamps carry the deviation the arrival clock can't.
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

        // 5s of sustained ~100ms deviation: the sweep deepens the queue
        // target one step per second.
        var now = ms(1000)
        for i in 0..<250 {
            downlink.ingest(packet(tsStep: i % 2 == 0 ? 0 : 9600), nowNs: now)
            now += ms(20)
        }
        let noisyTarget = downlink.currentJitterTargetDepth
        XCTAssertGreaterThanOrEqual(noisyTarget, 5, "sustained jitter must deepen the target")

        // A perfectly paced stream decays the estimator back to the floor.
        for _ in 0..<350 {
            downlink.ingest(packet(tsStep: 960), nowNs: now)
            now += ms(20)
        }
        XCTAssertEqual(downlink.currentJitterTargetDepth, 2, "a calm stream must decay to the floor")
    }

    func testSystemAudioGapsAreNotConcealed() throws {
        let downlink = VoiceDownlink()
        var heard = 0
        downlink.onMixedPCM = { _ in heard += 1 }
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

/// A minimal lock box so capture-thread tests can read pump output without
/// tripping strict concurrency.
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

    /// The SSRC is not a parameter because viewers key their Opus decoders on it.
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

    /// Two viewers, two decoders, one frame per slot to the sharer's output.
    func testViewerVoicesAreDecodedPerSSRCAndMixedPerSlot() throws {
        let voice = try SharerVoice(
            microphone: ManualMic(), encoder: OpusVoiceEncoder(), send: { _ in })
        var heard: [[Float]] = []
        voice.onRemotePCM = { pcm in heard.append(pcm) }
        let encoder = try OpusVoiceEncoder()
        let au = try XCTUnwrap(
            encoder.encode(pcm: (0..<960).map { Float(sin(Double($0) * 0.05)) * 0.4 }))
        // Viewer SSRCs start at 2 — 0 is the sharer, 1 is system audio.
        let two = AudioRTPPacketizer(ssrc: 2, payloadType: RTPHeader.voicePayloadType)
        let three = AudioRTPPacketizer(ssrc: 3, payloadType: RTPHeader.voicePayloadType)
        let base: UInt64 = 1_000_000_000
        voice.receive(two.packetize(au: au), nowNs: base)
        voice.receive(three.packetize(au: au), nowNs: base + 2_000_000)
        voice.receive(two.packetize(au: au), nowNs: base + 20_000_000)
        voice.receive(three.packetize(au: au), nowNs: base + 22_000_000)
        XCTAssertEqual(voice.voiceCount, 2)
        XCTAssertEqual(heard.count, 2, "two voices in one slot must come out as one frame")
        XCTAssertTrue(heard.allSatisfy { $0.count == 960 })
    }

    /// An open capture device after Stop Sharing keeps the OS mic indicator
    /// lit — reads as "still recording" to everyone in the room.
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
