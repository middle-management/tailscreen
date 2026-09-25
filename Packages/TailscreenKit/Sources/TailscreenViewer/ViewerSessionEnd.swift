import Foundation
import TailscreenProtocol

extension ViewerSessionEndReason {
    /// The transport's close reason as the reason a person is shown, with the
    /// single HELLO_DENY byte worded BY CONTEXT.
    ///
    /// `deniedOrKicked` is one wire byte covering two different sentences;
    /// `wasAdmitted` is what tells them apart. Still on the approval placard
    /// (no SSRC yet) means the request was **declined**; already watching
    /// means the sharer **disconnected** them mid-session. Hard-coding either
    /// answer is right half the time and silently wrong the other half.
    ///
    /// All three hosts route through here — do not reintroduce a per-host copy.
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
