import Foundation

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

    /// `NSLock`, not `Synchronization.Mutex`, and the reason is worth keeping.
    ///
    /// **ThreadSanitizer cannot see through `Mutex` on Linux.** Its lock is
    /// futex-based, which TSan does not model as establishing happens-before,
    /// so every `withLock` body reads to TSan as an unsynchronised `inout`
    /// access and it reports a "Swift access race" on correct code. Verified
    /// in isolation: a bare `Mutex<S>` hammered by `concurrentPerform`, with
    /// none of this app's code involved, reports the identical warning, while
    /// the same hammer over `NSLock` is clean.
    ///
    /// That matters here more than anywhere else in this tier. This recorder
    /// is written to from the capture callbacks, both UDP receive loops, the
    /// sweep timers and the UI thread, which is exactly the shape of type
    /// `linux-tsan` exists to check — and behind a `Mutex` that check silently
    /// cannot run. Using a lock the sanitiser understands keeps the guarantee
    /// real instead of assumed.
    ///
    /// `NSLock` is already the pattern `WindowsShareSession` uses one tier up,
    /// so this is a choice the codebase has made before, not a new one.
    ///
    /// Note for anyone extending this tier: `RTPBufferPool` and
    /// `RetransmitBuffer` are on `Mutex` and are therefore equally invisible
    /// to TSan today. Nothing exercises them concurrently under the sanitiser
    /// yet, so nothing fails — but a concurrency test added to either will hit
    /// this same wall, and the answer will be this same one.
    /// One event's ingredients, assembled outside the lock and handed in as a
    /// single value — both callers build the same set, and passing them
    /// individually made `appendLocked` a six-parameter function for no gain.
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
        self.state = State(enabled: enabled)
    }

    // MARK: - Switching

    /// Whether events are being kept right now.
    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.enabled
    }

    /// Turn recording on or off.
    ///
    /// Turning it **off deliberately keeps what was already recorded** — the
    /// user who flips the switch after something went wrong wants to hand over
    /// what just happened, and a switch that also erased it would be a trap.
    /// ``clear()`` is the separate, explicit way to discard.
    public func setRecording(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        state.enabled = enabled
    }

    /// Discard everything recorded so far, including the drop count and the
    /// session start stamps. The next event starts a fresh session as far as
    /// an exported bundle is concerned.
    ///
    /// Sequence numbers restart at 1 with it: they number a session's events,
    /// and two bundles that share a device and a numbering but not a session
    /// would merge into nonsense.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        state.prologue.removeAll(keepingCapacity: true)
        state.ring.removeAll(keepingCapacity: true)
        state.ringStart = 0
        state.nextSeq = 1
        state.dropped = 0
        state.startWallClock = nil
        state.startMonotonicNs = nil
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
        guard isRecording else { return }

        let mono = nowNs ?? Self.monotonicNowNs()
        let wall = wallClock ?? Date()
        let redacted = DiagnosticsRedaction.scrub(fields())

        lock.lock()
        defer { lock.unlock() }

        // Re-check under the same lock that appends. Without this a
        // `setRecording(false)` racing an in-flight record could still land an
        // event after the user asked it to stop, which is the one promise this
        // switch has to keep.
        guard state.enabled else { return }
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
        // Elapsed against the session start, not a raw uptime: a reader should
        // see `0` on the first line. The ordering guard is why this is not a
        // bare `&-` — a clock that appears to step backwards must not wrap into
        // an enormous number.
        let elapsed = mono >= start ? mono &- start : 0

        let event = DiagnosticEvent(
            seq: state.nextSeq,
            monotonicNs: elapsed,
            wallClock: wall,
            role: pending.role,
            category: name.category,
            name: name.rawValue,
            severity: pending.severity,
            fields: pending.fields)
        state.nextSeq &+= 1

        if state.prologue.count < prologueCapacity {
            state.prologue.append(event)
            return
        }
        if state.ring.count < ringCapacity {
            state.ring.append(event)
            return
        }
        // Full: overwrite the oldest and advance. This is the only place an
        // event is lost, so it is the only place `dropped` moves.
        state.ring[state.ringStart] = event
        state.ringStart = (state.ringStart + 1) % ringCapacity
        state.dropped &+= 1
    }

    // MARK: - Reading

    /// Everything currently held, oldest first: the prologue, then the ring.
    ///
    /// The gap between them is **not** represented here — this is the event
    /// list, and a synthetic gap entry would be an event nothing recorded.
    /// ``snapshot()`` is what carries the drop count, and it is what export
    /// and any UI should use.
    public func events() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return orderedEventsLocked()
    }

    /// The ordered event list. **Caller must hold `lock`.**
    ///
    /// Split out so ``snapshot()`` can take the events and the metadata under
    /// ONE acquisition. `NSLock` is not recursive, so the alternative — having
    /// `snapshot` call `events()` and then re-lock — both risks a deadlock and
    /// opens a window: a record, a ring overwrite, a toggle or a `clear()`
    /// landing between the two acquisitions would produce a bundle whose
    /// header describes a different moment than its events. Export is
    /// deliberately allowed while recording continues, so that window is a
    /// real one, not a theoretical one.
    private func orderedEventsLocked() -> [DiagnosticEvent] {
        guard state.ring.count == ringCapacity, state.ringStart > 0 else {
            return state.prologue + state.ring
        }
        return state.prologue
            + Array(state.ring[state.ringStart...])
            + Array(state.ring[..<state.ringStart])
    }

    /// Everything held, plus what it took to hold it.
    /// Append a lifecycle marker even while recording is off.
    ///
    /// Exactly two events need this, and both describe the switch rather than
    /// the session: `recording.stopped`, which must outlive the stop it
    /// reports, and `recording.exported`, because **exporting while stopped is
    /// the documented workflow** — reproduce the problem, stop recording, hand
    /// the file over. An ordinary `record` no-ops when disabled, so that
    /// workflow produced a bundle with no record of its own export, which is
    /// the one thing ``DiagnosticsBundle`` promises every bundle carries.
    ///
    /// Deliberately NOT implemented by flipping the switch on and back: that
    /// would open a window in which every other writer in the process could
    /// land an event the user had asked not to be recorded.
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

    /// Everything held, plus what it took to hold it — read atomically.
    ///
    /// One lock acquisition covers both the events and the counters that
    /// describe them, so `droppedCount`, `startedAt` and `wasRecording` always
    /// describe the exact event list they ship with.
    public func snapshot() -> DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiagnosticsSnapshot(
            role: defaultRole,
            deviceLabel: deviceLabel,
            wasRecording: state.enabled,
            startedAt: state.startWallClock,
            droppedCount: state.dropped,
            events: orderedEventsLocked())
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
