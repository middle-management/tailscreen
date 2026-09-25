import Foundation

/// The in-memory event log one side of a session keeps about itself.
/// Thread-safe and allocation-bounded, since it's called from the capture
/// thread, receive loops, UI thread and sweep timers.
///
/// Not a plain ring: a plain ring drops the oldest events, which throws away
/// the handshake (first two seconds) while keeping the symptom (an hour
/// later). So the buffer is two buffers — a **prologue** of the first
/// ``prologueCapacity`` events, never evicted, and a **ring** of the most
/// recent ``ringCapacity``. The gap between them is counted and exported, not
/// silently absorbed, or a reader would read them as adjacent.
///
/// Recording is off by default in a stable release, so the disabled path has
/// to be free: `fields` is an `@autoclosure`, so a disabled recorder never
/// builds the dictionary.
public final class DiagnosticsRecorder: @unchecked Sendable {

    /// Events kept from the start of each session, never evicted while that
    /// session's prologue is retained.
    public let prologueCapacity: Int

    /// How many sessions' prologues are kept. Per session, not per process —
    /// otherwise a second share's HELLO lands in the evictable ring, losing
    /// exactly what `DiagnosticsMerge` pairs on.
    public let retainedSessionPrologues: Int

    /// Most-recent events kept once the prologue is full.
    public let ringCapacity: Int

    /// The role stamped on events that do not name one of their own. Usually
    /// `.app`, since one process is not one role — a Mac can share to one
    /// person while watching another. Call sites that know their side pass
    /// it explicitly to ``record(_:role:severity:fields:nowNs:wallClock:)``.
    public let defaultRole: DiagnosticRole

    /// Identifies the machine in a merged bundle. Free-form and host-supplied
    /// (a hostname, a device name); it is the label a person reads to know
    /// whose column they are looking at.
    public let deviceLabel: String

    private struct State {
        var enabled: Bool
        /// Bumped on every real on/off transition. `enabled` alone can't
        /// close the off→on race: a writer scrubs fields outside the lock,
        /// and by the time it re-locks, recording may have stopped and
        /// restarted — the generation check catches that.
        var generation: UInt64 = 0
        /// Which session events are stamped with now. Advances with each
        /// prologue, surviving the retention cap — a bundle whose lowest
        /// ordinal is 3 says so rather than renumbering the loss away.
        var session: UInt32 = 0
        /// One prologue per session, oldest first. See ``beginSession()``.
        var prologues: [[DiagnosticEvent]] = [[]]
        /// Fixed-size circular storage. `ringStart` is the index of the oldest
        /// live element once `ringCount == ringCapacity`.
        var ring: [DiagnosticEvent] = []
        var ringStart = 0
        var nextSeq: UInt64 = 1
        var dropped: UInt64 = 0
        var startWallClock: Date?
        var startMonotonicNs: UInt64?
    }

    /// `NSLock`, not `Synchronization.Mutex` (see ``Guarded``'s TSan note).
    /// Bare `NSLock`, not `Guarded`, since `record` deliberately releases the
    /// lock early, a shape `withLock` can't express.
    ///
    /// One event's ingredients, assembled outside the lock and handed in as a
    /// single value, since both callers build the same set.
    private struct PendingEvent {
        var name: DiagnosticEventName
        var role: DiagnosticRole
        var severity: DiagnosticSeverity
        var fields: [String: DiagnosticValue]
        var mono: UInt64
        var wall: Date
    }

    private let lock = NSLock()
    private var state: State

    /// - Parameters:
    ///   - defaultRole: the role for events that do not name one.
    ///   - deviceLabel: the name a reader identifies this side by.
    ///   - enabled: whether recording starts on. Hosts pass
    ///     ``DiagnosticsPreference/load(defaults:channel:environment:)``.
    ///   - prologueCapacity: events kept from the start, never evicted.
    ///   - ringCapacity: most-recent events kept.
    ///
    /// The defaults (256 + 4096) are sized against what they're for: 256
    /// covers bring-up through first frame, and 4096 at this app's event
    /// rates (per-second summaries, not per-packet) is roughly the last hour.
    public init(
        defaultRole: DiagnosticRole = .app,
        deviceLabel: String,
        enabled: Bool,
        prologueCapacity: Int = 256,
        ringCapacity: Int = 4096,
        retainedSessionPrologues: Int = 4
    ) {
        self.defaultRole = defaultRole
        self.deviceLabel = deviceLabel
        // Clamped, not trapped: a recorder is never worth crashing the app it records.
        self.prologueCapacity = max(0, prologueCapacity)
        self.ringCapacity = max(1, ringCapacity)
        self.retainedSessionPrologues = max(1, retainedSessionPrologues)
        self.state = State(enabled: enabled)
    }

    // MARK: - Switching

    /// Whether events are being kept right now.
    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.enabled
    }

    /// Turn recording on or off, optionally writing a lifecycle marker in the
    /// same critical section. Turning it off keeps what was already
    /// recorded — ``clear()`` is the separate, explicit way to discard.
    ///
    /// The marker and the flag move together, or a concurrent writer could
    /// land an event outside the session it claims to describe. Enabling
    /// writes the marker after the flag (first event of the new stretch),
    /// disabling before (last event of the old one).
    public func setRecording(
        _ enabled: Bool,
        markerName: DiagnosticEventName? = nil,
        markerFields: [String: DiagnosticValue] = [:]
    ) {
        // Built outside the lock: scrubbing is the caller's cost, not the
        // critical section's.
        let redacted = markerName == nil ? [:] : DiagnosticsRedaction.scrub(markerFields)
        let mono = Self.monotonicNowNs()
        let wall = Date()

        lock.lock()
        defer { lock.unlock() }

        // A no-op transition writes nothing, or `TAILSCREEN_DIAGNOSTICS=0`
        // makes every UI toggle append another `recording.stopped`.
        guard state.enabled != enabled else { return }

        // A real transition moves the generation, so a writer already past
        // the switch check belongs to the closing session, not the new one.
        state.generation &+= 1

        func appendMarker(_ name: DiagnosticEventName) {
            appendLocked(
                PendingEvent(
                    name: name, role: defaultRole, severity: name.defaultSeverity,
                    fields: redacted, mono: mono, wall: wall))
        }

        if enabled {
            state.enabled = true
            if let markerName { appendMarker(markerName) }
        } else {
            if let markerName { appendMarker(markerName) }
            state.enabled = false
        }
    }

    /// Discard everything recorded so far, including the drop count and
    /// session start stamps. Sequence numbers restart at 1, since two
    /// bundles sharing a device and numbering but not a session would merge into nonsense.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        state.prologues = [[]]
        state.session = 0
        state.ring.removeAll(keepingCapacity: true)
        state.ringStart = 0
        state.nextSeq = 1
        state.dropped = 0
        state.startWallClock = nil
        state.startMonotonicNs = nil
    }

    /// Start a new session prologue, so this session's handshake is
    /// protected from ring eviction like the first session's was. Hosts call
    /// this at share start / viewer connect; calling it twice is harmless.
    public func beginSession() {
        lock.lock()
        defer { lock.unlock() }
        // An untouched trailing segment is reused, so a double call gets one session.
        if state.prologues.last?.isEmpty == true { return }
        state.session &+= 1
        state.prologues.append([])
        while state.prologues.count > retainedSessionPrologues {
            let dropped = state.prologues.removeFirst()
            state.dropped &+= UInt64(dropped.count)
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
        // Read the switch before touching `fields`, so a disabled recorder never builds the dictionary.
        // Switch and generation read together, so the re-check below can
        // tell "still recording" from "stopped and restarted" — see ``State/generation``.
        lock.lock()
        let wasEnabled = state.enabled
        let generation = state.generation
        lock.unlock()
        guard wasEnabled else { return }

        let mono = nowNs ?? Self.monotonicNowNs()
        let wall = wallClock ?? Date()
        let redacted = DiagnosticsRedaction.scrub(fields())

        lock.lock()
        defer { lock.unlock() }

        // Re-check under the same lock that appends, or a racing
        // `setRecording(false)` could still land an event after the user
        // asked to stop. Generation covers stopped-and-restarted.
        guard state.enabled, state.generation == generation else { return }
        appendLocked(
            PendingEvent(
                name: name, role: role ?? defaultRole,
                severity: severity ?? name.defaultSeverity,
                fields: redacted, mono: mono, wall: wall))
    }

    /// Append one event. **Caller must hold `lock`**, and must already have
    /// decided that it should be appended — this does not consult `enabled`,
    /// because ``recordLifecycle(_:fields:nowNs:wallClock:)`` deliberately
    /// bypasses it.
    private func appendLocked(_ pending: PendingEvent) {
        let name = pending.name
        let mono = pending.mono
        let wall = pending.wall

        let start: UInt64
        if let existing = state.startMonotonicNs {
            start = existing
        } else {
            state.startMonotonicNs = mono
            state.startWallClock = wall
            start = mono
        }
        // Elapsed against session start, not raw uptime, so the first line
        // reads 0. Guarded, not a bare `&-`, so a backward clock step can't wrap into a huge number.
        let elapsed = mono >= start ? mono &- start : 0

        let event = DiagnosticEvent(
            seq: state.nextSeq,
            monotonicNs: elapsed,
            wallClock: wall,
            session: state.session,
            role: pending.role,
            category: name.category,
            name: name.rawValue,
            severity: pending.severity,
            fields: pending.fields)
        state.nextSeq &+= 1

        if state.prologues[state.prologues.count - 1].count < prologueCapacity {
            state.prologues[state.prologues.count - 1].append(event)
            return
        }
        if state.ring.count < ringCapacity {
            state.ring.append(event)
            return
        }
        // Full: overwrite the oldest — the only place `dropped` moves.
        state.ring[state.ringStart] = event
        state.ringStart = (state.ringStart + 1) % ringCapacity
        state.dropped &+= 1
    }

    // MARK: - Reading

    /// Everything currently held, oldest first: the prologue, then the ring.
    /// The gap between them is not represented here; ``snapshot()`` carries
    /// the drop count and is what export and any UI should use.
    public func events() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return orderedEventsLocked()
    }

    /// The ordered event list. **Caller must hold `lock`.** Split out so
    /// ``snapshot()`` takes events and metadata under one acquisition —
    /// `NSLock` isn't recursive, and re-locking between two calls opens a
    /// window where a concurrent record/toggle/`clear()` desyncs the header
    /// from its events.
    private func orderedEventsLocked() -> [DiagnosticEvent] {
        let ring: [DiagnosticEvent]
        if state.ring.count == ringCapacity, state.ringStart > 0 {
            ring = Array(state.ring[state.ringStart...]) + Array(state.ring[..<state.ringStart])
        } else {
            ring = state.ring
        }
        let prologue = state.prologues.flatMap { $0 }
        // Sorted by sequence, not concatenated: with more than one session
        // prologue, the ring and later prologues interleave in time.
        return (prologue + ring).sorted { $0.seq < $1.seq }
    }

    /// Append a lifecycle marker even while recording is off. Exactly two
    /// events need this: `recording.stopped` (must outlive the stop) and
    /// `recording.exported` (export-while-stopped is a documented workflow).
    /// Not implemented by flipping the switch on and back, which would open a
    /// window for other writers to land an unwanted event.
    public func recordLifecycle(
        _ name: DiagnosticEventName,
        fields: [String: DiagnosticValue] = [:],
        nowNs: UInt64? = nil,
        wallClock: Date? = nil
    ) {
        let mono = nowNs ?? Self.monotonicNowNs()
        let wall = wallClock ?? Date()
        let redacted = DiagnosticsRedaction.scrub(fields)

        lock.lock()
        defer { lock.unlock() }
        appendLocked(
            PendingEvent(
                name: name, role: defaultRole, severity: name.defaultSeverity,
                fields: redacted, mono: mono, wall: wall))
    }

    /// A snapshot with one lifecycle event staged on the end but not
    /// committed to the recorder — for export, which must put
    /// `recording.exported` in the bundle while leaving the recorder
    /// untouched until the write succeeds. Staged here, not at the call
    /// site, so its clock (`anchor + monotonicNs`) is measured now, not
    /// borrowed from the previous event.
    public func snapshotStaging(
        _ name: DiagnosticEventName,
        nowNs: UInt64? = nil
    ) -> DiagnosticsSnapshot {
        let mono = nowNs ?? Self.monotonicNowNs()
        let wall = Date()

        lock.lock()
        defer { lock.unlock() }

        var snapshot = snapshotLocked()
        let start = state.startMonotonicNs ?? mono
        snapshot.events.append(
            DiagnosticEvent(
                seq: state.nextSeq,
                monotonicNs: mono >= start ? mono &- start : 0,
                wallClock: wall,
                session: state.session,
                role: defaultRole,
                category: name.category,
                name: name.rawValue,
                severity: name.defaultSeverity))
        return snapshot
    }

    /// Everything held, plus what it took to hold it — read atomically under one lock.
    public func snapshot() -> DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    /// **Caller must hold `lock`.**
    private func snapshotLocked() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            role: defaultRole,
            deviceLabel: deviceLabel,
            wasRecording: state.enabled,
            startedAt: state.startWallClock,
            droppedCount: state.dropped,
            events: orderedEventsLocked())
    }

    /// The process uptime clock — same one `AnnotationStore` and the RTP
    /// PING path read, so timestamps are comparable.
    static func monotonicNowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// One side's recording, frozen for export. Separate from the recorder so
/// export doesn't hold the lock while serializing, and the recorder keeps
/// running while a bundle is written.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var role: DiagnosticRole
    public var deviceLabel: String
    /// Whether recording was on at the snapshot — distinguishes "on, nothing happened" from "never on".
    public var wasRecording: Bool
    /// When the first event was recorded, or nil if none ever was.
    public var startedAt: Date?
    /// How many events fell out of the ring. Non-zero means a hole between
    /// the prologue and the ring, not adjacency.
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
