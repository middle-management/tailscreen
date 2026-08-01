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
    let prompts: [HubPrompt]
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
        prompts: [HubPrompt] = [],
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
        self.prompts = prompts
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
                ForEach(Array(notes.enumerated()), id: \.offset) { note in
                    Text(note.element)
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(HubStyle.cardFill))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
