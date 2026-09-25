import Foundation

/// One recorded moment in a session, in the shape an agent can read without
/// being told what the app is. See `.claude/rules/diagnostics.md` for why the
/// merge exists.
///
/// Shaped for a reader that is not a person:
///
///   * `name` is a stable dotted identifier, never prose — minted in
///     ``DiagnosticEventName`` and pinned by `DiagnosticEventNameTests`, like
///     wire bytes. A renamed event is a broken reader.
///   * Detail goes in `fields`, not the name or a sentence — greppable,
///     joinable across sides, and keeps two same-fields events `Equatable`.
///   * Both clocks are recorded: `monotonicNs` orders one side's events (an
///     NTP correction can't jump it mid-share); `wallClock` is the only
///     cross-machine merge key.
///
/// Deliberately not a log line — `TSLogger`/`InputDebugLog` stay stderr for a
/// developer reading a live run. This is the structured record that outlives
/// the run.
public struct DiagnosticEvent: Sendable, Equatable {

    /// Per-recorder sequence number, from 1, assigned on record. Neither
    /// clock can order same-tick events unambiguously; this can, and also
    /// lets a reader detect loss (a bundle starting at `seq: 4213` dropped
    /// 4212 events — ``DiagnosticsBundle`` says so in the header).
    public var seq: UInt64

    /// Nanoseconds since the recorder started. Monotonic within one side.
    public var monotonicNs: UInt64

    /// Wall-clock capture time — the cross-side merge key. Trusted only as
    /// far as the two machines' clocks agree, so ``DiagnosticsBundle`` merges
    /// on it but ``DiagnosticsRecorder`` never orders by it.
    public var wallClock: Date

    /// Which session of this process the event belongs to, from 0. A process
    /// shares and views more than once, each a separate story; without this,
    /// the merge could pair a HELLO from one session with the ACK of
    /// another. An ordinal, not a UUID, since it's read far more often than
    /// joined on. Scoped to one bundle — ``DiagnosticsRecorder/beginSession()`` advances it.
    public var session: UInt32

    /// Which half of the session recorded this.
    public var role: DiagnosticRole

    /// The subsystem, for filtering a long stream down to one concern.
    public var category: DiagnosticCategory

    /// Stable dotted identifier — see ``DiagnosticEventName``.
    public var name: String

    /// How much this event should pull a reader's eye.
    public var severity: DiagnosticSeverity

    /// Structured detail. Keys are short, lowercase and stable; values are
    /// JSON scalars (see ``DiagnosticValue``).
    public var fields: [String: DiagnosticValue]

    public init(
        seq: UInt64,
        monotonicNs: UInt64,
        wallClock: Date,
        session: UInt32 = 0,
        role: DiagnosticRole,
        category: DiagnosticCategory,
        name: String,
        severity: DiagnosticSeverity = .info,
        fields: [String: DiagnosticValue] = [:]
    ) {
        self.seq = seq
        self.monotonicNs = monotonicNs
        self.wallClock = wallClock
        self.session = session
        self.role = role
        self.category = category
        self.name = name
        self.severity = severity
        self.fields = fields
    }
}

/// Which half of a session an event came from. A bundle merges both sides,
/// so every line must say whose it is. `app` covers what belongs to neither:
/// sign-in, node bring-up, window/view changes, settings.
public enum DiagnosticRole: String, Sendable, CaseIterable, Codable {
    case app
    case sharer
    case viewer
}

/// The subsystem an event belongs to. Deliberately coarse: a reader wanting
/// finer grain filters on the `name` prefix instead.
public enum DiagnosticCategory: String, Sendable, CaseIterable, Codable {
    /// Node bring-up, sign-in, discovery, link (share-by-token) tunnels.
    case network
    /// HELLO / HELLO_ACK, capability negotiation, admission, approval, eviction.
    case handshake
    /// Capture, encode, decode, render — the picture itself.
    case media
    /// Loss recovery and congestion: NACK, FEC, PLI, receiver reports, bitrate.
    case transport
    /// Microphone, system audio, voice.
    case audio
    /// Something a person did: clicked, granted, toggled, stopped.
    case action
    /// Which surface was on screen.
    case view
    /// A failure that was surfaced, or should have been.
    case fault
}

/// How much an event should pull a reader's eye. Three levels, not five —
/// "expected / went wrong / session-ending" is the distinction that earns its
/// keep.
public enum DiagnosticSeverity: String, Sendable, CaseIterable, Codable, Comparable {
    /// The session doing what it is supposed to do.
    case info
    /// Degraded but still running: a retry, a fallback, a capability withheld.
    case warning
    /// The thing the user was trying to do did not happen.
    case error

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A field value: the JSON scalars, and nothing else. No nesting — a flat
/// event is one row, greppable with `name=value`; structured data (a
/// capability set, a resolution) is spelled as a comparable scalar
/// (`caps: "nack|rr|fec"`, `size: "2560x1440"`).
public enum DiagnosticValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
}

// MARK: - Ergonomic construction

extension DiagnosticValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension DiagnosticValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension DiagnosticValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension DiagnosticValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension DiagnosticValue {
    /// Widening convenience so call sites pass any integer width (SSRCs
    /// `UInt32`, sequence numbers `UInt16`, byte counts `Int`) without a cast.
    /// `UInt64` values above `Int64.max` clamp rather than trap — a
    /// diagnostics recorder must never crash the app it records.
    public init<T: BinaryInteger>(_ value: T) {
        if let exact = Int64(exactly: value) {
            self = .int(exact)
        } else {
            self = .int(value < 0 ? .min : .max)
        }
    }
}
