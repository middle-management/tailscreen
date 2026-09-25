import XCTest

@testable import TailscreenAudio

/// Pins `PlaybackQueueAccounting`, the pending-buffer bookkeeping behind
/// `MicCapture`'s two player nodes, so it can be checked with no audio engine.
///
/// Read `testResetHealsACountPinnedAtTheCap` first: without the reset, a
/// count pinned at the cap when the engine stops for VPIO never heals, and
/// every later arrival is dropped as an overrun for the rest of the session.
/// The generation keeps the reset safe against a completion the old queue
/// fires late.
final class PlaybackQueueAccountingTests: XCTestCase {
    private let target = 3
    private let slack = 3
    private let s: UInt64 = 1_000_000_000
    private typealias Verdict = PlaybackQueueAccounting.ScheduleVerdict

    /// Schedule `n` arrivals against an idle player, returning the verdicts.
    private func prime(_ q: inout PlaybackQueueAccounting, count n: Int, playing: Bool = false) -> [Verdict] {
        (0..<n).map { _ in q.schedule(targetDepth: target, slack: slack, playerIsPlaying: playing) }
    }

    // MARK: - The cap

    func testDropsAtTheCapAndCountsNothing() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: target + slack, playing: true)
        XCTAssertEqual(q.pending, target + slack)
        XCTAssertEqual(q.schedule(targetDepth: target, slack: slack, playerIsPlaying: true), .drop)
        XCTAssertEqual(q.pending, target + slack, "a dropped arrival is not pending")
        XCTAssertEqual(q.scheduledSinceReset, target + slack, "nor does it count toward priming")
    }

    func testCapFollowsTheAdaptiveTarget() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: target + slack, playing: true)
        XCTAssertEqual(q.schedule(targetDepth: target, slack: slack, playerIsPlaying: true), .drop)
        // Jitter target raised: the same depth is now under the cap.
        XCTAssertEqual(
            q.schedule(targetDepth: target + 1, slack: slack, playerIsPlaying: true),
            .schedule(kickPlayback: false))
    }

    // MARK: - Reset: the self-healing rule

    func testResetHealsACountPinnedAtTheCap() {
        var q = PlaybackQueueAccounting()
        // Queued to the cap as the local mic comes on and the engine stops for VPIO; nothing completes.
        _ = prime(&q, count: target + slack, playing: true)
        XCTAssertEqual(q.schedule(targetDepth: target, slack: slack, playerIsPlaying: true), .drop)

        let healed = q.reset()

        XCTAssertEqual(healed, target + slack, "the reset reports what it discarded")
        XCTAssertEqual(q.pending, 0)
        XCTAssertEqual(
            q.schedule(targetDepth: target, slack: slack, playerIsPlaying: false),
            .schedule(kickPlayback: false),
            "the first arrival after the restart is scheduled, not dropped")
    }

    func testResetOrphansCompletionsOfTheDiscardedQueue() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: 2, playing: true)
        let oldGeneration = q.generation
        q.reset()
        // AVAudioPlayerNode.stop() fires the discarded buffers' completions
        // after the reset; they must not touch the fresh count.
        XCTAssertFalse(q.consumed(generation: oldGeneration, playerIsPlaying: true, nowNs: s))
        XCTAssertFalse(q.consumed(generation: oldGeneration, playerIsPlaying: true, nowNs: s))
        XCTAssertEqual(q.pending, 0, "stale completions never drive the count negative")
        XCTAssertEqual(q.drainedAtNs, 0, "nor record a drain the new queue never had")

        // A buffer scheduled under the new generation still completes.
        _ = prime(&q, count: 1, playing: true)
        XCTAssertTrue(q.consumed(generation: q.generation, playerIsPlaying: true, nowNs: 2 * s))
        XCTAssertEqual(q.pending, 0)
    }

    func testResetRePrimesTheJitterBuffer() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: target)
        q.reset()
        // Kick waits for a full target depth again; a carried-over priming count must not fire it early.
        let verdicts = prime(&q, count: target)
        XCTAssertEqual(
            verdicts,
            [Verdict](repeating: .schedule(kickPlayback: false), count: target - 1)
                + [.schedule(kickPlayback: true)])
    }

    func testResetForgetsAPendingDrain() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: 1, playing: true)
        q.consumed(generation: q.generation, playerIsPlaying: true, nowNs: s)
        XCTAssertNotEqual(q.drainedAtNs, 0)
        q.reset()
        XCTAssertFalse(q.takeStarveVerdict(nowNs: s + 1), "a drain before the restart is not an underrun after it")
    }

    func testResetWithNothingPendingHealsNothing() {
        var q = PlaybackQueueAccounting()
        XCTAssertEqual(q.reset(), 0)
        XCTAssertEqual(q.generation, 1, "but still opens a new generation")
    }

    // MARK: - Priming and the kick

    func testKicksOnceTheTargetDepthIsQueued() {
        var q = PlaybackQueueAccounting()
        let verdicts = prime(&q, count: target + 1)
        XCTAssertEqual(verdicts[target - 2], .schedule(kickPlayback: false))
        XCTAssertEqual(verdicts[target - 1], .schedule(kickPlayback: true))
        // Already playing: not kicked again.
        XCTAssertEqual(
            q.schedule(targetDepth: target, slack: slack, playerIsPlaying: true),
            .schedule(kickPlayback: false))
    }

    func testKicksAgainWhenThePlayerStoppedOnItsOwn() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: target)
        // Primed once already: an idle player restarts on the next arrival, not after a whole new target depth.
        XCTAssertEqual(
            q.schedule(targetDepth: target, slack: slack, playerIsPlaying: false),
            .schedule(kickPlayback: true))
    }

    // MARK: - Completions and the underrun verdict

    func testCompletionDecrementsAndRecordsADrainWhilePlaying() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: 2, playing: true)
        XCTAssertTrue(q.consumed(generation: q.generation, playerIsPlaying: true, nowNs: s))
        XCTAssertEqual(q.pending, 1)
        XCTAssertEqual(q.drainedAtNs, 0, "not drained yet")
        XCTAssertTrue(q.consumed(generation: q.generation, playerIsPlaying: true, nowNs: 2 * s))
        XCTAssertEqual(q.pending, 0)
        XCTAssertEqual(q.drainedAtNs, 2 * s)
    }

    func testDrainWithThePlayerStoppedIsNotRecorded() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: 1)
        q.consumed(generation: q.generation, playerIsPlaying: false, nowNs: s)
        XCTAssertEqual(q.drainedAtNs, 0, "a queue emptied by stop() is not a starve")
    }

    func testStarveVerdictIsTakenOnce() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: 1, playing: true)
        q.consumed(generation: q.generation, playerIsPlaying: true, nowNs: s)
        XCTAssertTrue(q.takeStarveVerdict(nowNs: s + 100_000_000), "resume within the window: an underrun")
        XCTAssertFalse(q.takeStarveVerdict(nowNs: s + 200_000_000), "the same drain is not counted twice")
    }

    func testLongSilenceAfterADrainIsBenign() {
        var q = PlaybackQueueAccounting()
        _ = prime(&q, count: 1, playing: true)
        q.consumed(generation: q.generation, playerIsPlaying: true, nowNs: s)
        XCTAssertFalse(q.takeStarveVerdict(nowNs: 5 * s), "mute / end of stream, not a starve")
        XCTAssertEqual(q.drainedAtNs, 0, "and the drain is no longer pending either way")
    }

    func testNoPendingDrainIsNoUnderrun() {
        var q = PlaybackQueueAccounting()
        XCTAssertFalse(q.takeStarveVerdict(nowNs: s))
    }

    func testCompletionNeverDrivesTheCountNegative() {
        var q = PlaybackQueueAccounting()
        // An unexpected completion clamps at zero rather than going negative, which would let the queue exceed its cap.
        XCTAssertTrue(q.consumed(generation: q.generation, playerIsPlaying: true, nowNs: s))
        XCTAssertEqual(q.pending, 0)
    }
}
