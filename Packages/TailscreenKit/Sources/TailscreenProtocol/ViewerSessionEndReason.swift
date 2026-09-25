import Foundation

/// Why a viewer session ended, as the person watching is told it.
///
/// The presentation-side mirror of the viewer tier's `ViewerCloseReason`,
/// with the one HELLO_DENY byte already split by ADMISSION CONTEXT — declined
/// at the approval placard vs kicked mid-watch. The wire carries no such
/// distinction; see `ViewerSessionEndReason.resolve(_:wasAdmitted:)` in
/// `TailscreenViewer`, the one place it's applied.
///
/// Lives in the dependency-free tier because consumers can't all reach the
/// viewer tier (`TailscreenHubUI` depends on no viewer tier; GTK's
/// `ViewerUIState` imports neither chrome nor viewer).
public enum ViewerSessionEndReason: String, Sendable, Equatable, CaseIterable {
    /// The sharer ended the session (SERVER_BYE).
    case sharerStopped
    /// Nothing arrived for longer than the idle threshold.
    case timedOut
    /// The receive path died on repeated socket errors.
    case connectionLost
    /// HELLO_DENY while still at the approval placard — never admitted.
    case declined
    /// HELLO_DENY while already watching — a mid-session kick.
    case disconnectedBySharer
}
