import Foundation

/// Pending-buffer bookkeeping for one player-node playback queue — the
/// macOS `MicCapture` keeps one per `AVAudioPlayerNode` (voice, system
/// audio). `AVAudioPlayerNode` exposes no queue depth, so the host counts
/// what it scheduled and what the node reported consumed, and every
/// decision the playback side makes hangs off that count: whether an
/// arrival is dropped as an overrun, whether the player has been primed
/// deep enough to start, and whether a drain-to-zero was an audible
/// underrun. Pure and portable so those decisions can be pinned with no
/// audio engine (`PlaybackQueueAccountingTests`).
///
/// The one rule this type exists to enforce is `reset()`. A completion is
/// the *only* way `pending` comes down, and an audio engine can discard
/// its players' queued buffers without invoking one — stopping the engine
/// to toggle voice processing, an output-device change, or the engine
/// stopping itself on a configuration change all do. Bookkeeping that
/// survives such a stop is then wrong by the discarded count, and once it
/// is wrong by the whole cap, `schedule` drops every later arrival as an
/// overrun: inbound audio is silent for the rest of the session while the
/// stats line shows `overruns=` climbing. So the host resets at every
/// point where the queue is known to be empty, and each reset opens a new
/// `generation` so a completion still in flight from the old queue cannot
/// drive the fresh count negative or record a bogus drain.
public struct PlaybackQueueAccounting: Equatable, Sendable {
    /// Buffers scheduled and not yet reported consumed.
    public private(set) var pending = 0
    /// Buffers scheduled since the last reset — the jitter-buffer priming
    /// counter. Playback is kicked off only once this reaches the target
    /// depth, so the player has runway and does not underrun on the first
    /// arrival hiccup.
    public private(set) var scheduledSinceReset = 0
    /// Playback-session marker. Every completion captures the generation
    /// it was scheduled under; `consumed` ignores one from an earlier
    /// generation, because the buffer it reports on was discarded by the
    /// reset that opened the current one.
    public private(set) var generation = 0
    /// Clock reading when the queue last drained to zero while the player
    /// was running; 0 = no drain pending. Whether that drain was an audible
    /// underrun is decided by the next arrival (`takeStarveVerdict`).
    public private(set) var drainedAtNs: UInt64 = 0

    public init() {}

    /// What `schedule` decided for one arrival.
    public enum ScheduleVerdict: Equatable, Sendable {
        /// The queue is at its cap — the clock-drift backstop. The arrival
        /// is dropped and counts as an overrun.
        case drop
        /// Schedule the buffer. `kickPlayback` is true when the player is
        /// idle and has now been primed to the target depth, so the host
        /// should call `play()` after scheduling.
        case schedule(kickPlayback: Bool)
    }

    /// Decide one arrival. The cap is `targetDepth + slack`: the adaptive
    /// jitter target plus the headroom the sender's slightly-fast timer is
    /// allowed to bank before a frame is dropped to keep latency bounded.
    /// A `.schedule` verdict counts the buffer as pending; the host must
    /// then schedule it and route its completion to `consumed` with the
    /// current `generation`.
    public mutating func schedule(targetDepth: Int, slack: Int, playerIsPlaying: Bool) -> ScheduleVerdict {
        if pending >= targetDepth + slack { return .drop }
        pending += 1
        scheduledSinceReset += 1
        return .schedule(kickPlayback: !playerIsPlaying && scheduledSinceReset >= targetDepth)
    }

    /// One scheduleBuffer completion. Returns false, and changes nothing,
    /// for a completion from an earlier `generation` — the buffer it names
    /// belonged to a queue a reset already emptied. Otherwise decrements,
    /// and records a drain when the queue hits zero while the player is
    /// still running (the possible audible starve).
    @discardableResult
    public mutating func consumed(generation: Int, playerIsPlaying: Bool, nowNs: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        pending = max(pending - 1, 0)
        if pending == 0, playerIsPlaying {
            drainedAtNs = nowNs
        }
        return true
    }

    /// The underrun verdict for a pending drain, consumed as it is read:
    /// `VoiceReceiveDecisions.isStarveResume` over `drainedAtNs`. A drain
    /// followed by this arrival within the resume window was an audible
    /// underrun; one followed by a long silence was a benign stop (mute,
    /// end of stream). Either way the drain is no longer pending.
    public mutating func takeStarveVerdict(nowNs: UInt64) -> Bool {
        guard drainedAtNs != 0 else { return false }
        let starved = VoiceReceiveDecisions.isStarveResume(drainedAtNs: drainedAtNs, nowNs: nowNs)
        drainedAtNs = 0
        return starved
    }

    /// The queue is known to be empty: the host is about to stop the
    /// player and engine, or the engine has stopped itself. Zeroes the
    /// count and the priming counter (the next session primes afresh),
    /// forgets any pending drain, and opens a new generation so the
    /// completions the discarded buffers may still fire are orphaned.
    /// Returns how many buffers were still counted as pending — what the
    /// reset healed, for the host's log line.
    @discardableResult
    public mutating func reset() -> Int {
        let healed = pending
        pending = 0
        scheduledSinceReset = 0
        drainedAtNs = 0
        generation += 1
        return healed
    }
}
