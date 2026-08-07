import Foundation

/// Why a viewer session ended, as the person watching is told it.
///
/// The presentation-side mirror of the viewer tier's `ViewerCloseReason`, with
/// the one HELLO_DENY byte already split by ADMISSION CONTEXT — declined at the
/// approval placard vs kicked mid-watch. The wire carries no distinction
/// between those two, so the split is a fact only the host holds; see
/// `ViewerSessionEndReason.resolve(_:wasAdmitted:)` in `TailscreenViewer`,
/// which is the one place it is applied.
///
/// This lives in the dependency-free tier rather than beside `ViewerCloseReason`
/// because its consumers cannot all reach the viewer tier: the shared hub chrome
/// (`TailscreenHubUI`) deliberately depends on no viewer tier, and the GTK app's
/// `ViewerUIState` deliberately imports neither the chrome nor the viewer. All
/// three had grown their own five-case copy of this list, which is three places
/// for a sixth ending to be added in two of them.
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
