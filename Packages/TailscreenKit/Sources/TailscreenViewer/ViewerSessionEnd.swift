import Foundation
import TailscreenProtocol

extension ViewerSessionEndReason {
    /// The transport's close reason as the reason a person is shown, with the
    /// single HELLO_DENY byte worded BY CONTEXT.
    ///
    /// `wasAdmitted` is a parameter and not a guess for the reason the wire
    /// format documents: `deniedOrKicked` is one byte covering two very
    /// different sentences, and the only thing that tells them apart is where
    /// this viewer was when it landed. Still parked on the approval placard
    /// (no SSRC assigned yet) means the request was **declined**; already
    /// watching means the sharer **disconnected** them mid-session. A copy of
    /// this that hard-codes either answer is right half the time and silently
    /// so — both renderings are plausible sentences on a plausible screen.
    ///
    /// All three hosts route through here. Before it existed the mapping was
    /// written four times: the GTK app twice (transport reason → its own
    /// enum, then that enum → the chrome's), the Windows app once, and macOS
    /// once — where it hard-coded `disconnectedBySharer` because its deny path
    /// happens to arrive somewhere else with the context already applied.
    public static func resolve(
        _ reason: ViewerCloseReason, wasAdmitted: Bool
    ) -> ViewerSessionEndReason {
        switch reason {
        case .sharerStopped: return .sharerStopped
        case .timedOut: return .timedOut
        case .connectionLost: return .connectionLost
        case .deniedOrKicked: return wasAdmitted ? .disconnectedBySharer : .declined
        }
    }
}
