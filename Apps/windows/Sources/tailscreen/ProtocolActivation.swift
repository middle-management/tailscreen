import Foundation

/// Delivers a clicked `tailscreen:` join link into the app.
///
/// The MSIX manifest's `uap:Protocol` extension is the registration half.
/// Packaged Win32 apps are multi-instance and nothing here redirects, so each
/// click starts a new process; the URI arrives via AppLifecycle activation
/// arguments, with the classic command line as fallback. Fine because a link
/// launch runs a guest viewer session, needing no tsnet node, so it never
/// contends with a running instance's state directory.
///
/// Carries the same `#if os(Windows)` + stub pattern as `WinUIVideoView` and
/// `NotificationActivation`, so call sites stay on the Linux typecheck path.
enum ProtocolActivation {}

#if os(Windows)

import UWP
import WinAppSDK
import WindowsFoundation

extension ProtocolActivation {
    /// The `tailscreen:` link this process was launched with, or nil for an
    /// ordinary launch. Unlike the notification observer, `getActivatedEventArgs()`
    /// is the right call here — a protocol activation IS a launch.
    @MainActor
    static func launchJoinLink() -> String? {
        if let instance = AppInstance.getCurrent(),
            let arguments = try? instance.getActivatedEventArgs(),
            arguments.kind == .protocol,
            let protocolArgs = arguments.data as? UWP.ProtocolActivatedEventArgs,
            let uri = protocolArgs.uri
        {
            // rawUri, not absoluteUri: the token must arrive byte-faithful,
            // not normalized.
            return uri.rawUri
        }
        return commandLineLink()
    }

    /// Redirected protocol activations while the app is running. Today
    /// nothing redirects — each click is a fresh process — but the handler
    /// costs nothing installed, and is the wire single-instance redirection
    /// would use if added later.
    @MainActor
    static func observe(_ handler: @escaping @MainActor (String) -> Void) {
        guard let instance = AppInstance.getCurrent() else { return }
        instance.activated.addHandler { _, arguments in
            guard let arguments, arguments.kind == .protocol else { return }
            guard
                let protocolArgs = arguments.data as? UWP.ProtocolActivatedEventArgs,
                let uri = protocolArgs.uri
            else { return }
            let link = uri.rawUri
            // The event arrives on a COM thread; the join path is main-actor
            // state.
            Task { @MainActor in handler(link) }
        }
    }

    private static func commandLineLink() -> String? {
        CommandLine.arguments.dropFirst().first {
            $0.lowercased().hasPrefix("tailscreen:")
        }
    }
}

#else

extension ProtocolActivation {
    /// Off Windows there is no protocol activation, and saying so here is
    /// what lets the host call this unconditionally.
    @MainActor
    static func launchJoinLink() -> String? { nil }
    @MainActor
    static func observe(_ handler: @escaping @MainActor (String) -> Void) {}
}

#endif
