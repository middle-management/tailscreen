import Foundation

/// Pending-buffer bookkeeping for one player-node playback queue — macOS's
/// `MicCapture` keeps one per `AVAudioPlayerNode`, since it exposes no queue
/// depth of its own. Every playback decision hangs off this count: whether an
/// arrival overruns, whether the player is primed enough to start, whether a
/// drain-to-zero was an audible underrun. Pure and portable so these are
/// pinned with no audio engine (`PlaybackQueueAccountingTests`).
///
/// `reset()` is the rule this type exists to enforce: an engine can discard
/// queued buffers (voice-processing toggle, device change, self-stop)
/// without a completion firing, and bookkeeping that survives such a stop
/// drops every later arrival as an overrun — audio silently stops while
/// `overruns=` climbs in the stats. Each reset opens a new `generation` so an
/// in-flight completion from the old queue can't drive the fresh count
/// negative or record a bogus drain.
public struct PlaybackQueueAccounting: Equatable, Sendable {
    /// Buffers scheduled and not yet reported consumed.
    public private(set) var pending = 0
    /// Buffers scheduled since the last reset — the jitter-buffer priming
    /// counter. Playback starts only once this reaches the target depth.
    public private(set) var scheduledSinceReset = 0
    /// Playback-session marker. `consumed` ignores a completion from an
    /// earlier generation — its buffer was already discarded by the reset
    /// that opened the current one.
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

    /// Decide one arrival. The cap is `targetDepth + slack` — the jitter
    /// target plus headroom for a slightly-fast sender timer before latency
    /// is bounded by dropping. `.schedule` counts the buffer as pending; the
    /// host must schedule it and route completion to `consumed` with the
    /// current `generation`.
    public mutating func schedule(targetDepth: Int, slack: Int, playerIsPlaying: Bool) -> ScheduleVerdict {
        if pending >= targetDepth + slack { return .drop }
        pending += 1
        scheduledSinceReset += 1
        return .schedule(kickPlayback: !playerIsPlaying && scheduledSinceReset >= targetDepth)
    }

    /// One scheduleBuffer completion. Returns false and changes nothing for
    /// an earlier `generation` — its queue was already emptied by a reset.
    /// Otherwise decrements, and records a drain if the queue hits zero
    /// while the player is still running (a possible audible starve).
    @discardableResult
    public mutating func consumed(generation: Int, playerIsPlaying: Bool, nowNs: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        pending = max(pending - 1, 0)
        if pending == 0, playerIsPlaying {
            drainedAtNs = nowNs
        }
        return true
    }

    /// The underrun verdict for a pending drain, consumed as read: a drain
    /// followed by this arrival within the resume window is an audible
    /// underrun, a long silence is a benign stop (mute, end of stream).
    public mutating func takeStarveVerdict(nowNs: UInt64) -> Bool {
        guard drainedAtNs != 0 else { return false }
        let starved = VoiceReceiveDecisions.isStarveResume(drainedAtNs: drainedAtNs, nowNs: nowNs)
        drainedAtNs = 0
        return starved
    }

    /// The queue is known to be empty (host or engine about to stop).
    /// Zeroes the counts, forgets any pending drain, and opens a new
    /// generation to orphan late completions from discarded buffers.
    /// Returns how many buffers were healed, for the host's log line.
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
