import Foundation

/// Where this machine's own screen share is, as the sharer is shown it.
///
/// The third of the lifecycles that had grown a copy per host, and the same
/// argument as `NodeBringUpPhase` and `ViewerSessionPhase`: one thing was
/// happening, three types described it, and they did not agree about which
/// moments exist. macOS had `idle / starting / active` and reported a failed
/// start as an alert; the GTK engine had exactly the four cases below; the
/// WinUI engine had a pair of Bools with **no starting state at all**, so its
/// share card read "Not sharing" for the whole bring-up — capture permission,
/// encoder, tsnet — and only flipped once frames were already going out.
///
/// The case names come from the GTK engine, which had them right: `sharing`
/// rather than macOS's `active`, because it says what is happening and it is
/// the word all three already use in their own status lines ("Sharing your
/// screen", "Sharing \(target)").
///
/// `failed` carries its reason for the same reason `NodeBringUpPhase.failed`
/// does — a host that keeps the reason in a slot beside the phase has two
/// values to write and clear together, and therefore two values that can
/// disagree about whether anything is wrong.
public enum ShareBringUpPhase: Equatable, Sendable {
    /// Not sharing, and nothing on the way.
    case idle
    /// Bringing capture up: permission, encoder, server, transport. Every
    /// host takes visible seconds here — on macOS the ScreenCaptureKit
    /// helper, on Windows the WGC picker plus tsnet — which is exactly why
    /// a hub with no such state leaves somebody looking at "Not sharing"
    /// wondering whether their click registered.
    case starting
    /// Live: frames are going out.
    case sharing
    /// The start failed and nothing went live, with the reason as the person
    /// is told it.
    case failed(String)

    /// Live. The projection a host keeps its existing `isSharing` reads on
    /// rather than churning every call site.
    public var isSharing: Bool { self == .sharing }

    /// Whether pressing Start makes sense — idle, or failed and retryable.
    ///
    /// A failure belongs here for the same reason it belongs in
    /// `NodeBringUpPhase.isSignedOut`: the way out of it is the button that
    /// tried, and a gate written as `== .idle` silently loses the retry the
    /// moment failures became a state of their own. That is not
    /// hypothetical — it is the shape of the bug this type's sibling
    /// introduced and had to be caught by hand on the GTK link-share gate.
    public var canStart: Bool {
        switch self {
        case .idle, .failed: true
        default: false
        }
    }

    /// Why the last start failed, or nil.
    public var failureReason: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }

    /// Whether this is the failed state, whatever the reason.
    public var hasFailed: Bool { failureReason != nil }
}
