import Foundation

/// Sums the voices that land in the same 20 ms playout slot into one frame.
///
/// Every receive path decodes one Opus stream per SSRC and hands the result to
/// a single playback queue — `MicCapture`'s voice player node on macOS, the one
/// `AudioSink` the GTK and WinUI hosts own. A queue plays what it is given in
/// the order it is given, so with two remote voices (a sharer hearing two
/// viewers; a viewer hearing the sharer plus another viewer's relayed voice)
/// their 20 ms frames were queued alternately and played *in turn*: 20 ms of
/// A, 20 ms of B, 20 ms of A. Time-multiplexing, not summation — it sounds
/// garbled and chopped, and the doubled queue depth also trips the playback
/// overrun cap so frames get dropped on top. This is the missing sum.
///
/// The rule is arrival-driven and needs no timer: a frame opens a slot, frames
/// from *other* SSRCs that arrive within `slotNs` of the opening are summed
/// into it, and the slot closes — emitting one mixed frame — when either the
/// same SSRC speaks again (its next frame is by definition the next 20 ms) or
/// the window elapses. Frames of one SSRC are therefore never summed with
/// each other, whatever their timing, which is what keeps a concealment burst
/// (several frames of one SSRC in one instant) sequential.
///
/// A single live voice passes straight through, unheld and unchanged: there is
/// nothing to sum it with, and holding it for a slot-mate that will never come
/// would add 20 ms of latency to every one-to-one call. A voice counts as live
/// for `liveWindowNs` after its last frame, so a lost packet does not flip the
/// mixer's mode, while a peer who muted or left stops holding the other's
/// frames within a fraction of a second. The one transition cost is that the
/// slot opened while a second voice was live is flushed when the mixer drops
/// back to one voice — never dropped, since it is real audio.
///
/// The sum is clamped to [-1, 1] only when it actually is a sum; a frame that
/// passed through alone is emitted byte-identical, so the single-SSRC path is
/// exactly what it was before mixing existed.
///
/// A value type with no clock and no lock: the caller threads `nowNs` through
/// (the same arrival clock the gap and jitter decisions read) and confines the
/// value the way it confines its per-SSRC state — the macOS `VoiceChannel` on
/// its queue, `VoiceDownlink` under its lock.
public struct VoiceMixer: Sendable {
    /// One playout slot: an Opus frame's 20 ms. Frames from different SSRCs
    /// arriving within this much of a slot's opening are summed into it.
    public static let slotNs: UInt64 = 20_000_000

    /// How long after its last frame a voice still counts as live. Ten slots:
    /// well past a concealable loss burst, well short of anything a person
    /// notices as the mixer drops back to pass-through after a peer goes quiet.
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

        // Forget voices that have gone quiet, then record this one. A stamp
        // ahead of `nowNs` (clock skew) wraps under `&-` and is dropped too,
        // which only ever costs one transition.
        lastArrivalNs = lastArrivalNs.filter { nowNs &- $0.value <= Self.liveWindowNs }
        lastArrivalNs[ssrc] = nowNs

        // One voice: nothing to sum with. Flush whatever a departed slot-mate
        // left held, then pass this frame through untouched.
        if lastArrivalNs.count == 1 {
            if let held = open {
                out.append(held.finished())
                open = nil
            }
            out.append(samples)
            return out
        }

        // Several voices: accumulate per slot. The slot closes when its
        // opener (or any contributor) speaks again — that frame is the next
        // 20 ms, never this one — or when the window has elapsed.
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
