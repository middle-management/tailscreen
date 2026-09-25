import Foundation

/// Sums the voices that land in the same 20 ms playout slot into one frame.
///
/// Each receive path decodes one Opus stream per SSRC into a single playback
/// queue, which plays what it's given in order — so two remote voices queued
/// separately play in alternating 20 ms turns (time-multiplexed, not summed),
/// sounding garbled and doubling queue depth into overrun drops. This is the
/// missing sum.
///
/// Arrival-driven, no timer: a frame opens a slot, other SSRCs' frames
/// arriving within `slotNs` sum into it, and the slot closes (emitting one
/// mixed frame) when its opener speaks again or the window elapses. Frames of
/// one SSRC are never summed with each other, which keeps a concealment burst
/// sequential.
///
/// A single live voice passes through unheld — holding it for a slot-mate
/// that never comes would add 20 ms latency to every one-to-one call. A voice
/// counts live for `liveWindowNs` after its last frame, so one lost packet
/// doesn't flip modes, but a departed peer stops holding frames quickly. A
/// slot open when the mixer drops back to one voice is flushed, not dropped.
///
/// The sum is clamped to [-1, 1] only when it's an actual sum, so a lone
/// passed-through frame is byte-identical to pre-mixing behaviour.
///
/// A value type with no clock and no lock: the caller threads `nowNs` through
/// and confines the value itself (macOS `VoiceChannel` on its queue,
/// `VoiceDownlink` under its lock).
public struct VoiceMixer: Sendable {
    /// One playout slot: an Opus frame's 20 ms. Frames from different SSRCs
    /// arriving within this much of a slot's opening are summed into it.
    public static let slotNs: UInt64 = 20_000_000

    /// How long after its last frame a voice still counts as live. Ten
    /// slots: past a concealable loss burst, short of anything noticeable
    /// when the mixer drops back to pass-through.
    public static let liveWindowNs: UInt64 = 10 * slotNs

    /// One open slot: the running sum, when it opened, and who is in it.
    private struct Slot {
        var sum: [Float]
        var openedNs: UInt64
        var contributors: Set<UInt32>

        mutating func mix(_ samples: [Float]) {
            if samples.count > sum.count {
                sum.append(contentsOf: repeatElement(0, count: samples.count - sum.count))
            }
            for i in samples.indices { sum[i] += samples[i] }
        }

        /// The frame to play. Clamped only when it is a sum, so a frame that
        /// sat in the slot alone leaves exactly as it arrived.
        func finished() -> [Float] {
            guard contributors.count > 1 else { return sum }
            var mixed = sum
            _ = VoiceReceiveDecisions.clampToUnitRange(&mixed)
            return mixed
        }
    }

    /// Arrival clock of each voice's last frame; pruned past `liveWindowNs`.
    private var lastArrivalNs: [UInt32: UInt64] = [:]
    private var open: Slot?

    public init() {}

    /// Number of voices heard within `liveWindowNs` of the last `add`. The
    /// mixer passes frames through unheld while this is 1. Test visibility.
    public var liveVoiceCount: Int { lastArrivalNs.count }

    /// Feed one decoded (or concealed) frame of one voice. Returns the frames
    /// that are ready to play, in playout order — usually none or one; two
    /// when a held slot is flushed ahead of a pass-through frame.
    ///
    /// - Parameter nowNs: the frame's arrival on the caller's monotonic clock.
    public mutating func add(ssrc: UInt32, samples: [Float], nowNs: UInt64) -> [[Float]] {
        var out: [[Float]] = []

        // Forget voices that have gone quiet. A stamp ahead of `nowNs` (clock skew) is dropped too.
        lastArrivalNs = lastArrivalNs.filter { nowNs &- $0.value <= Self.liveWindowNs }
        lastArrivalNs[ssrc] = nowNs

        // One voice: flush whatever a departed slot-mate left held, then pass through untouched.
        if lastArrivalNs.count == 1 {
            if let held = open {
                out.append(held.finished())
                open = nil
            }
            out.append(samples)
            return out
        }

        // Several voices: accumulate per slot, closing when a contributor speaks again or the window elapses.
        if var slot = open {
            let closed = slot.contributors.contains(ssrc) || nowNs &- slot.openedNs >= Self.slotNs
            if closed {
                out.append(slot.finished())
                open = Slot(sum: samples, openedNs: nowNs, contributors: [ssrc])
            } else {
                slot.mix(samples)
                slot.contributors.insert(ssrc)
                open = slot
            }
        } else {
            open = Slot(sum: samples, openedNs: nowNs, contributors: [ssrc])
        }
        return out
    }

    /// Forget every voice and drop the open slot — a new session. What was
    /// held belongs to the session that ended, so it is not returned.
    public mutating func reset() {
        lastArrivalNs.removeAll()
        open = nil
    }
}
