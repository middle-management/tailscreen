import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
// `Darwin.write` resolves to the module-wide Glibc shim in
// PortabilityShims.swift; flock/open/close/ftruncate resolve unqualified.
import Glibc
#endif

// The implementation below is POSIX (flock/open/ftruncate). Windows has no
// flock and — more to the point — no `replayd`, so the constraint this type
// models simply does not exist there. See the Windows variant at the bottom.
#if !os(Windows)

/// File-lock advisory mutex shared across Tailscreen instances on the same
/// Mac. macOS's `replayd` enforces a per-bundle limit of one SCStream
/// session at a time; without coordination a 2nd-instance share click fails
/// with replayd -3805. The lockfile lets the UI grey out Share preemptively
/// instead of a failed bring-up + alert.
///
/// `flock(LOCK_EX | LOCK_NB)` on `/tmp/tailscreen-sharing.lock`,
/// auto-released on fd close or process exit — no orphan-lock recovery
/// needed even on SIGKILL.
public final class ShareLock: @unchecked Sendable {
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
        // Drop our PID into the file for anyone tailing it. Best-effort;
        // the flock alone is what's load-bearing.
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

    /// Probe whether *some* process on this Mac holds the lock (not who).
    /// A non-destructive `LOCK_SH | LOCK_NB` fails with `EWOULDBLOCK` if the
    /// file is exclusively locked elsewhere; on success, drop the shared
    /// lock and report free.
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

/// Windows stand-in. `ShareLock` exists for macOS `replayd`'s per-bundle
/// SCStream limit; Windows has no such constraint, so this is a deliberate
/// no-op (not an unimplemented stub) that always succeeds. A real
/// single-capture constraint would use a named mutex (`CreateMutexW`) here.
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
