import Foundation

// Glibc only, deliberately: importing WinSDK here would drag its
// `#define uuid_t UUID` into the module and make every `UUID` mention
// ambiguous against Foundation's.
#if canImport(Glibc)
import Glibc
#endif

// Combine stand-ins for platforms without it (Linux), so portable transport
// classes (`TailscalePeerDiscovery`, `TailscaleIPNWatcher`) keep their
// `ObservableObject`/`@Published` untouched. Compiles to nothing on Apple
// platforms.
//
// `$property.values` must behave like Combine's `AsyncPublisher` (current
// value on subscribe, then updates) since `TailscalePeerDiscovery` consumes
// `watcher.$peers.values` to merge IPN-bus peers.
#if !canImport(Combine)

/// Marker stand-in for Combine's `ObservableObject`. Carries no
/// `objectWillChange`; it exists so conformance clauses compile.
public protocol ObservableObject: AnyObject {}

/// Stand-in for Combine's `@Published`. `$prop.values` yields the current
/// value on subscription then every assignment, matching `AsyncPublisher`.
/// A class so assignment mutates shared state directly; subscribers are
/// pruned via `onTermination` to avoid accumulating dead continuations.
@propertyWrapper
public final class Published<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init(wrappedValue: Value) {
        current = wrappedValue
    }

    public var wrappedValue: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            let live = Array(continuations.values)
            lock.unlock()
            // Yield outside the lock so a consumer that reacts synchronously
            // can't re-enter and deadlock.
            for continuation in live { continuation.yield(newValue) }
        }
    }

    public var projectedValue: Published<Value> { self }

    /// Current value on subscribe, then every assignment — the
    /// `AsyncPublisher.values` shape.
    public var values: AsyncStream<Value> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuation.yield(current)
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }
}

#endif  // !canImport(Combine)

// Glibc stand-in for the `Darwin.`-qualified syscalls portable files use
// (currently `ShareLock`). On Apple platforms the real Darwin module wins.
// Gated on Glibc, not "not Darwin": Windows's `ShareLock` variant touches no
// POSIX, so there's nothing here for it to stand in for.
#if !canImport(Darwin) && canImport(Glibc)
enum Darwin {
    @discardableResult
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        Glibc.write(fd, buf, count)
    }
}
#endif  // !canImport(Darwin) && canImport(Glibc)
