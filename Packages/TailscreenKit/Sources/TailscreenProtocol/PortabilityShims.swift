import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

// Combine stand-ins for platforms that don't have it (Linux), so the
// portable transport classes (`TailscalePeerDiscovery`,
// `TailscaleIPNWatcher`) can keep their `ObservableObject` conformance and
// `@Published` state untouched. On Apple platforms this whole file compiles
// to nothing — Combine's real types win, and the mac build is byte-for-byte
// unaffected.
//
// The `Published` shim is not inert: `$property.values` must behave like
// Combine's `AsyncPublisher` (current value on subscribe, then updates),
// because `TailscalePeerDiscovery` consumes `watcher.$peers.values` to merge
// IPN-bus peers. There is no `objectWillChange`/SwiftUI machinery here —
// non-Apple UIs observe state their own way.
#if !canImport(Combine)

/// Marker stand-in for Combine's `ObservableObject`. Carries no
/// `objectWillChange`; it exists so conformance clauses compile.
public protocol ObservableObject: AnyObject {}

/// Stand-in for Combine's `@Published`. The projected value (`$prop`)
/// exposes `values`, an `AsyncStream` that yields the current value on
/// subscription and every subsequent assignment — the same shape as
/// Combine's `AsyncPublisher` that portable consumers rely on. A class (not
/// a struct wrapping reference storage) so assignment through the wrapper
/// mutates shared state directly; finished subscribers are pruned via
/// `onTermination` so long-lived publishers don't accumulate dead
/// continuations.
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
// (currently `ShareLock`). Internal, so any file in this module reaches it;
// on Apple platforms the real Darwin module wins and this compiles away.
#if !canImport(Darwin)
enum Darwin {
    @discardableResult
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        Glibc.write(fd, buf, count)
    }
}
#endif  // !canImport(Darwin)
