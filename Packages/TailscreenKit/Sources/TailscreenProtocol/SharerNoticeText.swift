import Foundation

/// The words a sharer notice is rendered with, and the two ways a
/// notification backend can quietly drop half of them.
///
/// Separate from `SharerNotice` since it depends on what the *daemon* can
/// render; separate from the hosts so three of them don't each compose
/// strings that drift apart.
///
/// **Two capability gaps this exists to survive**, neither producing an
/// error anywhere (both pinned by tests):
///
/// - **No `actions`.** The daemon silently drops the buttons. An Accept/Deny
///   pair would then render as a sentence stating a decision with no way to
///   make it, so the text changes to say where to answer instead.
/// - **No `body`.** Only the summary shows, and every notice here names a
///   *person* in the body — so the name folds up into the summary instead.
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

    /// Action keys. Constants, not literals, since they cross a process
    /// boundary and a typo on one side is a dead button. Derived from
    /// `NoticeAction` (not spelled out) so the way back,
    /// `NoticeAction(rawValue:)`, can't silently stop routing if either
    /// moved. The macOS backend takes the same keys straight off
    /// `NoticeAction.rawValue`.
    public static let approveKey = NoticeAction.approve.rawValue
    public static let denyKey = NoticeAction.deny.rawValue

    /// What to say when the buttons cannot be shown. Names the app, since a
    /// notification is read out of context.
    public static let answerInAppHint = "Open Tailscreen to answer."

    /// What a returned action key means.
    ///
    /// **Everything but the two answer keys maps to `.dismiss`** — the
    /// load-bearing half. Platforms deliver more than button presses through
    /// this channel (a Windows toast BODY click activates the app; a
    /// freedesktop daemon can invoke an unsolicited `"default"` action), and
    /// reading either as a deny would decide about a peer just because
    /// someone looked at the notification.
    ///
    /// Total, not optional: "I don't recognize this" and "dismissed" call
    /// for the same behaviour — bring the app forward, leave them waiting.
    public static func action(forKey key: String) -> NoticeAction {
        switch key {
        case approveKey: .approve
        case denyKey: .deny
        default: .dismiss
        }
    }

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
        // Hint only where a button was actually taken away — telling someone
        // to answer a report is how a notification becomes noise.
        let needsHint = !notice.kind.actions.isEmpty && !rendersActions

        var detail = self.detail(for: notice.kind, label: notice.label)
        if needsHint { detail += " " + answerInAppHint }

        guard rendersBody else {
            // Name goes FIRST: a summary truncates from the end, and the
            // name decides whether this is worth interrupting for.
            return Rendered(summary: detail, body: "", buttons: buttons)
        }
        return Rendered(
            summary: headline(for: notice.kind), body: detail, buttons: buttons)
    }

    /// The short line. Says nothing about *who* — that's the body's job, and
    /// duplicating it stutters on daemons that show both.
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

    /// Buttons for a kind, in order. The affirmative is worded per kind:
    /// "Accept" fits a viewer at the gate but not an invitation to share,
    /// where the answer is an action rather than agreement.
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
