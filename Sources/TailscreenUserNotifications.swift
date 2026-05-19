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
        case unknown, requesting, authorized, denied
    }

    private var authState: AuthState = .unknown
    private var pendingPostsAfterAuth: [() -> Void] = []

    private init() {}

    /// Post a "$hostname wants you to share" banner. If notification
    /// authorization hasn't been requested yet, the request fires on this
    /// call and the post is enqueued until the user responds.
    func postRequestToShareNotification(fromHostname: String) {
        let post = { [weak self] in
            guard let self else { return }
            guard self.authState == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Tailscreen request"
            content.body = "\(fromHostname) wants you to share your screen"
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
        case .denied:
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, _ in
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
