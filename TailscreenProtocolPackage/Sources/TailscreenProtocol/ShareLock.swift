import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc

/// Maps the `Darwin.`-qualified syscall this file uses onto Glibc so the
/// same call site compiles on Linux (flock/open/close/ftruncate resolve
/// unqualified on both platforms).
private enum Darwin {
    public static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        Glibc.write(fd, buf, count)
    }
}
#endif

/// File-lock advisory mutex shared across Tailscreen instances on the
/// same Mac. macOS's `replayd` enforces a per-bundle constraint that
/// only one SCStream session can run on the bundle at a time; without
/// coordination, a 2nd-instance share-button click is dead on arrival
/// (replayd returns -3805). The lockfile lets one instance know
/// another is already sharing so the UI can grey out its Share button
/// preemptively instead of putting the user through a failed bring-up
/// + alert.
///
/// Implementation: open a file at `/tmp/tailscreen-sharing.lock` and
/// `flock(LOCK_EX | LOCK_NB)` it. The lock is auto-released when the
/// fd is closed or the process exits — no orphan-lock recovery
/// needed even on SIGKILL.
public final class ShareLock: @unchecked Sendable {
    /// Path is /tmp because every short-lived/test scenario should
    /// see the lock land somewhere obvious and tmpfs-cleanable.
    public static let path = "/tmp/tailscreen-sharing.lock"

    private var fd: Int32 = -1

    public init() {}

    deinit { release() }

    /// Try to take the exclusive lock. Returns `true` if we own it
    /// (caller is now allowed to share), `false` if another process
    /// currently holds it.
    public func tryAcquire() -> Bool {
        if fd >= 0 { return true }  // already ours
        let f = open(Self.path, O_RDWR | O_CREAT, 0o644)
        guard f >= 0 else { return false }
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            close(f)
            return false
        }
        fd = f
        // Drop our PID into the file so anyone tailing it knows who
        // holds the lock. Best-effort; truncation + write isn't
        // load-bearing for correctness, the flock alone is.
        let pid = "\(getpid())\n"
        _ = ftruncate(f, 0)
        _ = pid.withCString { cstr in
            Darwin.write(f, cstr, strlen(cstr))
        }
        return true
    }

    public func release() {
        guard fd >= 0 else { return }
        // Closing the fd releases the flock atomically.
        close(fd)
        fd = -1
    }

    /// True if we currently hold the lock.
    public var isHeldBySelf: Bool { fd >= 0 }

    /// Probe whether *some* process on this Mac currently holds the
    /// lock. Doesn't tell us who — just whether the slot is taken.
    /// Tries a non-destructive `LOCK_SH | LOCK_NB`: if it fails with
    /// `EWOULDBLOCK`, the file is exclusively locked elsewhere. If
    /// it succeeds, no one's holding it; we drop the shared lock
    /// before returning.
    public static func isHeldByAnyone() -> Bool {
        let f = open(path, O_RDONLY)
        guard f >= 0 else { return false }
        defer { close(f) }
        let acquired = flock(f, LOCK_SH | LOCK_NB) == 0
        if acquired {
            _ = flock(f, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
