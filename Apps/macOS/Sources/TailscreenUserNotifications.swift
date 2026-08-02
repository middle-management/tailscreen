import Foundation
import UserNotifications

/// The app's `UNUserNotificationCenterDelegate`.
///
/// Without one, a notification posted while Tailscreen is frontmost displays
/// **nothing at all** — the system's default for a foreground app is to
/// suppress it, and `add(_:)` reports success either way. There was no delegate
/// anywhere in the target, so every post made while the user had the app in
/// front was silently dropped: exactly the moment someone has just clicked the
/// menubar item and a viewer arrives.
///
/// This is also where a notification *action* reports back
/// (`didReceive response:`) once the approve/deny buttons land, so the object
/// is needed regardless of the foreground case.
/// Stateless, so `@unchecked Sendable` costs nothing to guarantee — it exists
/// only to satisfy the `static let shared` a delegate needs in order to be
/// retained (`UNUserNotificationCenter.delegate` is weak).
///
/// The protocol conformance lives in the extension below rather than on this
/// line, so the declaration fits on one line: swift-format wraps a longer one
/// and puts the opening brace on its own line, which swiftlint's
/// `opening_brace` rule rejects — the two tools cannot both be satisfied by a
/// wrapped declaration, so the fix is to not need one. Same reasoning as
/// `AccountProfileStore.init`'s `fm` local.
final class TailscreenNotificationDelegate: NSObject, @unchecked Sendable {
    static let shared = TailscreenNotificationDelegate()

    /// Install once at launch. No-op on unbundled builds, where
    /// `UNUserNotificationCenter.current()` raises rather than degrading.
    @MainActor
    static func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = shared
    }
}

extension TailscreenNotificationDelegate: UNUserNotificationCenterDelegate {
    /// Show banners even when Tailscreen is the active app. `.list` keeps it
    /// in Notification Center so a sharer who looks away mid-share can still
    /// find out somebody is waiting; `.sound` is honoured only for posts that
    /// asked for one, and the sharer-facing posts deliberately do not (see
    /// `ViewerJoinNotifier.post`).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Posts macOS notifications for events that happen while the menubar
/// popover is closed — primarily incoming request-to-share prompts, which
/// otherwise sit invisible in `pendingRequests` until the user happens to
/// open the popover.
///
/// Authorization is requested lazily on the first notification, so first
/// launch stays prompt-free; a denied request just makes future posts no-op
/// (the in-popover banner still surfaces the request).
@MainActor
final class TailscreenUserNotifications {
    static let shared = TailscreenUserNotifications()

    private enum AuthState {
        case unknown, requesting, authorized, denied, unavailable
    }

    private var authState: AuthState
    private var pendingPostsAfterAuth: [() -> Void] = []

    private init() {
        // `UNUserNotificationCenter.current()` traps with "Bundle
        // identifier nil" when called from an unbundled binary —
        // happens with `make run` / `swift build` output, since those
        // produce a plain Mach-O without an Info.plist. Detect that
        // shape and mark notifications permanently unavailable so the
        // in-popover banner remains the only surface; the bundled
        // `Tailscreen.app` (release / install path) has a bundle id
        // and works normally.
        if Bundle.main.bundleIdentifier == nil {
            self.authState = .unavailable
        } else {
            self.authState = .unknown
        }
    }

    /// Post a "$hostname wants you to share" banner. If notification
    /// authorization hasn't been requested yet, the request fires on this
    /// call and the post is enqueued until the user responds. No-op on
    /// unbundled binaries (see `init`).
    func postRequestToShareNotification(fromHostname: String) {
        let post = { [weak self] in
            guard let self else { return }
            guard self.authState == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = L("Tailscreen request")
            content.body = L("\(fromHostname) wants you to share your screen")
            // Kept, unlike the sharer-facing posts in `ViewerJoinNotifier`:
            // a request-to-share arrives while this machine is *idle*, so
            // there is no capture running for the sound to leak into.
            content.sound = .default
            // Someone is waiting on an answer, so this outranks a Focus. The
            // requester's connection is held open until it is answered or
            // times out — an unnoticed banner spends that window and resolves
            // to "no answer" without the user ever knowing they were asked.
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["fromHostname": fromHostname]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { _ in }
        }

        switch authState {
        case .authorized:
            post()
        case .denied, .unavailable:
            return
        case .requesting:
            pendingPostsAfterAuth.append(post)
        case .unknown:
            pendingPostsAfterAuth.append(post)
            requestAuthorization()
        }
    }

    private func requestAuthorization() {
        authState = .requesting
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authState = granted ? .authorized : .denied
                let queued = self.pendingPostsAfterAuth
                self.pendingPostsAfterAuth.removeAll()
                for post in queued { post() }
            }
        }
    }
}
