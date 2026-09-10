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

    /// Why an ENDED session ended. Nil for a failure, which is a different
    /// thing with a different sentence — see `failureMessage`.
    ///
    /// This used to answer `.connectionLost` for `.failed` as well, because
    /// the in-window pane had no way to say anything else and a connection
    /// that failed to open is *a* kind of lost connection. It reads wrong
    /// where it matters, though: a dial that was refused, or a token that had
    /// expired, was reported to the person as "The connection to X was lost",
    /// which describes a session they never had.
    var ending: ViewerSessionEndReason? {
        guard case .ended(let reason) = lifecycle.phase else { return nil }
        return reason
    }

    /// The message from a `failed` phase — a bring-up or runtime failure,
    /// said in its own words rather than folded into an end reason.
    var failureMessage: String? {
        guard case .failed(let message) = lifecycle.phase else { return nil }
        return message
    }

    /// Whether a terminal pane is on screen, whichever kind.
    ///
    /// What the callers that used to test `ending != nil` actually meant:
    /// they gate menu items and window handling on "the session is over and
    /// its pane is still up", and neither cares which of the two it is.
    var isOver: Bool { lifecycle.phase?.isOver == true }

    /// The pre-video phase the in-window placard covers, if any.
    ///
    /// Both of them: this app used to show the placard only from
    /// `awaitingApproval`, so `connecting` — the phase every session passes
    /// through — was the one moment with nothing on the surface the person
    /// is looking at. The window title said "Connecting to X…" and the
    /// window itself was empty.
    var placardPhase: ViewerSessionPhase? {
        switch lifecycle.phase {
        case .connecting, .awaitingApproval: lifecycle.phase
        default: nil
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
