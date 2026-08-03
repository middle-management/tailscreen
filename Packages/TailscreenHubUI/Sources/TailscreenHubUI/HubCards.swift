import SwiftCrossUI
import TailscreenProtocol

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
    /// The quality knobs, when this host offers them. Nil renders no menu —
    /// a viewer-only build has nothing to set.
    let quality: HubQuality?
    /// An extra action the current state calls for, e.g. taking control back.
    let extraAction: HubAction?
    /// The sharer's microphone, when a device was opened for this share.
    ///
    /// Nil renders nothing — the same capability rule the viewer's control
    /// follows, and the reason this is not a `HubToggle` in `settings`: a
    /// setting persists and is the least urgent thing on the card, whereas
    /// talking is a live session control that belongs beside Stop Sharing.
    let microphone: HubMicrophone?
    /// The sharer's own drawing tools, when this host can put strokes on its
    /// own screen. Nil renders nothing.
    let drawing: HubDrawing?
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
        quality: HubQuality? = nil,
        extraAction: HubAction? = nil,
        microphone: HubMicrophone? = nil,
        drawing: HubDrawing? = nil,
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
        self.quality = quality
        self.extraAction = extraAction
        self.microphone = microphone
        self.drawing = drawing
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
                if let microphone {
                    MicrophoneButton(
                        isOn: microphone.isOn, onToggle: microphone.toggle)
                }
                if let drawing {
                    VStack(alignment: .leading, spacing: 2) {
                        AnnotationToolbar(
                            activeTool: drawing.activeTool,
                            inkColor: drawing.inkColor,
                            showsStats: false,
                            onSelectTool: drawing.selectTool,
                            onUndo: drawing.undo,
                            onClear: drawing.clear)
                        // The caption is load-bearing rather than decorative:
                        // arming a tool hands the whole screen to a
                        // click-through-no-longer overlay, so the way back has
                        // to be on screen BEFORE it is needed — once armed,
                        // this window is behind the overlay and unreadable.
                        Text(drawing.note ?? (drawing.activeTool == nil
                            ? "Drawing takes over the screen; Esc gives it back"
                            : "Press Esc to stop drawing"))
                            .font(.caption)
                            .foregroundColor(HubStyle.secondaryText)
                    }
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
                if let quality {
                    VStack(alignment: .leading, spacing: 2) {
                        HubQualityMenu(model: quality)
                        // The caption is where the honesty lives. These knobs
                        // are read when a share STARTS — the capture backend
                        // takes them at construction on both hosts — so a
                        // change made mid-share does nothing until the next
                        // one. Saying so beats a menu that appears to work and
                        // silently doesn't. (macOS re-pushes through its
                        // helper-restart path; neither of these hosts has one.)
                        Text(
                            quality.isSharing
                                ? "Applies to your next share"
                                : (quality.settings.preset.hubCaption ?? "Custom settings")
                        )
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
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


/// The sharer's live microphone, as the share card needs it.
///
/// A value, not a binding: swift-cross-ui rebuilds the card from the host's
/// state on every change, so the button reads the value this render was built
/// with and reports the press back through `toggle` — the same shape
/// `HubToggle` uses, and for the same reason.
public struct HubMicrophone: Sendable {
    public let isOn: Bool
    public let toggle: @MainActor @Sendable () -> Void

    public init(isOn: Bool, toggle: @escaping @MainActor @Sendable () -> Void) {
        self.isOn = isOn
        self.toggle = toggle
    }
}


/// The sharer's own drawing tools, as the share card needs them.
///
/// Values plus callbacks, like `HubMicrophone` and `HubToggle`, because
/// swift-cross-ui rebuilds the card from the host's state on every change.
public struct HubDrawing: Sendable {
    public let activeTool: AnnotationTool?
    /// The colour this sharer's strokes appear in — identity-derived, like
    /// every participant's.
    public let inkColor: Annotation.RGBA
    /// Why drawing is unavailable or refused, when it is. Nil renders the
    /// ordinary hint instead.
    public let note: String?
    public let selectTool: @MainActor @Sendable (AnnotationTool) -> Void
    public let undo: @MainActor @Sendable () -> Void
    public let clear: @MainActor @Sendable () -> Void

    public init(
        activeTool: AnnotationTool?,
        inkColor: Annotation.RGBA,
        note: String? = nil,
        selectTool: @escaping @MainActor @Sendable (AnnotationTool) -> Void,
        undo: @escaping @MainActor @Sendable () -> Void,
        clear: @escaping @MainActor @Sendable () -> Void
    ) {
        self.activeTool = activeTool
        self.inkColor = inkColor
        self.note = note
        self.selectTool = selectTool
        self.undo = undo
        self.clear = clear
    }
}
