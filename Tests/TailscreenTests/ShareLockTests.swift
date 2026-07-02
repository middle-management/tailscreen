import XCTest

@testable import Tailscreen

/// Unit tests for `ShareLock` — the flock-based single-sharer mutex.
/// flock(2) locks are per open-file-description, so two `ShareLock`
/// instances in one process genuinely contend, which lets these tests
/// exercise acquire/contend/probe/release without spawning a second
/// process. Skips if some other process on the machine (e.g. a real
/// Tailscreen mid-share) already holds the lock.
final class ShareLockTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipIf(
            ShareLock.isHeldByAnyone(),
            "the share lock is held by another process on this machine")
    }

    func testAcquireContendsAndReleases() {
        let first = ShareLock()
        let second = ShareLock()
        defer {
            first.release()
            second.release()
        }

        XCTAssertFalse(first.isHeldBySelf)
        XCTAssertTrue(first.tryAcquire())
        XCTAssertTrue(first.isHeldBySelf)

        // The slot is taken: a second instance can't acquire, and the
        // non-destructive probe sees it as held.
        XCTAssertFalse(second.tryAcquire())
        XCTAssertFalse(second.isHeldBySelf)
        XCTAssertTrue(ShareLock.isHeldByAnyone())

        // Re-acquiring our own lock is an idempotent success.
        XCTAssertTrue(first.tryAcquire())

        first.release()
        XCTAssertFalse(first.isHeldBySelf)
        XCTAssertFalse(ShareLock.isHeldByAnyone())

        // Slot freed — the loser can now take it.
        XCTAssertTrue(second.tryAcquire())
    }

    func testProbeDoesNotStealTheLock() {
        let lock = ShareLock()
        defer { lock.release() }
        XCTAssertTrue(lock.tryAcquire())

        // isHeldByAnyone takes (and drops) a shared lock to probe; that
        // must not release or invalidate the holder's exclusive lock.
        XCTAssertTrue(ShareLock.isHeldByAnyone())
        XCTAssertTrue(ShareLock.isHeldByAnyone())
        XCTAssertTrue(lock.isHeldBySelf)

        let contender = ShareLock()
        XCTAssertFalse(contender.tryAcquire())
    }

    func testReleaseWithoutAcquireIsHarmless() {
        let lock = ShareLock()
        lock.release()
        XCTAssertFalse(lock.isHeldBySelf)
        XCTAssertFalse(ShareLock.isHeldByAnyone())
    }
}
