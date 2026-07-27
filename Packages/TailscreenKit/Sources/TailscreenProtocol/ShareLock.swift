import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
// `Darwin.write` resolves to the module-wide Glibc shim in
// PortabilityShims.swift; flock/open/close/ftruncate resolve unqualified.
import Glibc
#elseif canImport(WinSDK)
import WinSDK
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
// The implementation below is POSIX (flock/open/ftruncate). Windows has no
// flock and — more to the point — no `replayd`, so the constraint this type
// models simply does not exist there. See the Windows variant at the bottom.
#if !os(Windows)
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

#else

/// Windows stand-in.
///
/// `ShareLock` exists to coordinate around macOS `replayd`'s per-bundle limit
/// of one `SCStream` session. Windows has no `replayd` and no such limit, so
/// there is nothing to coordinate and the lock always succeeds.
///
/// This is a deliberate no-op, not an unimplemented stub: callers use it to
/// grey out a Share button pre-emptively, and on Windows the honest answer to
/// "is another process already sharing?" is "that isn't a constraint here".
/// If Windows ever grows a real single-capture constraint, this is where a
/// named mutex (`CreateMutexW`) would go.
public final class ShareLock: @unchecked Sendable {
    public static let path = "(unused on Windows)"

    private var held = false

    public init() {}

    public func tryAcquire() -> Bool {
        held = true
        return true
    }

    public func release() { held = false }

    public var isHeldBySelf: Bool { held }

    public static func isHeldByAnyone() -> Bool { false }
}

#endif
