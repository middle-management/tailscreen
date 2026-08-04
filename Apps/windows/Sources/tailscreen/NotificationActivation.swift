import Foundation

/// Delivers a toast press back into the app.
///
/// The *other* half of the notification story, and the half that decides
/// whether the buttons are worth putting on the toast at all: a notification
/// with an Accept button that answers nothing is strictly worse than one
/// without, because the sharer waits for something that is not coming.
///
/// The split runs through swift-winui's projection. Posting needs a C shim
/// because `Microsoft.Windows.AppNotifications` is not projected in Swift;
/// **this** half is projected — `AppInstance.Activated` and
/// `ExtendedActivationKind.appNotification` are ordinary Swift — right up to
/// the last step, where the event's `data` is an
/// `AppNotificationActivatedEventArgs` from that same unprojected namespace and
/// arrives as an untyped `IInspectable`. `WindowsNotifier.decodeAction(
/// fromActivationData:)` is the one `QueryInterface` that closes the gap.
///
/// This is the app's second genuinely Windows-bound file, and it carries the
/// same `#if os(Windows)` + stub as `WinUIVideoView` for the same reason: so
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
    /// Subscribes to the *running* instance's event rather than reading
    /// `getActivatedEventArgs()`, and the difference is the whole feature:
    /// that method returns the arguments this process was LAUNCHED with, so
    /// a host that used it would answer a toast only when the click had
    /// started the app — never during a share, which is the only time any
    /// of this matters.
    ///
    /// Silent when there is no `AppInstance`. That is the same normal state
    /// registration failing is: without a Windows App Runtime the app can
    /// reach, nothing was posted either, so there is nothing to answer.
    @MainActor
    static func observe(_ handler: @escaping @MainActor (Press) -> Void) {
        guard let instance = AppInstance.getCurrent() else { return }
        instance.activated.addHandler { _, arguments in
            guard let arguments, arguments.kind == .appNotification else { return }
            // Unprojected, so it comes through as the base COM wrapper —
            // and `pUnk.borrow` is the raw pointer the shim needs. Borrowed
            // for the duration of this call only; the shim never releases
            // it.
            guard let data = arguments.data as? WindowsFoundation.IInspectable else { return }
            guard
                let press = WindowsNotifier.decodeAction(
                    fromActivationData: UnsafeMutableRawPointer(data.pUnk.borrow))
            else { return }
            // The event arrives on a COM thread, and everything it will
            // touch — the roster, the inbox, the notification bookkeeping —
            // is main-actor state.
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
