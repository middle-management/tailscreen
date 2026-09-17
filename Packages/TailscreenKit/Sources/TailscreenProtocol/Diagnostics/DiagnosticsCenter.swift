import Foundation

/// The process's diagnostics recorder, and the one place the existing
/// `print`-backed logging is teed into it.
///
/// ## Why this is process-wide
///
/// Because what is being recorded is the process. One app is one session
/// record, and the writers are scattered by nature — `AppState` and the GTK
/// and WinUI engines, the sharer server, the viewer session, and the
/// `LogSink`s several of those construct privately at their own
/// initialisation from call sites that have no reference to a recorder and no
/// reason to acquire one. Threading a recorder through all of them to reach
/// what is already a singleton in everything but name would be a lot of
/// plumbing for no extra correctness.
///
/// The explicit seams remain: ``TailscaleScreenShareServer/recorder`` and
/// ``ViewerSession/recorder`` are still ordinary injected properties, so a
/// test can hand either one its own recorder and read it back without
/// touching global state. This type is how a **host** installs the one
/// recorder those properties get pointed at, not a second way to record.
///
/// Nothing is recorded until a host installs a recorder, so a build with
/// diagnostics off (the stable-release default) pays one relaxed load per
/// log line and nothing else.
public final class DiagnosticsCenter: @unchecked Sendable {

    public static let shared = DiagnosticsCenter()

    private struct State {
        var recorder: DiagnosticsRecorder?
        var environment: DiagnosticsEnvironment?
    }

    /// `NSLock` for the reason spelled out on ``Guarded`` — TSan cannot see
    /// through `Synchronization.Mutex`, so a type behind one cannot be checked
    /// by the sanitiser at all, and the log tee below is called from every
    /// thread in the process.
    private let lock = NSLock()
    private var state = State()

    private init() {}

    /// The process recorder, once a host has created one.
    ///
    /// Set **once**, at start-up, and never cleared — including when the user
    /// turns recording off. Whether events are kept is the recorder's own
    /// switch (``DiagnosticsRecorder/setRecording(_:)``), not this reference.
    ///
    /// That split is deliberate and it is what makes the toggle work mid-share.
    /// The sharer server and the viewer session copy this reference when they
    /// are constructed; if turning recording off nil'd it here, they would
    /// keep their stale copy and go on recording, while turning it back on
    /// would install a reference nothing already built would ever see. Holding
    /// one object for the life of the process and moving a Boolean inside it
    /// makes both directions work everywhere at once — and costs nothing,
    /// because a disabled recorder's `record` returns on a Boolean load
    /// without evaluating its arguments.
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

    /// Record one line from the `LogSink` plumbing.
    ///
    /// This is where the feature gets most of its coverage for free: roughly
    /// three dozen existing call sites across the transport and sharer tiers
    /// already log the things a session investigation needs — node bring-up,
    /// listener binds, viewer admission, capture-helper lifecycle, congestion
    /// and FEC fallbacks, remote-control grants — and none of them had to be
    /// touched to be recorded.
    ///
    /// These lines are prose, so they are the weakest kind of event: not
    /// greppable by a stable name, not joinable across sides, not carrying
    /// structured fields. They are a safety net UNDER the named events in
    /// ``DiagnosticEventName``, never a substitute. When a log line turns out
    /// to be load-bearing in an investigation, give it a registry case and
    /// record it properly.
    public func captureLog(source: String, message: String) {
        guard let recorder else { return }
        recorder.record(
            .logLine,
            severity: Self.severity(of: message),
            fields: ["source": .string(source), "text": .string(message)])
    }

    /// Classify a log line by its own text, because `LogSink` has no levels —
    /// every message is one unstructured string.
    ///
    /// Deliberately biased toward **under**-classifying. A line wrongly marked
    /// `error` sends a reader chasing a non-problem, which costs more than a
    /// real problem sitting at `info` next to the named event that already
    /// reports it properly — these lines are a safety net under the registry
    /// events, not the thing anybody should be triaging from.
    ///
    /// Three rules, in order:
    ///
    /// 1. **The author's own marker wins.** This codebase already prefixes log
    ///    lines with `❌` and `⚠`/`⚠️` where it means them, which is real
    ///    severity information written by someone who knew what the line meant.
    ///    Guessing from prose while ignoring that would be strictly worse.
    /// 2. **A line about surviving errors is not an error.** "receive loop
    ///    survived 3 error(s) this session" is a *success* message and the one
    ///    false positive a plain keyword scan produces against the current call
    ///    sites. Cheap to exclude, and the exclusion is safe: a line that says
    ///    something survived or recovered is reporting the good outcome.
    /// 3. Otherwise, keywords.
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
