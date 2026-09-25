import Foundation

/// Delivers a toast press back into the app.
///
/// `Microsoft.Windows.AppNotifications` isn't projected in Swift for posting
/// (needs a C shim), but `AppInstance.Activated` /
/// `ExtendedActivationKind.appNotification` are — except the event's `data`
/// is an `AppNotificationActivatedEventArgs` from that same unprojected
/// namespace, arriving as an untyped `IInspectable`.
/// `WindowsNotifier.decodeAction(fromActivationData:)` is the one
/// `QueryInterface` that closes the gap.
///
/// Carries the same `#if os(Windows)` + stub as `WinUIVideoView` so
/// `SharerNotifications` and its call sites stay on the Linux typecheck path.
enum NotificationActivation {
    /// What a press was about: the notice's `id`, and the action key.
    typealias Press = (id: String, action: String)
}

#if os(Windows)

import WinAppSDK
import WinNotifyKit
import WindowsFoundation

extension NotificationActivation {
    /// Start listening. Each press is delivered on the main actor.
    ///
    /// Subscribes to the running instance's event rather than
    /// `getActivatedEventArgs()`, which answers only for the process's own
    /// LAUNCH — never during a share, the only time this matters.
    ///
    /// Silent when there is no `AppInstance`: without a Windows App Runtime
    /// the app can reach, nothing was posted either.
    @MainActor
    static func observe(_ handler: @escaping @MainActor (Press) -> Void) {
        guard let instance = AppInstance.getCurrent() else { return }
        instance.activated.addHandler { _, arguments in
            guard let arguments, arguments.kind == .appNotification else { return }
            // Unprojected, so it arrives as the base COM wrapper; `pUnk.borrow`
            // is the raw pointer the shim needs, borrowed for this call only.
            guard let data = arguments.data as? WindowsFoundation.IInspectable else { return }
            guard
                let press = WindowsNotifier.decodeAction(
                    fromActivationData: UnsafeMutableRawPointer(data.pUnk.borrow))
            else { return }
            // The event arrives on a COM thread; everything it touches is main-actor state.
            Task { @MainActor in handler((id: press.identity, action: press.action)) }
        }
    }
}

#else

extension NotificationActivation {
    /// Off Windows there is no activation to observe, and saying so here is
    /// what lets the host call this unconditionally.
    @MainActor
    static func observe(_ handler: @escaping @MainActor (Press) -> Void) {}
}

#endif
