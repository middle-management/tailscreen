import Foundation

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
/// Combine's `AsyncPublisher` that portable consumers rely on.
@propertyWrapper
public struct Published<Value: Sendable> {
    /// Reference-typed storage + subscriber fan-out. A class so the
    /// projected value handed to a subscriber keeps observing the same
    /// storage the wrapper mutates.
    public final class Projection: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Value
        private var continuations: [AsyncStream<Value>.Continuation] = []

        init(_ initial: Value) {
            current = initial
        }

        /// Current value on subscribe, then every assignment — the
        /// `AsyncPublisher.values` shape.
        public var values: AsyncStream<Value> {
            AsyncStream { continuation in
                lock.lock()
                defer { lock.unlock() }
                continuation.yield(current)
                continuations.append(continuation)
            }
        }

        var value: Value {
            get {
                lock.lock()
                defer { lock.unlock() }
                return current
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                current = newValue
                for continuation in continuations { continuation.yield(newValue) }
            }
        }
    }

    private let projection: Projection

    public init(wrappedValue: Value) {
        projection = Projection(wrappedValue)
    }

    public var wrappedValue: Value {
        get { projection.value }
        nonmutating set { projection.value = newValue }
    }

    public var projectedValue: Projection { projection }
}

#endif  // !canImport(Combine)
