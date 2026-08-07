import Foundation
import TailscaleKit
import TailscreenProtocol

/// One tsnet node bring-up instead of five.
///
/// Node bring-up used to be written independently by the viewer transport
/// (`TsnetTransport`), the sharer (`TailscaleScreenShareServer`), the macOS
/// client and `AppState`, and the Linux test sharer — five copies of "state
/// dir, `Configuration`, `TailscaleNode`, `up()`" whose semantics had
/// quietly diverged. The mechanics live here once; the *divergences* are
/// deliberate knobs each call site states explicitly (ephemerality, the
/// up-timeout policy, whether a login-URL subscription rides along), so a
/// site's behaviour is readable at the site rather than encoded in which
/// copy it happened to carry.
///
/// Two granularities on purpose:
/// - ``makeNode(spec:logger:)`` + ``up(_:spec:timeout:)`` for hosts that
///   interleave their own state between creation and `up()` (the macOS app
///   stores the node and subscribes its own long-lived IPN watcher first).
/// - ``bringUp(spec:logger:timeout:beforeUp:onLoginURL:stepLogPrefix:)`` for
///   the whole sequence, including the interactive-login URL subscription
///   with its leak-safe teardown.
public enum TsnetNodeFactory {
    /// Everything a node's identity is made of. All knobs are explicit —
    /// there are no defaults for `ephemeral` or `authKey`, because "which
    /// copy of bring-up had which default" is exactly the drift this type
    /// exists to end.
    public struct Spec: Sendable {
        /// The tsnet hostname to register under. Discovery filters on the
        /// `TailscreenInstance` prefixes, so the prefix decides whether
        /// peers can see this node at all.
        public var hostName: String
        /// Ephemeral nodes vanish from the tailnet the moment they go down —
        /// right for a transient viewer or a test tool, wrong for anything a
        /// peer may come back to.
        public var ephemeral: Bool
        /// tsnet state directory. Identity lives entirely in this directory;
        /// the factory creates it (best-effort) before the node.
        public var statePath: String
        /// Pre-auth key, or nil for interactive/existing login.
        public var authKey: String?
        /// Control server URL (headscale for local dev, else Tailscale's).
        public var controlURL: String

        public init(
            hostName: String,
            ephemeral: Bool,
            statePath: String,
            authKey: String?,
            controlURL: String
        ) {
            self.hostName = hostName
            self.ephemeral = ephemeral
            self.statePath = statePath
            self.authKey = authKey
            self.controlURL = controlURL
        }

        var configuration: Configuration {
            Configuration(
                hostName: hostName,
                path: statePath,
                authKey: authKey,
                controlURL: controlURL,
                ephemeral: ephemeral)
        }
    }

    /// How long `up()` may block. tsnet's `up()` has no internal timeout, and
    /// the right bound depends on whether a human is in the loop: with an
    /// auth key Running should arrive in seconds (a hang means a bad key or
    /// an unreachable control plane), while an interactive browser login
    /// legitimately takes minutes and must never be cut off.
    public enum UpTimeout: Sendable {
        /// Never bound `up()`.
        case unbounded
        /// Always bound `up()` to the given interval.
        case seconds(TimeInterval)
        /// Bound `up()` only when the spec carries an auth key (no human in
        /// the loop); unbounded otherwise so an interactive login isn't cut
        /// off. This is the policy the sharer and the macOS app use.
        case boundedWhenAuthKeyed(seconds: TimeInterval)
    }

    /// Create the state directory (best-effort) and the node. Does NOT call
    /// `up()` — pair with ``up(_:spec:timeout:)``.
    public static func makeNode(spec: Spec, logger: (any LogSink)?) throws -> TailscaleNode {
        try? FileManager.default.createDirectory(
            atPath: spec.statePath, withIntermediateDirectories: true)
        return try TailscaleNode(config: spec.configuration, logger: logger)
    }

    /// Bring the node up under the timeout policy.
    public static func up(_ node: TailscaleNode, spec: Spec, timeout: UpTimeout) async throws {
        switch timeout {
        case .unbounded:
            try await node.up()
        case .seconds(let seconds):
            try await withTimeout(seconds: seconds) { try await node.up() }
        case .boundedWhenAuthKeyed(let seconds):
            if spec.authKey != nil {
                try await withTimeout(seconds: seconds) { try await node.up() }
            } else {
                try await node.up()
            }
        }
    }

    /// The full bring-up: state dir → node → `beforeUp` hook → optional
    /// login-URL subscription → `up()` → subscription teardown.
    ///
    /// - Parameters:
    ///   - beforeUp: runs after the node exists and before `up()` — the
    ///     window a host must use to store the node or subscribe its own
    ///     IPN-bus watcher (subscribing after `up()` starts is too late: the
    ///     `BrowseToURL` notify fires with nobody listening and `up()` waits
    ///     forever).
    ///   - onLoginURL: when non-nil and the spec has no auth key, an IPN-bus
    ///     watcher is subscribed before `up()` and every `BrowseToURL` is
    ///     handed to this closure. The watcher is torn down on **every** exit
    ///     path — `up()` returning, `up()` throwing, and `startWatching`
    ///     itself throwing — because its `MessageProcessor` keeps running
    ///     (retaining the node) unless `stopWatching()` cancels it, and a
    ///     `startWatching` that threw part-way has already latched
    ///     `isWatching`. With an auth key the subscription is skipped
    ///     entirely.
    ///   - stepLogPrefix: when non-nil, each step logs *before* it starts
    ///     under this prefix (e.g. `"prepare"`). Before rather than after
    ///     because the failure this diagnoses is a *hang*, and a line that
    ///     only prints on success says nothing about where a hang is.
    public static func bringUp(
        spec: Spec,
        logger: (any LogSink)?,
        timeout: UpTimeout = .unbounded,
        beforeUp: (@Sendable (TailscaleNode) async -> Void)? = nil,
        onLoginURL: (@Sendable (URL) -> Void)? = nil,
        stepLogPrefix: String? = nil
    ) async throws -> TailscaleNode {
        func step(_ message: String) {
            guard let stepLogPrefix else { return }
            logger?.log("\(stepLogPrefix): \(message)")
        }

        step("creating state dir \(spec.statePath)")
        try? FileManager.default.createDirectory(
            atPath: spec.statePath, withIntermediateDirectories: true)

        // First call into the Go c-archive, so this is also where the Go
        // runtime initialises.
        step("creating tsnet node \(spec.hostName) (ephemeral=\(spec.ephemeral))")
        let node = try TailscaleNode(config: spec.configuration, logger: logger)

        if let beforeUp {
            await beforeUp(node)
        }

        // Interactive login (no auth key): tsnet's `up()` blocks until the
        // backend reaches Running, which on a fresh device means waiting for
        // a browser login. tsnet emits that login URL as a BrowseToURL notify
        // on the IPN bus — subscribe BEFORE `up()` (else the notify fires
        // with nobody listening and `up()` waits forever) and surface the URL
        // for the user to open. With an auth key this path is skipped
        // entirely.
        // ONE teardown covering every exit path from here on. `defer` cannot
        // `await`, so the whole subscribe-then-up sequence runs inside a
        // do/catch whose catch stops the watcher: it subscribed the IPN bus
        // before `up()`, and its MessageProcessor keeps running (retaining the
        // node) unless `stopWatching()` cancels it — a leak on the
        // interactive-login path. `startWatching` is INSIDE the same block for
        // the same reason: it latches `isWatching` before it can throw, so a
        // failed subscribe left the watcher half-armed and untorn-down when
        // this used to assign `authWatcher` only after it returned.
        var authWatcher: TailscaleIPNWatcher?
        do {
            if let onLoginURL, spec.authKey == nil {
                step("no auth key — subscribing to the IPN bus for the login URL")
                let watcher = await TailscaleIPNWatcher()
                await MainActor.run {
                    watcher.onBrowseToURL = { url in
                        onLoginURL(url)
                    }
                }
                authWatcher = watcher
                try await watcher.startWatching(node: node)
                step("IPN bus subscribed — waiting for interactive browser login…")
            }

            step("calling up() — blocks until login completes")
            try await up(node, spec: spec, timeout: timeout)
        } catch {
            await authWatcher?.stopWatching()
            throw error
        }
        await authWatcher?.stopWatching()

        return node
    }
}
