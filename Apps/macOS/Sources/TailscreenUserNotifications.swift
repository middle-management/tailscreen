import Foundation
import UserNotifications

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
            content.sound = .default
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
