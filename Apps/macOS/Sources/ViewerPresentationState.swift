import Combine
import Foundation
import TailscreenProtocol

/// Viewer-session presentation state owned by the macOS shell.
///
/// AppState still owns effects — the client, AppKit window, renderer, audio
/// and alerts — while this object owns the related values those effects
/// mutate. Keeping them together gives the viewer lifecycle one boundary
/// instead of four independent `@Published` flags plus reconnect identity on
/// the app-wide object.
///
/// AppState relays `objectWillChange`, preserving its existing public surface
/// while views migrate to observing this model directly.
@MainActor
final class ViewerPresentationState: ObservableObject {
    @Published private(set) var awaitingApproval = false
    @Published private(set) var awaitingAdmission = false
    @Published private(set) var ending: ViewerSessionEndReason?
    @Published private(set) var isGuestSession = false

    private(set) var lifecycle = ViewerSessionLifecycle()

    func begin(target: ViewerSessionTarget) {
        lifecycle.begin(target)
    }

    @discardableResult
    func markAwaitingApproval() -> Bool {
        lifecycle.markAwaitingApproval()
    }

    @discardableResult
    func markViewing() -> Bool {
        lifecycle.markViewing()
    }

    func setAwaitingApproval(_ value: Bool) {
        awaitingApproval = value
    }

    func setAwaitingAdmission(_ value: Bool) {
        awaitingAdmission = value
    }

    func setGuestSession(_ value: Bool) {
        isGuestSession = value
    }

    func end(_ reason: ViewerSessionEndReason) {
        _ = lifecycle.end(reason)
    }

    func fail(_ message: String) {
        _ = lifecycle.fail(message)
    }

    func setEnding(_ reason: ViewerSessionEndReason?) {
        ending = reason
    }

    /// Dismiss presentation while retaining the target for Reconnect and
    /// ended-state copy.
    func dismiss() {
        lifecycle.dismiss()
    }

    func forget() {
        lifecycle.forget()
        awaitingApproval = false
        awaitingAdmission = false
        ending = nil
        isGuestSession = false
    }
}
