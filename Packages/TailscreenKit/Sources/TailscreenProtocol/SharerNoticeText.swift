import Foundation

/// The words a sharer notice is rendered with, and the two ways a notification
/// backend can quietly drop half of them.
///
/// Separate from `SharerNotice` because it depends on what the *daemon* can
/// render, which the notice itself has no business knowing. Separate from the
/// hosts because three of them composing their own strings is three sets that
/// agree on the day they are written and never again — the same argument that
/// put `ShortcutCatalog`'s labels here.
///
/// **The two capability gaps this exists to survive.** A freedesktop
/// notification daemon advertises what it can render, and the honest ones
/// admit to less than you would expect:
///
/// - **No `actions`.** The daemon silently DROPS the buttons rather than
///   failing the call. An Accept/Deny pair then renders as a sentence stating
///   a decision with no way to make it — strictly worse than a plain notice,
///   because the person waits for something that is not coming. So the text
///   changes: it says where to answer instead.
/// - **No `body`.** Only the summary is shown. Every notice here names a
///   *person*, and the name lives in the body, so a summary-only daemon
///   produces "Someone wants to watch" with the someone missing. So the name
///   folds up into the summary.
///
/// Neither failure produces an error anywhere. Both are pinned by tests.
public enum SharerNoticeText {
    /// One button.
    public struct Button: Equatable, Sendable {
        /// The key that comes back when it is pressed. Stable, never shown.
        public let key: String
        /// English source text; hosts localize.
        public let label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    /// A notice, rendered for one particular daemon.
    public struct Rendered: Equatable, Sendable {
        public let summary: String
        /// Empty when the daemon cannot render a body — never a reason to skip
        /// posting, since the summary was rewritten to carry the name.
        public let body: String
        public let buttons: [Button]

        public init(summary: String, body: String, buttons: [Button]) {
            self.summary = summary
            self.body = body
            self.buttons = buttons
        }
    }

    /// Action keys. Constants rather than literals because they cross a
    /// process boundary — the daemon hands the key back verbatim, and a typo
    /// on one side is a button that does nothing.
    public static let approveKey = "approve"
    public static let denyKey = "deny"

    /// What to say when the buttons cannot be shown.
    ///
    /// Names the app, because a notification is read out of context: by the
    /// time somebody sees it they may not remember which of several things on
    /// their tailnet is asking.
    public static let answerInAppHint = "Open Tailscreen to answer."

    /// Render `notice` for a daemon with the stated capabilities.
    ///
    /// - Parameters:
    ///   - rendersBody: the `body` capability. False folds the peer's name into
    ///     the summary, because otherwise the notice names nobody.
    ///   - rendersActions: the `actions` capability. False drops the buttons
    ///     *and* says where to answer instead.
    public static func render(
        _ notice: SharerNotice, rendersBody: Bool, rendersActions: Bool
    ) -> Rendered {
        let buttons = rendersActions ? self.buttons(for: notice.kind) : []
        // The hint belongs only where a button was actually taken away. On an
        // informational notice there is nothing to answer, and telling someone
        // to go and answer a report is how a notification becomes noise.
        let needsHint = !notice.kind.actions.isEmpty && !rendersActions

        var detail = self.detail(for: notice.kind, label: notice.label)
        if needsHint { detail += " " + answerInAppHint }

        guard rendersBody else {
            // Everything on one line. The name goes FIRST: a summary is
            // truncated from the end, and the name is the part that decides
            // whether this is worth interrupting for.
            return Rendered(summary: detail, body: "", buttons: buttons)
        }
        return Rendered(
            summary: headline(for: notice.kind), body: detail, buttons: buttons)
    }

    /// The short line. Deliberately says nothing about *who* — that is the
    /// body's job, and duplicating it reads as a stutter on daemons that show
    /// both.
    static func headline(for kind: SharerNoticeKind) -> String {
        switch kind {
        case .viewerPending: "Someone wants to watch"
        case .controlRequested: "Control requested"
        case .requestToShare: "Share request"
        case .viewerJoined: "Viewer joined"
        case .viewerLeft: "Viewer left"
        }
    }

    /// The sentence naming the peer and what they want.
    static func detail(for kind: SharerNoticeKind, label: String) -> String {
        switch kind {
        case .viewerPending: "\(label) is waiting to be let in."
        case .controlRequested: "\(label) wants to control this machine."
        case .requestToShare: "\(label) wants you to share your screen."
        case .viewerJoined: "\(label) started watching."
        case .viewerLeft: "\(label) stopped watching."
        }
    }

    /// Buttons for a kind, in the order they should appear.
    ///
    /// The affirmative is worded per kind rather than shared: "Accept" is right
    /// for a viewer at the gate and wrong for an invitation to start sharing,
    /// where the answer is not agreement but an action.
    static func buttons(for kind: SharerNoticeKind) -> [Button] {
        switch kind {
        case .viewerPending:
            [Button(key: approveKey, label: "Accept"), Button(key: denyKey, label: "Deny")]
        case .controlRequested:
            [Button(key: approveKey, label: "Allow"), Button(key: denyKey, label: "Deny")]
        case .requestToShare:
            [Button(key: approveKey, label: "Share"), Button(key: denyKey, label: "Decline")]
        case .viewerJoined, .viewerLeft: []
        }
    }
}
