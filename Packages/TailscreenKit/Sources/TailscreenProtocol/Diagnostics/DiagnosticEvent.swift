import Foundation

/// One recorded moment in a session, in the shape an agent can read without
/// being told what the app is.
///
/// The thing this exists to fix: when a share goes wrong between two people,
/// each side sees half a story. The sharer knows it started capturing and
/// admitted somebody; the viewer knows it dialled, waited, and got a black
/// window. Neither half names the other's half, so the first hour of every
/// such report is spent reconstructing an ordering that both machines already
/// knew at the time. A recorded event stream is that ordering, kept.
///
/// Shaped for a **reader that is not a person**. Three consequences run
/// through the whole type:
///
///   * **`name` is a stable dotted identifier, never prose.** `hello.ack.sent`
///     means the same thing in every build forever; "Sent handshake ack to
///     viewer" does not, because the day somebody improves the wording every
///     saved query against it breaks. Names are minted in
///     ``DiagnosticEventName`` and pinned by `DiagnosticEventNameTests` for
///     exactly the reason the wire bytes are pinned by
///     `WireByteRegistryTests` — a renamed event is a broken reader, and the
///     rename is invisible at the call site.
///   * **Detail goes in `fields`, not into the name and not into a sentence.**
///     `ssrc=7 addr=100.64.0.3` is greppable, joinable across sides, and
///     survives translation into a table; "assigned SSRC 7 to 100.64.0.3" has
///     to be parsed back out of English first. It also keeps events cheap to
///     compare — two events differing only in a field are obviously the same
///     event.
///   * **Both clocks are recorded.** `monotonicNs` is what you order a single
///     side's events by (it cannot jump when NTP corrects the clock mid-share,
///     and a share is exactly long enough for that to happen); `wallClock` is
///     the only thing two machines can be merged on. Keeping one would make
///     either single-side ordering or cross-side merge unreliable, and both
///     are the point.
///
/// Deliberately NOT a log line. `TSLogger` and `InputDebugLog` stay what they
/// are — a developer reading stderr during a run. This is the structured
/// record that outlives the run and gets attached to a report.
public struct DiagnosticEvent: Sendable, Equatable {

    /// Per-recorder sequence number, from 1, assigned on record.
    ///
    /// Carried because the two clocks cannot do this job. Events recorded
    /// inside the same nanosecond tick sort ambiguously by either clock, and
    /// a merged bundle would then show an ack before the hello that caused it
    /// — the single most misleading thing a causal trace can do. The sequence
    /// is also how a reader detects loss: a bundle whose first event is
    /// `seq: 4213` dropped 4212 events, and ``DiagnosticsBundle`` says so in
    /// the header rather than leaving the gap to be noticed.
    public var seq: UInt64

    /// Nanoseconds since the recorder started. Monotonic within one side.
    public var monotonicNs: UInt64

    /// Wall-clock capture time — the cross-side merge key.
    ///
    /// Trusted only as far as the two machines' clocks agree, which is why
    /// ``DiagnosticsBundle`` merges on it but ``DiagnosticsRecorder`` never
    /// orders by it.
    public var wallClock: Date

    /// Which session of this process the event belongs to, from 0.
    ///
    /// A process shares and views more than once, and every one of those is a
    /// separate story about a separate pair of machines. Without this the
    /// exported stream is one undifferentiated run: a reader cannot tell where
    /// the share that went wrong began, and the merge could pair a HELLO from
    /// one session with the ACK of another if an SSRC ever repeated — a
    /// confidently wrong clock correction built out of two unrelated
    /// handshakes.
    ///
    /// An ordinal rather than a UUID, because it is read by a person and an
    /// agent far more often than it is joined on, and `session=2` is
    /// legible where a random 128-bit value is not. It scopes to ONE bundle:
    /// the two sides of a share number their sessions independently, and the
    /// thing that joins them across machines is still the SSRC in the
    /// handshake. ``DiagnosticsRecorder/beginSession()`` advances it.
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

/// Which half of a session an event came from.
///
/// A bundle is merged from both sides, so every line has to say whose it is —
/// "connection refused" means opposite things from the two ends. `app` covers
/// what belongs to neither role: sign-in, node bring-up, window and view
/// changes, settings.
public enum DiagnosticRole: String, Sendable, CaseIterable, Codable {
    case app
    case sharer
    case viewer
}

/// The subsystem an event belongs to.
///
/// Chosen so the obvious first question — "is this the network, the picture,
/// or the person?" — is one filter rather than a guess at which event names
/// are relevant. Kept deliberately coarse: a reader who wants finer grain
/// filters on the `name` prefix, which is free, whereas a category set that
/// tries to be precise ends up with events that plausibly belong to two.
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

/// How much an event should pull a reader's eye.
///
/// Three levels, not five. The distinction that earns its keep is
/// "expected / went wrong / session-ending", and every extra level past that
/// is an argument at the call site about which one applies.
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

/// A field value: the JSON scalars, and nothing else.
///
/// No nesting on purpose. A flat event is one row in a table, greppable with
/// `name=value` and joinable across sides on a bare key; a nested one needs a
/// path language before either works. Anything genuinely structured (a
/// capability set, a resolution) is spelled as a scalar the reader can
/// compare — `caps: "nack|rr|fec"`, `size: "2560x1440"` — which is also what
/// makes two events with the same fields `Equatable` in the way tests want.
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
    /// Widening convenience so call sites can pass any integer width without
    /// a cast at every use — SSRCs are `UInt32`, sequence numbers `UInt16`,
    /// byte counts `Int`, and a cast on each would be pure noise on a line
    /// whose whole job is to be cheap to write.
    ///
    /// `UInt64` values above `Int64.max` clamp rather than trap. Nothing in
    /// this app produces one, and a diagnostics recorder that can crash the
    /// app it is recording is a worse bug than an imprecise field.
    public init<T: BinaryInteger>(_ value: T) {
        if let exact = Int64(exactly: value) {
            self = .int(exact)
        } else {
            self = .int(value < 0 ? .min : .max)
        }
    }
}
