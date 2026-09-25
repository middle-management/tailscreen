import Foundation

/// The process's diagnostics recorder, and the one place the existing
/// `print`-backed logging is teed into it.
///
/// Process-wide because what's being recorded is the process: writers are
/// scattered (`AppState`, both engines, the sharer server, the viewer
/// session, several private `LogSink`s), and threading a recorder through
/// all of them would be plumbing for no extra correctness.
///
/// The explicit seams remain: ``TailscaleScreenShareServer/recorder`` and
/// ``ViewerSession/recorder`` are ordinary injected properties a test can
/// hand its own recorder, and this type is how a host installs the one
/// recorder those properties point at, not a second way to record.
///
/// Nothing is recorded until a host installs a recorder, so diagnostics-off
/// (the stable-release default) pays one relaxed load per log line.
public final class DiagnosticsCenter: @unchecked Sendable {

    public static let shared = DiagnosticsCenter()

    private struct State {
        var recorder: DiagnosticsRecorder?
        var environment: DiagnosticsEnvironment?
    }

    /// `NSLock`, not `Synchronization.Mutex` (see ``Guarded``'s TSan note) —
    /// the log tee below is called from every thread in the process.
    private let lock = NSLock()
    private var state = State()

    private init() {}

    /// The process recorder, once a host has created one. Set once at
    /// start-up, never cleared — including when recording is turned off,
    /// which is the recorder's own switch (``DiagnosticsRecorder/setRecording(_:)``),
    /// not this reference. If turning recording off nil'd it here, existing
    /// holders (server, viewer session) would keep a stale copy and re-enable
    /// would install a reference nothing built already sees.
    public var recorder: DiagnosticsRecorder? {
        lock.lock()
        defer { lock.unlock() }
        return state.recorder
    }

    /// The build facts for this process, for an exported bundle's header.
    public var environment: DiagnosticsEnvironment? {
        lock.lock()
        defer { lock.unlock() }
        return state.environment
    }

    /// Install the process recorder and the build facts. Hosts call this once,
    /// during start-up, through ``DiagnosticsHost/start(environment:defaults:processEnvironment:)``.
    public func install(recorder: DiagnosticsRecorder?, environment: DiagnosticsEnvironment?) {
        lock.lock()
        defer { lock.unlock() }
        state.recorder = recorder
        state.environment = environment
    }

    /// Record one line from the `LogSink` plumbing. These lines are prose —
    /// the weakest kind of event — and are a safety net under the named
    /// events in ``DiagnosticEventName``, never a substitute. Promote a
    /// load-bearing log line to a registry event instead of relying on this.
    public func captureLog(source: String, message: String) {
        guard let recorder else { return }
        recorder.record(
            .logLine,
            severity: Self.severity(of: message),
            fields: ["source": .string(source), "text": .string(message)])
    }

    /// Classify a log line by its own text, since `LogSink` has no levels.
    /// Deliberately biased toward under-classifying — a wrongly-marked
    /// `error` costs more than a real problem sitting at `info`.
    ///
    /// Three rules, in order: (1) the author's own `❌`/`⚠` marker wins; (2) a
    /// line about surviving errors ("survived 3 error(s)") is not itself an
    /// error; (3) otherwise, keywords.
    static func severity(of message: String) -> DiagnosticSeverity {
        // 1. Explicit markers.
        if message.contains("❌") { return .error }
        if message.contains("⚠") { return .warning }

        let lowered = message.lowercased()

        // 2. The good-outcome exclusion.
        let reportsRecovery =
            lowered.contains("survived") || lowered.contains("recovered")
            || lowered.contains("no error")
        if reportsRecovery { return .info }

        // 3. Keywords.
        if lowered.contains("error") || lowered.contains("failed")
            || lowered.contains("failure") || lowered.contains("fatal")
        {
            return .error
        }
        if lowered.contains("warn") || lowered.contains("retry")
            || lowered.contains("timeout") || lowered.contains("unavailable")
        {
            return .warning
        }
        return .info
    }
}
