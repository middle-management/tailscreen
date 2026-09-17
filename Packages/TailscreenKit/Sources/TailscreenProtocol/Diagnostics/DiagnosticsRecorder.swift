import Foundation
import Synchronization

/// The in-memory event log one side of a session keeps about itself.
///
/// Thread-safe and allocation-bounded, because it is called from the capture
/// thread, the receive loops, the UI thread and the sweep timers, and because
/// a share left running overnight must not be the reason the app is killed.
///
/// ## Why the buffer is not a plain ring
///
/// The obvious bounded buffer keeps the most recent N events and drops the
/// oldest. Applied here it throws away the single most valuable part of the
/// record: **the handshake happens in the first two seconds and the symptom
/// arrives an hour later.** "Viewer sees black" is only answerable against the
/// negotiation that set the codec and capabilities, so a plain ring deletes
/// the answer and keeps the complaint.
///
/// So the buffer is two buffers. A **prologue** holds the first
/// ``prologueCapacity`` events and is never evicted — bring-up, sign-in,
/// handshake, admission, the first frames. A **ring** holds the most recent
/// ``ringCapacity`` events. Between them sits a counted gap, and the count is
/// exported rather than silently absorbed: a reader that cannot see the gap
/// will read the prologue and the ring as adjacent and infer a causal link
/// across an hour of missing time.
///
/// ## Cost when off
///
/// Recording is off in a stable release unless the user turns it on
/// (``DiagnosticsPreference``), so the disabled path has to be free. `fields`
/// is an `@autoclosure`: a disabled recorder never builds the dictionary, and
/// the call site pays a Boolean load. Same reason `InputDebugLog.log` takes
/// one — these sit on per-packet and per-frame paths.
public final class DiagnosticsRecorder: @unchecked Sendable {

    /// Events kept from the start of the session, never evicted.
    public let prologueCapacity: Int

    /// Most-recent events kept once the prologue is full.
    public let ringCapacity: Int

    /// The role stamped on events that do not name one of their own.
    ///
    /// Usually `.app`, because **one process is not one role**. A Mac can
    /// share its screen to one person and watch another's at the same time,
    /// in the same process, so a recorder that fixed a single role would file
    /// half its events under the wrong one — and the merge, which pairs a
    /// HELLO_ACK's sender with its receiver, would then be pairing on a
    /// fiction. Each call site that knows its side passes it to
    /// ``record(_:role:severity:fields:nowNs:wallClock:)``; everything else
    /// falls back to this.
    public let defaultRole: DiagnosticRole

    /// Identifies the machine in a merged bundle. Free-form and host-supplied
    /// (a hostname, a device name); it is the label a person reads to know
    /// whose column they are looking at.
    public let deviceLabel: String

    private struct State {
        var enabled: Bool
        var prologue: [DiagnosticEvent] = []
        /// Fixed-size circular storage. `ringStart` is the index of the oldest
        /// live element once `ringCount == ringCapacity`.
        var ring: [DiagnosticEvent] = []
        var ringStart = 0
        var nextSeq: UInt64 = 1
        var dropped: UInt64 = 0
        var startWallClock: Date?
        var startMonotonicNs: UInt64?
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - defaultRole: the role for events that do not name one.
    ///   - deviceLabel: the name a reader identifies this side by.
    ///   - enabled: whether recording starts on. Hosts pass
    ///     ``DiagnosticsPreference/load(defaults:channel:environment:)``.
    ///   - prologueCapacity: events kept from the start, never evicted.
    ///   - ringCapacity: most-recent events kept.
    ///
    /// The defaults (256 + 4096) are sized against what they are for rather
    /// than against a memory budget: 256 comfortably covers bring-up through
    /// first frame for a handful of viewers, and 4096 at the event rates this
    /// app actually produces (per-second summaries, not per-packet lines) is
    /// roughly the last hour. Together they are a few hundred kilobytes, which
    /// is far below anything the video path is doing.
    public init(
        defaultRole: DiagnosticRole = .app,
        deviceLabel: String,
        enabled: Bool,
        prologueCapacity: Int = 256,
        ringCapacity: Int = 4096
    ) {
        self.defaultRole = defaultRole
        self.deviceLabel = deviceLabel
        // A non-positive capacity would make the arithmetic below meaningless
        // (and `%` by zero fatal). Clamp rather than trap: a recorder is never
        // worth crashing the app it is recording.
        self.prologueCapacity = max(0, prologueCapacity)
        self.ringCapacity = max(1, ringCapacity)
        self.state = Mutex(State(enabled: enabled))
    }

    // MARK: - Switching

    /// Whether events are being kept right now.
    public var isRecording: Bool { state.withLock { $0.enabled } }

    /// Turn recording on or off.
    ///
    /// Turning it **off deliberately keeps what was already recorded** — the
    /// user who flips the switch after something went wrong wants to hand over
    /// what just happened, and a switch that also erased it would be a trap.
    /// ``clear()`` is the separate, explicit way to discard.
    public func setRecording(_ enabled: Bool) {
        state.withLock { $0.enabled = enabled }
    }

    /// Discard everything recorded so far, including the drop count and the
    /// session start stamps. The next event starts a fresh session as far as
    /// an exported bundle is concerned.
    ///
    /// Sequence numbers restart at 1 with it: they number a session's events,
    /// and two bundles that share a device and a numbering but not a session
    /// would merge into nonsense.
    public func clear() {
        state.withLock {
            $0.prologue.removeAll(keepingCapacity: true)
            $0.ring.removeAll(keepingCapacity: true)
            $0.ringStart = 0
            $0.nextSeq = 1
            $0.dropped = 0
            $0.startWallClock = nil
            $0.startMonotonicNs = nil
        }
    }

    // MARK: - Recording

    /// Record one event.
    ///
    /// - Parameters:
    ///   - name: the registry case for this event. Its category and default
    ///     severity come with it — see ``DiagnosticEventName``.
    ///   - role: which side of the session this event belongs to, when the
    ///     call site knows. Defaults to ``defaultRole``.
    ///   - severity: overrides the registry default, for the events whose
    ///     weight depends on the outcome rather than on which event it is.
    ///   - fields: structured detail. Not evaluated when recording is off.
    ///   - nowNs: monotonic reading; nil reads the process uptime clock. The
    ///     parameter exists so suites drive the buffer deterministically —
    ///     same seam as `AnnotationStore`.
    ///   - wallClock: capture time; nil reads the system clock.
    public func record(
        _ name: DiagnosticEventName,
        role: DiagnosticRole? = nil,
        severity: DiagnosticSeverity? = nil,
        fields: @autoclosure () -> [String: DiagnosticValue] = [:],
        nowNs: UInt64? = nil,
        wallClock: Date? = nil
    ) {
        // Read the switch before touching `fields`: the whole point of the
        // autoclosure is that a disabled recorder never builds the dictionary.
        guard state.withLock({ $0.enabled }) else { return }

        let mono = nowNs ?? Self.monotonicNowNs()
        let wall = wallClock ?? Date()
        let redacted = DiagnosticsRedaction.scrub(fields())

        state.withLock { s in
            // Re-check under the same lock that appends. Without this a
            // `setRecording(false)` racing an in-flight record could still
            // land an event after the user asked it to stop, which is the one
            // promise this switch has to keep.
            guard s.enabled else { return }

            if s.startMonotonicNs == nil {
                s.startMonotonicNs = mono
                s.startWallClock = wall
            }
            // Elapsed against the session start, not a raw uptime: a reader
            // should see `0` on the first line, and `&-` because a clock that
            // appears to step backwards must not wrap into an enormous number.
            let elapsed = mono >= (s.startMonotonicNs ?? mono) ? mono &- (s.startMonotonicNs ?? mono) : 0

            let event = DiagnosticEvent(
                seq: s.nextSeq,
                monotonicNs: elapsed,
                wallClock: wall,
                role: role ?? defaultRole,
                category: name.category,
                name: name.rawValue,
                severity: severity ?? name.defaultSeverity,
                fields: redacted)
            s.nextSeq &+= 1

            if s.prologue.count < prologueCapacity {
                s.prologue.append(event)
                return
            }
            if s.ring.count < ringCapacity {
                s.ring.append(event)
                return
            }
            // Full: overwrite the oldest and advance. This is the only place
            // an event is lost, so it is the only place `dropped` moves.
            s.ring[s.ringStart] = event
            s.ringStart = (s.ringStart + 1) % ringCapacity
            s.dropped &+= 1
        }
    }

    // MARK: - Reading

    /// Everything currently held, oldest first: the prologue, then the ring.
    ///
    /// The gap between them is **not** represented here — this is the event
    /// list, and a synthetic gap entry would be an event nothing recorded.
    /// ``snapshot()`` is what carries the drop count, and it is what export
    /// and any UI should use.
    public func events() -> [DiagnosticEvent] {
        state.withLock { s in
            guard s.ring.count == ringCapacity, s.ringStart > 0 else {
                return s.prologue + s.ring
            }
            return s.prologue + Array(s.ring[s.ringStart...]) + Array(s.ring[..<s.ringStart])
        }
    }

    /// Everything held, plus what it took to hold it.
    public func snapshot() -> DiagnosticsSnapshot {
        let (dropped, start, enabled) = state.withLock {
            ($0.dropped, $0.startWallClock, $0.enabled)
        }
        return DiagnosticsSnapshot(
            role: defaultRole,
            deviceLabel: deviceLabel,
            wasRecording: enabled,
            startedAt: start,
            droppedCount: dropped,
            events: events())
    }

    /// The process uptime clock — monotonic, and the same one
    /// `AnnotationStore` and the RTP PING path read, so timestamps taken here
    /// are comparable with timestamps taken there.
    static func monotonicNowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// One side's recording, frozen for export.
///
/// Separate from the recorder because export must not hold the lock while it
/// serializes, and because a merge works on values — the recorder keeps
/// running while a bundle is being written.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var role: DiagnosticRole
    public var deviceLabel: String
    /// Whether recording was on at the moment of the snapshot. Worth carrying:
    /// an empty event list means something very different when the answer is
    /// "it was on and nothing happened" than when it is "it was never on".
    public var wasRecording: Bool
    /// When the first event was recorded, or nil if none ever was.
    public var startedAt: Date?
    /// How many events fell out of the ring. Non-zero means the stream has a
    /// hole between the prologue and the ring, and a reader must not treat
    /// the two as adjacent.
    public var droppedCount: UInt64
    public var events: [DiagnosticEvent]

    public init(
        role: DiagnosticRole,
        deviceLabel: String,
        wasRecording: Bool,
        startedAt: Date?,
        droppedCount: UInt64,
        events: [DiagnosticEvent]
    ) {
        self.role = role
        self.deviceLabel = deviceLabel
        self.wasRecording = wasRecording
        self.startedAt = startedAt
        self.droppedCount = droppedCount
        self.events = events
    }
}
