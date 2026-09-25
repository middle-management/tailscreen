import Foundation

/// Where this machine's own screen share is, as the sharer is shown it.
///
/// Shared across hosts like `NodeBringUpPhase`/`ViewerSessionPhase`, so
/// macOS, GTK and WinUI describe one bring-up from one enum instead of three
/// vocabularies that can disagree (WinUI's old pair of Bools had no
/// `starting` state at all, so its share card read "Not sharing" through
/// the whole capture/encoder/tsnet bring-up).
///
/// `failed` carries its reason inline, like `NodeBringUpPhase.failed`, so
/// there's one value to write and clear rather than two that can disagree.
public enum ShareBringUpPhase: Equatable, Sendable {
    /// Not sharing, and nothing on the way.
    case idle
    /// Bringing capture up: permission, encoder, server, transport. Every
    /// host takes visible seconds here (ScreenCaptureKit helper on macOS,
    /// WGC picker + tsnet on Windows).
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
    /// A gate written as `== .idle` would silently lose the retry once
    /// `failed` became its own state (the GTK link-share gate's bug).
    public var canStart: Bool {
        switch self {
        case .idle, .failed: true
        default: false
        }
    }

    /// Whether a share is occupying this machine — starting or live. Exact
    /// complement of `canStart`. Gates written as `!= .idle` before `failed`
    /// existed read a failed start as a live share forever (this shipped:
    /// locked account switching, unclickable peer rows, silenced notices) —
    /// say the question directly instead of deriving it from `.idle`.
    public var isLive: Bool { !canStart }

    /// Why the last start failed, or nil.
    public var failureReason: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }

    /// Whether this is the failed state, whatever the reason.
    public var hasFailed: Bool { failureReason != nil }
}
