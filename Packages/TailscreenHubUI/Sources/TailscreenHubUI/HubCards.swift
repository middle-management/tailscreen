import SwiftCrossUI

/// Centered spinner + status line — the pre-list phases (bringing the node up,
/// discovering, connecting) and the direct-connect placard.
public struct HubStatusPane: View {
    let status: String

    public init(status: String) {
        self.status = status
    }

    public var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(status)
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Interactive-login card: the sign-in prompt over the URL to open.
///
/// The URL is shown as selectable text rather than hidden behind the button:
/// launching a browser is the part most likely to fail on a locked-down or
/// remote machine, and a URL you can select and paste always works.
public struct HubLoginCard: View {
    let url: String
    var onOpen: (@MainActor @Sendable () -> Void)?

    public init(url: String, onOpen: (@MainActor @Sendable () -> Void)? = nil) {
        self.url = url
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sign in to Tailscale")
                .font(.headline)
                .fontWeight(.semibold)
            Text("Open this URL in your browser to sign in:")
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
            Text(url)
                .font(.callout)
                .textSelectionEnabled()
            if let onOpen {
                Button("Open in Browser", action: onOpen)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard()
    }
}

/// The sharing half of the hub: start or stop sharing this screen, say who is
/// watching, and answer anything that is asking for a decision.
///
/// The macOS app puts this in a menubar popover. Neither of the other two
/// platforms has that surface through swift-cross-ui, so it sits at the top of
/// the hub window instead, above the screen list, and one window covers both
/// directions.
///
/// `prompts` is why approvals and control requests are one control rather than
/// two: this window is the *only* surface these apps have — there is no
/// menubar to fall back on — so a prompt that is not rendered here is a prompt
/// nobody will ever answer, and the viewer on the other end waits forever.
///
/// `settings` is the other half of that argument. A prompt only appears if
/// something *asks*, and the switch that decides whether anyone has to ask —
/// "Require approval for new viewers" — has nowhere else to live either. A
/// card that can render the prompts but not the gate is a card where the gate
/// can only be off.
public struct ShareCard: View {
    let title: String
    let statusLine: String
    let isSharing: Bool
    let canShare: Bool
    let startLabel: String
    let stopLabel: String
    /// Secondary lines under the status — who is watching, where the frame
    /// time goes, why a capability is unavailable.
    let notes: [String]
    /// Who is currently watching, and what can be done about each of them.
    ///
    /// A structured roster rather than more `notes` lines, because this is the
    /// one place a sharer can change their mind about somebody already
    /// admitted. It sits ABOVE the notes and BELOW the prompts: a person
    /// waiting to be let in is more urgent than a person already watching,
    /// and both are more urgent than a frame-time statistic.
    let viewers: [HubViewerRow]
    let prompts: [HubPrompt]
    /// Persistent on/off controls for this share — today the approval gate.
    /// Rendered as the card's footer, below the prompts and notes: a setting
    /// is the least urgent thing on the card, and a viewer waiting to be let
    /// in is the most.
    let settings: [HubToggle]
    /// An extra action the current state calls for, e.g. taking control back.
    let extraAction: HubAction?
    let onStart: @MainActor @Sendable () -> Void
    let onStop: @MainActor @Sendable () -> Void
    let onAccept: @MainActor @Sendable (String) -> Void
    let onDecline: @MainActor @Sendable (String) -> Void

    public init(
        title: String = "My screen",
        statusLine: String,
        isSharing: Bool,
        canShare: Bool,
        startLabel: String = "Share my screen",
        stopLabel: String = "Stop sharing",
        notes: [String] = [],
        viewers: [HubViewerRow] = [],
        prompts: [HubPrompt] = [],
        settings: [HubToggle] = [],
        extraAction: HubAction? = nil,
        onStart: @escaping @MainActor @Sendable () -> Void,
        onStop: @escaping @MainActor @Sendable () -> Void,
        onAccept: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onDecline: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.title = title
        self.statusLine = statusLine
        self.isSharing = isSharing
        self.canShare = canShare
        self.startLabel = startLabel
        self.stopLabel = stopLabel
        self.notes = notes
        self.viewers = viewers
        self.prompts = prompts
        self.settings = settings
        self.extraAction = extraAction
        self.onStart = onStart
        self.onStop = onStop
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            VStack(alignment: .leading, spacing: 8) {
                Text(statusLine)
                    .font(.callout)
                    .foregroundColor(isSharing ? HubStyle.chipText : HubStyle.secondaryText)
                if canShare {
                    if isSharing {
                        Button(stopLabel, action: onStop)
                    } else {
                        Button(startLabel, action: onStart)
                    }
                }
                if let extraAction {
                    Button(extraAction.label, action: extraAction.perform)
                }
                ForEach(prompts, id: \.id) { prompt in
                    HStack(spacing: 8) {
                        Text(prompt.message)
                            .font(.caption)
                        Spacer()
                        Button(prompt.acceptLabel) { onAccept(prompt.id) }
                        Button(prompt.declineLabel) { onDecline(prompt.id) }
                    }
                }
                ForEach(viewers, id: \.id) { viewer in
                    HubViewerRowView(viewer: viewer)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { note in
                    Text(note.element)
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
                ForEach(Array(settings.enumerated()), id: \.offset) { setting in
                    VStack(alignment: .leading, spacing: 2) {
                        // The value and the setter are separate on the way in
                        // (see `HubToggle`) and are stitched back together
                        // here, because `Toggle` speaks only `Binding`. The
                        // getter closes over the value this render was built
                        // with, so the switch tracks the host's state rather
                        // than a copy of it that could drift.
                        Toggle(
                            setting.element.label,
                            isOn: Binding(
                                get: { setting.element.isOn },
                                set: { setting.element.set($0) })
                        )
                        // SwiftCrossUI defaults `toggleStyle` to `.button`,
                        // which draws a *button* that happens to be accented
                        // while on. On a settings row that is two mistakes:
                        // it invites a press as if it were an action, and its
                        // state is carried by a colour a glance can miss. A
                        // switch says "setting", and says which way it is set
                        // — which for the approval gate is the whole point.
                        .toggleStyle(.switch)
                        if let caption = setting.element.caption {
                            Text(caption)
                                .font(.caption)
                                .foregroundColor(HubStyle.secondaryText)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(HubStyle.cardFill))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
