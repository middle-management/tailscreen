import Combine
import Foundation
import TailscreenProtocol

/// Viewer-session presentation state owned by the macOS shell.
///
/// AppState still owns effects — the client, AppKit window, renderer, audio
/// and alerts — while this object owns the portable lifecycle and the one
/// macOS-only pre-admission flag. Presentation values that the lifecycle
/// already determines are projections, not separately mutable slots.
///
/// AppState relays `objectWillChange`, preserving its existing public surface
/// while views migrate to observing this model directly.
@MainActor
final class ViewerPresentationState: ObservableObject {
    @Published private(set) var awaitingAdmission = false

    @Published private(set) var lifecycle = ViewerSessionLifecycle()

    var awaitingApproval: Bool {
        lifecycle.phase == .awaitingApproval
    }

    var ending: ViewerSessionEndReason? {
        switch lifecycle.phase {
        case .ended(let reason):
            reason
        case .failed:
            // macOS explains connection failures in an alert; if an old
            // viewer window is still visible during Reconnect, its deterministic
            // in-window projection is the corresponding connection-lost state.
            .connectionLost
        default:
            nil
        }
    }

    var isGuestSession: Bool {
        lifecycle.phase != nil && lifecycle.target?.isGuest == true
    }

    @discardableResult
    func begin(target: ViewerSessionTarget) -> ViewerSessionID {
        lifecycle.begin(target)
    }

    func isCurrent(_ id: ViewerSessionID) -> Bool {
        lifecycle.isCurrent(id)
    }

    func isActive(_ id: ViewerSessionID) -> Bool {
        lifecycle.isActive(id)
    }

    @discardableResult
    func markAwaitingApproval(for id: ViewerSessionID) -> Bool {
        lifecycle.markAwaitingApproval(for: id)
    }

    @discardableResult
    func markViewing(for id: ViewerSessionID) -> Bool {
        lifecycle.markViewing(for: id)
    }

    func setAwaitingAdmission(_ value: Bool) {
        awaitingAdmission = value
    }

    @discardableResult
    func end(_ reason: ViewerSessionEndReason, for id: ViewerSessionID) -> Bool {
        lifecycle.end(reason, for: id)
    }

    @discardableResult
    func fail(_ message: String, for id: ViewerSessionID) -> Bool {
        lifecycle.fail(message, for: id)
    }

    /// Dismiss presentation while retaining the target for Reconnect and
    /// ended-state copy.
    func dismiss() {
        lifecycle.dismiss()
    }

    func forget() {
        lifecycle.forget()
        awaitingAdmission = false
    }
}
