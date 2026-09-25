import ImageFormats
import SwiftCrossUI
import TailscreenL10n
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
/// URL shown as selectable text, not just behind the button: launching a
/// browser is the part most likely to fail on a locked-down/remote machine.
public struct HubLoginCard: View {
    let url: String
    var onOpen: (@MainActor @Sendable () -> Void)?

    public init(url: String, onOpen: (@MainActor @Sendable () -> Void)? = nil) {
        self.url = url
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Sign in to Tailscale"))
                .font(.headline)
                .fontWeight(.semibold)
            Text(L("Open this URL in your browser to sign in:"))
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
            Text(url)
                .font(.callout)
                .textSelectionEnabled()
            if let onOpen {
                Button(L("Open in Browser"), action: onOpen)
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
/// macOS puts this in a menubar popover; GTK/WinUI have no such surface, so it
/// sits atop the hub window instead. `prompts` and `settings` both render here
/// because this window is the *only* surface those two hosts have — a prompt
/// or gate not rendered here is one nobody can ever answer or flip.
public struct ShareCard: View {
    let statusLine: String
    let isSharing: Bool
    /// A share is coming up but not live yet — `ShareBringUpPhase.starting`.
    /// Only the action row reads it, to render neither Start nor Stop (both
    /// hosts gate Start on `canStart`, which `starting` fails). Live styling
    /// still keys off `isSharing`, not this — no green until frames flow.
    let isStarting: Bool
    let canShare: Bool
    let startLabel: String
    let stopLabel: String
    /// Secondary lines under the status — who is watching, where the frame
    /// time goes, why a capability is unavailable.
    let notes: [String]
    /// Who is currently watching, and what can be done about each of them.
    /// Renders above notes, below prompts — approvals waiting are the most
    /// urgent, then people already watching, then statistics.
    let viewers: [HubViewerRow]
    let prompts: [HubPrompt]
    /// Persistent on/off controls for this share — today the approval gate.
    /// Rendered as the card's footer: least urgent thing on the card.
    let settings: [HubToggle]
    /// The quality knobs, when this host offers them. Nil renders no menu —
    /// a viewer-only build has nothing to set.
    let quality: HubQuality?
    /// An extra action the current state calls for, e.g. taking control back.
    let extraAction: HubAction?
    /// The sharer's microphone, when a device was opened for this share. Not
    /// a `HubToggle`/`settings` entry: talking is a live session control that
    /// belongs beside Stop Sharing, not the persisted-settings footer.
    let microphone: HubMicrophone?
    /// The sharer's own drawing tools, when this host can put strokes on its
    /// own screen. Nil renders nothing.
    let drawing: HubDrawing?
    /// A second way to begin a share when the primary button can't express it
    /// — today "share one window or app" (Linux, via the ScreenCast portal;
    /// not always available). Nil ⇒ no such option. Windows passes nil: its
    /// WGC picker already offers windows alongside displays.
    let secondaryStart: HubAction?
    /// Re-point a LIVE share without dropping current viewers — the mirror of
    /// `secondaryStart`, beside Stop rather than Start. Nil is a real state:
    /// an X11 session can only ever capture the root window.
    let changeSource: HubAction?
    /// A thumbnail of what viewers are actually receiving, so "Sharing to 2"
    /// can be checked against what's really on the wire. Sits directly under
    /// the status line — above Stop, since a wrong thumbnail means stopping.
    /// Nil renders nothing.
    let preview: HubPreview?
    /// The share-by-token half, when this host's engine has it. Nil renders
    /// nothing — same capability rule as the microphone and drawing slots.
    let linkSharing: HubLinkSharing?
    /// The nuance under the headline — "Nobody watching yet", "1 waiting for
    /// approval". Separate from `statusLine` (state vs. detail), matching the
    /// macOS card's split. Nil renders nothing rather than an empty line.
    let statusDetail: String?
    let onStart: @MainActor @Sendable () -> Void
    let onStop: @MainActor @Sendable () -> Void
    let onAccept: @MainActor @Sendable (String) -> Void
    let onDecline: @MainActor @Sendable (String) -> Void

    public init(
        statusLine: String,
        statusDetail: String? = nil,
        isSharing: Bool,
        isStarting: Bool = false,
        canShare: Bool,
        startLabel: String = L("Share my screen"),
        stopLabel: String = L("Stop Sharing"),
        notes: [String] = [],
        viewers: [HubViewerRow] = [],
        prompts: [HubPrompt] = [],
        settings: [HubToggle] = [],
        quality: HubQuality? = nil,
        extraAction: HubAction? = nil,
        microphone: HubMicrophone? = nil,
        drawing: HubDrawing? = nil,
        secondaryStart: HubAction? = nil,
        changeSource: HubAction? = nil,
        preview: HubPreview? = nil,
        linkSharing: HubLinkSharing? = nil,
        onStart: @escaping @MainActor @Sendable () -> Void,
        onStop: @escaping @MainActor @Sendable () -> Void,
        onAccept: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onDecline: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.statusLine = statusLine
        self.isSharing = isSharing
        self.isStarting = isStarting
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
        self.secondaryStart = secondaryStart
        self.changeSource = changeSource
        self.preview = preview
        self.linkSharing = linkSharing
        self.statusDetail = statusDetail
        self.onStart = onStart
        self.onStop = onStop
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    /// No section heading above the card, matching the macOS hub window —
    /// only the peer list below carries a "Screens" title.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            previewMat
            actionsRow
            if let extraAction {
                Button(extraAction.label, action: extraAction.perform)
            }
            peopleCluster
            linkCluster
            drawingCluster
            settingsCluster
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Green while live — at-a-glance answer to "is my screen going out".
        .hubCard(
            fill: isSharing ? HubStyle.sharingCardFill : HubStyle.cardFill,
            stroke: isSharing ? HubStyle.sharingCardStroke : HubStyle.cardStroke)
    }

    /// The macOS card's header: a live dot, the state as a headline, the
    /// viewer count as a pill, and the nuance underneath. Nothing relies on
    /// colour alone — the dot has a headline beside it, the pill a number.
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                if isSharing {
                    Circle()
                        .fill(HubStyle.online)
                        .frame(width: 9, height: 9)
                }
                Text(statusLine)
                    .font(.headline)
                    .foregroundColor(isSharing ? HubStyle.chipText : HubStyle.secondaryText)
                if isSharing && !viewers.isEmpty {
                    Text("\(viewers.count)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(HubStyle.countPillFill))
                }
                Spacer()
            }
            if let statusDetail {
                Text(statusDetail)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
            }
        }
    }

    /// The preview at its own aspect ratio via `fittedSize` rather than a
    /// fixed frame: the capture can be any shape (portrait monitor, narrow
    /// window), and it never scales up, so an older host's thumbnail renders
    /// at natural size instead of blurred.
    @ViewBuilder private var previewMat: some View {
        if let preview, let image = preview.image,
            let fitted = ThumbnailScaler.fittedSize(
                width: preview.width, height: preview.height,
                longestEdge: ThumbnailScaler.defaultLongestEdge)
        {
            Image(image)
                .resizable()
                .frame(width: Double(fitted.width), height: Double(fitted.height))
                .cornerRadius(Int(HubStyle.rowRadius))
        } else if isSharing {
            // Placeholder so the card doesn't jump when the first thumbnail lands.
            Text(L("Capturing…"))
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: HubStyle.rowRadius).fill(HubStyle.previewWell))
        }
    }

    /// The share's controls on one row: change source / microphone / Stop
    /// while sharing, the one or two ways to start while idle. Stop goes
    /// last, as on the macOS card, so a hand aiming for the microphone
    /// doesn't land on it — Stop's press is felt by everyone watching.
    @ViewBuilder private var actionsRow: some View {
        if canShare {
            HStack(spacing: 8) {
                if isSharing {
                    if let changeSource {
                        Button(changeSource.label, action: changeSource.perform)
                    }
                    if let microphone {
                        MicrophoneButton(
                            isOn: microphone.isOn, floating: false,
                            onToggle: microphone.toggle)
                    }
                    Button(stopLabel, action: onStop)
                } else if !isStarting {
                    Button(startLabel, action: onStart)
                    // Only while idle — mid-share this would start a second one.
                    if let secondaryStart {
                        Button(secondaryStart.label, action: secondaryStart.perform)
                    }
                }
                Spacer()
            }
        }
    }

    /// The drawing tools on a subtle sub-panel, their caption beneath.
    @ViewBuilder private var drawingCluster: some View {
        if let drawing {
            VStack(alignment: .leading, spacing: 6) {
                // `.twoRows`: a single row is wider than the hub window, which
                // makes swift-cross-ui clip every label — see `AnnotationToolbar.Arrangement`.
                AnnotationToolbar(
                    activeTool: drawing.activeTool,
                    inkColor: drawing.inkColor,
                    arrangement: .twoRows,
                    showsStats: false,
                    onSelectTool: drawing.selectTool,
                    onUndo: drawing.undo,
                    onClear: drawing.clear
                )
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: HubStyle.rowRadius).fill(HubStyle.barFill))
                // Load-bearing: arming a tool puts an overlay over this
                // window, so the way back must be visible BEFORE it's needed.
                Text(
                    drawing.note
                        ?? (drawing.activeTool == nil
                            ? L("Drawing takes over the screen; Esc gives it back")
                            : L("Press Esc to stop drawing"))
                )
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
            }
        }
    }

    /// Pending prompts first, then everyone watching, behind a divider —
    /// everything above this is about this machine, these rows about others.
    @ViewBuilder private var peopleCluster: some View {
        if !prompts.isEmpty || !viewers.isEmpty {
            Divider()
            ForEach(prompts, id: \.id) { prompt in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(prompt.message)
                            .font(.callout)
                            .fontWeight(.bold)
                        if prompt.isGuest {
                            // Flags that this admits someone outside the tailnet.
                            HubGuestChip()
                        }
                        Spacer()
                    }
                    if let detail = prompt.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(HubStyle.secondaryText)
                    }
                    HStack(spacing: 6) {
                        Button(prompt.acceptLabel) { onAccept(prompt.id) }
                        Button(prompt.declineLabel) { onDecline(prompt.id) }
                        Spacer()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Amber, like the macOS pending-viewer list — waiting on an answer.
                .background(
                    RoundedRectangle(cornerRadius: HubStyle.rowRadius)
                        .fill(HubStyle.attentionFill))
            }
            ForEach(viewers, id: \.id) { viewer in
                HubViewerRowView(viewer: viewer)
            }
        }
    }

    /// The share-by-token controls: the toggle, and while a link is live, the
    /// link as selectable text (no clipboard affordance in these toolkits),
    /// guest count, New Link, and consent caption. Only while sharing — the
    /// link is minted per share and dies with it.
    @ViewBuilder private var linkCluster: some View {
        if isSharing, let linkSharing {
            Divider()
            if linkSharing.isOnlyWayIn {
                // Link-only share IS its link — no off position short of Stop
                // Sharing, so state the mode instead of a toggle that can't flip.
                Text(L("Sharing via link — the link is the only way in"))
                    .font(.callout)
                    .foregroundColor(HubStyle.secondaryText)
            } else {
                Toggle(
                    L("Share via Link"),
                    isOn: Binding(
                        get: { linkSharing.token != nil || linkSharing.busy },
                        set: { linkSharing.onToggle($0) })
                )
                .toggleStyle(.switch)
            }
            if linkSharing.busy {
                Text(L("Creating link…"))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
            } else if let token = linkSharing.token {
                linkBody(token: token, copy: linkSharing.onCopy)
                Text(guestCountLine)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                if let onNewLink = linkSharing.onNewLink {
                    Button(L("New Link"), action: onNewLink)
                }
                Text(
                    L(
                        "Anyone with the link can ask to join; you approve each guest. The link stops working when sharing stops."
                    )
                )
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
            }
        }
    }

    /// The link, in whichever form this host can hand over. With a clipboard:
    /// one truncated line plus buttons for the `tailscreen:` link, the
    /// `https:` fallback, and the bare token. Without one: both links in
    /// full, selectable text.
    ///
    /// Takes the closure as a parameter rather than reading `linkSharing`
    /// inline — an `if let` over a captured optional closure nested this deep
    /// is a shape swift-cross-ui's result builder typechecks badly.
    @ViewBuilder private func linkBody(
        token: String, copy: (@MainActor @Sendable (String) -> Void)?
    ) -> some View {
        if let copy {
            Text(ShareLinkFormat.link(token: token))
                .font(.caption)
                .lineLimit(1)
                .textSelectionEnabled()
            HStack(spacing: 6) {
                Button(L("Copy Link")) { copy(ShareLinkFormat.link(token: token)) }
                Button(L("Copy Web Link")) { copy(ShareLinkFormat.webLink(token: token)) }
                Button(L("Copy Token")) { copy(token) }
                Spacer()
            }
        } else {
            Text(ShareLinkFormat.link(token: token))
                .font(.caption)
                .textSelectionEnabled()
            // Browser form: same token, opens in any browser, no app.
            Text(ShareLinkFormat.webLink(token: token))
                .font(.caption)
                .textSelectionEnabled()
        }
    }

    private var guestCountLine: String {
        switch linkSharing?.guestCount ?? 0 {
        case 0: return L("No guests yet")
        case 1: return L("1 guest")
        case let n: return L("\(n) guests")
        }
    }

    /// Notes, the approval gate, and quality — standing configuration, behind
    /// a divider so it reads as the card's footer.
    @ViewBuilder private var settingsCluster: some View {
        if !notes.isEmpty || !settings.isEmpty || quality != nil {
            Divider()
            ForEach(Array(notes.enumerated()), id: \.offset) { note in
                Text(note.element)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
            }
            ForEach(Array(settings.enumerated()), id: \.offset) { setting in
                VStack(alignment: .leading, spacing: 2) {
                    // `HubToggle` separates value from setter; `Toggle` wants
                    // a `Binding`, stitched back together here.
                    Toggle(
                        setting.element.label,
                        isOn: Binding(
                            get: { setting.element.isOn },
                            set: { setting.element.set($0) })
                    )
                    // SwiftCrossUI's default `.button` style reads as a
                    // pressable action with state carried only by colour; a
                    // switch says "setting" and shows which way it's set.
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
                    // These knobs are read at share start (capture backend
                    // takes them at construction on both hosts), so a
                    // mid-share change does nothing until the next share.
                    Text(
                        quality.isSharing
                            ? L("Applies to your next share")
                            : (quality.settings.preset.hubCaption ?? L("Custom settings"))
                    )
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                }
            }
        }
    }
}

/// A thumbnail of the frame viewers are currently receiving. Raw packed RGBA
/// rather than an encoded image: neither host has an image encoder between
/// it and its capture backend. `ThumbnailScaler` produces this, already
/// scaled and channel-swapped.
public struct HubPreview: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, R,G,B,A per pixel.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// The pixels as swift-cross-ui wants them, or nil if they do not describe
    /// an image. The length check matters: `Image` hands these bytes to a
    /// backend that reads `width * height * 4` of them, so a short buffer
    /// reads past the array's end.
    var image: ImageFormats.Image<RGBA>? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        return ImageFormats.Image<RGBA>(width: width, height: height, bytes: rgba)
    }
}

/// The sharer's live microphone, as the share card needs it. A value, not a
/// binding — swift-cross-ui rebuilds the card from host state each change, so
/// the button reports the press back through `toggle`, like `HubToggle`.
public struct HubMicrophone: Sendable {
    public let isOn: Bool
    public let toggle: @MainActor @Sendable () -> Void

    public init(isOn: Bool, toggle: @escaping @MainActor @Sendable () -> Void) {
        self.isOn = isOn
        self.toggle = toggle
    }
}

/// The sharer's own drawing tools, as the share card needs them. Values plus
/// callbacks, like `HubMicrophone` and `HubToggle`.
public struct HubDrawing: Sendable {
    public let activeTool: AnnotationTool?
    /// The colour this sharer's strokes appear in — identity-derived.
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
