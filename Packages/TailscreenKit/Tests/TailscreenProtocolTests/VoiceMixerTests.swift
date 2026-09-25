import Foundation
import XCTest

@testable import TailscreenAudio

/// `VoiceMixer` — the per-slot sum between "one Opus decoder per SSRC" and
/// "one playback queue per host". With two remote voices, per-SSRC emission
/// decoded and delivered every frame correctly, but the host's queue played
/// them in turn (20ms of one, then the other) which sounded "garbled" — so
/// assertions here check the NUMBER of frames a slot produces and that their
/// SAMPLES are the sum, never just "was something emitted".
final class VoiceMixerTests: XCTestCase {
    private func ms(_ value: Int) -> UInt64 { UInt64(value) * 1_000_000 }

    private func frame(_ value: Float, count: Int = 960) -> [Float] {
        [Float](repeating: value, count: count)
    }

    // MARK: - One voice

    func testASingleVoicePassesThroughUnheldAndUnchanged() {
        var mixer = VoiceMixer()
        for k in 0..<10 {
            let samples = (0..<960).map { Float(sin(Double(k * 960 + $0) * 0.05)) * 0.4 }
            let out = mixer.add(ssrc: 7, samples: samples, nowNs: ms(1000 + 20 * k))
            XCTAssertEqual(out.count, 1, "frame \(k): one in, one out — a lone voice is never held")
            XCTAssertEqual(out[0], samples, "frame \(k): a lone voice must come out untouched")
        }
        XCTAssertEqual(mixer.liveVoiceCount, 1)
    }

    // MARK: - Two voices

    /// Two voices in one slot must produce ONE frame whose samples are the
    /// sum, not two frames for a queue to play one after the other.
    func testTwoVoicesInOneSlotBecomeOneSummedFrame() {
        var mixer = VoiceMixer()
        XCTAssertEqual(mixer.add(ssrc: 2, samples: frame(0.25), nowNs: ms(1000)), [frame(0.25)])
        // B arrives 5ms later: opens a slot, waits for A's next frame.
        XCTAssertEqual(mixer.add(ssrc: 3, samples: frame(0.5), nowNs: ms(1005)), [])
        XCTAssertEqual(mixer.liveVoiceCount, 2)
        XCTAssertEqual(mixer.add(ssrc: 2, samples: frame(0.125), nowNs: ms(1020)), [])
        let out = mixer.add(ssrc: 3, samples: frame(0.5), nowNs: ms(1025))
        XCTAssertEqual(out.count, 1, "one slot, one frame — not one per voice")
        XCTAssertEqual(out[0].count, 960)
        XCTAssertEqual(out[0], frame(0.625), "the slot's frame must be the SUM of its two voices")
    }

    /// Two voices at 50Hz each come out as 50 frames/sec, never 100 alternating.
    func testSteadyStateEmitsOneFrameForEveryTwoIn() {
        var mixer = VoiceMixer()
        var emitted: [[Float]] = []
        let frames = 50
        for k in 0..<frames {
            emitted += mixer.add(ssrc: 2, samples: frame(Float(k + 1) / 10000), nowNs: ms(1000 + 20 * k))
            emitted += mixer.add(ssrc: 3, samples: frame(Float(k + 1) / 1000), nowNs: ms(1004 + 20 * k))
        }
        XCTAssertEqual(emitted.count, frames, "one frame per 20 ms slot")
        // Frame 0: A alone. Frame k ≥ 1: B's (k-1)th summed with A's kth.
        XCTAssertEqual(emitted[0], frame(1 / 10000))
        for k in 1..<frames {
            let expected = Float(k + 1) / 10000 + Float(k) / 1000
            XCTAssertEqual(emitted[k][0], expected, accuracy: 1e-6, "slot \(k) is not the sum")
            XCTAssertEqual(emitted[k][959], expected, accuracy: 1e-6)
        }
    }

    func testTheSumIsClampedToUnitRange() {
        var mixer = VoiceMixer()
        _ = mixer.add(ssrc: 2, samples: frame(0.8), nowNs: ms(1000))
        _ = mixer.add(ssrc: 3, samples: frame(0.7), nowNs: ms(1005))
        _ = mixer.add(ssrc: 2, samples: frame(0.8), nowNs: ms(1020))
        let positive = mixer.add(ssrc: 3, samples: frame(-0.7), nowNs: ms(1025))
        XCTAssertEqual(positive, [frame(1.0)], "0.7 + 0.8 must clamp to 1")
        _ = mixer.add(ssrc: 2, samples: frame(-0.8), nowNs: ms(1040))
        let negative = mixer.add(ssrc: 3, samples: frame(0), nowNs: ms(1045))
        XCTAssertEqual(negative, [frame(-1.0)], "-0.7 + -0.8 must clamp to -1")
    }

    /// A concealment burst (several frames of one SSRC in one instant) must
    /// come out sequentially, never summed with itself.
    func testOneVoiceNeverSumsWithItself() {
        var mixer = VoiceMixer()
        _ = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1000))
        _ = mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1005))
        XCTAssertEqual(mixer.add(ssrc: 2, samples: frame(0.3), nowNs: ms(1020)), [])
        let second = mixer.add(ssrc: 2, samples: frame(0.4), nowNs: ms(1020))
        XCTAssertEqual(second, [frame(0.5)], "A's repeat closes the slot holding B + A's first frame")
        let third = mixer.add(ssrc: 2, samples: frame(0.6), nowNs: ms(1020))
        XCTAssertEqual(third, [frame(0.4)], "the burst's frames play one after another, unsummed")
    }

    /// A frame arriving more than 20ms after a slot opened is the next slot.
    func testFramesMoreThanASlotApartAreNotSummed() {
        var mixer = VoiceMixer()
        _ = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1000))
        XCTAssertEqual(mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1005)), [])
        let late = mixer.add(ssrc: 2, samples: frame(0.3), nowNs: ms(1030))  // 25ms after B
        XCTAssertEqual(late, [frame(0.2)], "B's frame plays alone, unclamped and unchanged")
        XCTAssertEqual(mixer.add(ssrc: 3, samples: frame(0.4), nowNs: ms(1045)), [])
        let next = mixer.add(ssrc: 2, samples: frame(0), nowNs: ms(1050))
        XCTAssertEqual(next.count, 1)
        assertFrame(next[0], equals: frame(0.7), "A's late frame + B's next")
    }

    func testThreeVoicesInOneSlotSumOnce() {
        var mixer = VoiceMixer()
        _ = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1000))
        XCTAssertEqual(mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1003)), [])
        XCTAssertEqual(mixer.add(ssrc: 4, samples: frame(0.3), nowNs: ms(1006)), [])
        XCTAssertEqual(mixer.add(ssrc: 2, samples: frame(0.4), nowNs: ms(1020)), [])
        XCTAssertEqual(mixer.liveVoiceCount, 3)
        let out = mixer.add(ssrc: 3, samples: frame(0), nowNs: ms(1023))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0][0], 0.9, accuracy: 1e-6, "B + C + A's next")
    }

    // MARK: - Leaving and returning

    /// A peer who mutes stops sending. Their slot-mate must not stay held
    /// one frame behind forever — once the quiet voice ages out of the live
    /// window, the mixer flushes the held frame rather than dropping it.
    func testAQuietVoiceStopsHoldingTheOtherAndNothingIsLost() {
        var mixer = VoiceMixer()
        var emitted: [[Float]] = []
        emitted += mixer.add(ssrc: 2, samples: frame(0.01), nowNs: ms(1000))
        emitted += mixer.add(ssrc: 3, samples: frame(0.1), nowNs: ms(1005))
        emitted += mixer.add(ssrc: 2, samples: frame(0.02), nowNs: ms(1020))
        emitted += mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1025))
        var fed = 4
        // A alone from here. Inside B's live window every A frame is held
        // one behind; the first frame past the window flushes it.
        var sawTheFlush = false
        for k in 2..<20 {
            let now = ms(1000 + 20 * k)
            let out = mixer.add(ssrc: 2, samples: frame(Float(k + 1) / 100), nowNs: now)
            fed += 1
            emitted += out
            let bStillLive = now &- ms(1025) <= VoiceMixer.liveWindowNs
            if k == 2 {
                XCTAssertEqual(out, [], "frame 2 joins the slot B's last frame opened")
            } else if bStillLive {
                XCTAssertEqual(out.count, 1, "frame \(k): held one behind while B counts as live")
                XCTAssertEqual(mixer.liveVoiceCount, 2)
            } else if !sawTheFlush {
                sawTheFlush = true
                XCTAssertEqual(out.count, 2, "frame \(k): the held frame flushes ahead of this one")
                XCTAssertEqual(out[1], frame(Float(k + 1) / 100), "and this one passes through as is")
                XCTAssertEqual(mixer.liveVoiceCount, 1, "B has been forgotten")
            } else {
                XCTAssertEqual(out.count, 1, "frame \(k): back to plain pass-through")
            }
        }
        XCTAssertTrue(sawTheFlush, "B must age out of the live window within the run")
        XCTAssertEqual(emitted.count, fed - 2, "no frame is dropped on the way back to one voice")
        assertFrame(emitted[1], equals: frame(0.12), "B's first + A's second")
        assertFrame(emitted[2], equals: frame(0.23), "B's second + A's third")
    }

    /// A lost packet must not flip the mixer to pass-through and back — the
    /// live window is wider than a concealable gap.
    func testALostPacketDoesNotFlipTheMode() {
        var mixer = VoiceMixer()
        _ = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1000))
        _ = mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1005))
        _ = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1020))
        _ = mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1025))
        let joined = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1040))
        XCTAssertEqual(joined, [], "joins the slot B's last frame opened")
        let stillHeld = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1060))
        XCTAssertEqual(stillHeld.count, 1, "A is still held one behind: B is live, just missing a frame")
        XCTAssertEqual(mixer.liveVoiceCount, 2)
        XCTAssertEqual(mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1065)), [])
        XCTAssertEqual(mixer.add(ssrc: 2, samples: frame(0), nowNs: ms(1080)), [frame(0.3)])
    }

    // MARK: - Edges

    /// Opus can hand back a short frame; the slot's frame is as long as its
    /// longest contributor, the rest being the longer voice alone.
    func testMismatchedFrameLengthsSumOverTheOverlap() {
        var mixer = VoiceMixer()
        _ = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1000))
        _ = mixer.add(ssrc: 3, samples: frame(0.2, count: 480), nowNs: ms(1005))
        _ = mixer.add(ssrc: 2, samples: frame(0.3), nowNs: ms(1020))
        let out = mixer.add(ssrc: 3, samples: frame(0), nowNs: ms(1025))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].count, 960, "as long as the longest contributor")
        XCTAssertEqual(out[0][0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[0][479], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[0][480], 0.3, accuracy: 1e-6, "past the short frame it is the long one alone")
        XCTAssertEqual(out[0][959], 0.3, accuracy: 1e-6)
    }

    /// A new session starts with nothing held from the previous one.
    func testResetForgetsTheVoicesAndDropsTheHeldSlot() {
        var mixer = VoiceMixer()
        _ = mixer.add(ssrc: 2, samples: frame(0.1), nowNs: ms(1000))
        _ = mixer.add(ssrc: 3, samples: frame(0.2), nowNs: ms(1005))
        XCTAssertEqual(mixer.liveVoiceCount, 2)
        mixer.reset()
        XCTAssertEqual(mixer.liveVoiceCount, 0)
        let out = mixer.add(ssrc: 9, samples: frame(0.4), nowNs: ms(1010))
        XCTAssertEqual(out, [frame(0.4)], "a fresh session's first voice passes straight through")
    }
}

/// Element-wise comparison for whole frames with a tolerance.
private func assertFrame(
    _ actual: [Float], equals expected: [Float], accuracy: Float = 1e-6, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, "frame length: \(message)", file: file, line: line)
    for (i, (a, e)) in zip(actual, expected).enumerated() where abs(a - e) > accuracy {
        XCTFail("sample \(i): \(a) != \(e) ± \(accuracy): \(message)", file: file, line: line)
        return
    }
}
