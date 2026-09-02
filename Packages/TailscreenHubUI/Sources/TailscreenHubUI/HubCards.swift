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
    /// A SECOND way to begin a share, when this host has one that the primary
    /// button cannot express — today "share one window or app", which on Linux
    /// needs the ScreenCast portal and so is not always available.
    ///
    /// Nil renders nothing, the capability-not-configuration rule the
    /// microphone and drawing slots already follow. Windows passes nil: its
    /// WGC picker already offers windows alongside displays, so a second
    /// button there would be a second door into the same room.
    let secondaryStart: HubAction?
    /// Re-point a LIVE share at something else without dropping the viewers
    /// already watching — the mirror of `secondaryStart`, offered beside Stop
    /// while sharing rather than beside Start while idle.
    ///
    /// Nil renders nothing, and that is a real state rather than a lazy
    /// default: an X11 session has exactly one thing it can capture (the root
    /// window), so there is nothing on that host for this button to change.
    let changeSource: HubAction?
    /// A thumbnail of what viewers are actually receiving. Nil renders nothing.
    ///
    /// It answers a question the status line cannot: "Sharing to 2" is equally
    /// true when the right window is on the wire and when the wrong one is, and
    /// on this platform the difference has been invisible to the one person who
    /// most needs to see it. It sits directly under the status line — above
    /// even the Stop button — because if it shows the wrong thing, stopping is
    /// what the next click is for.
    let preview: HubPreview?
    /// The share-by-token half, when this host's engine has it. Nil renders
    /// nothing — same capability rule as the microphone and drawing slots.
    let linkSharing: HubLinkSharing?
    /// The nuance under the headline — "Nobody watching yet", "1 waiting for
    /// approval". Separate from `statusLine` because the headline says the
    /// STATE and this says what is true about it right now, which is the
    /// macOS card's split (headline + resolution beneath). Nil renders
    /// nothing rather than an empty line.
    let statusDetail: String?
    let onStart: @MainActor @Sendable () -> Void
    let onStop: @MainActor @Sendable () -> Void
    let onAccept: @MainActor @Sendable (String) -> Void
    let onDecline: @MainActor @Sendable (String) -> Void

    public init(
        statusLine: String,
        statusDetail: String? = nil,
        isSharing: Bool,
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

    /// No section heading above the card, matching the macOS hub window: its
    /// share section opens straight on the dot and the headline, and only the
    /// peer list below carries a big "Screens" title. A heading here read as a
    /// second one stacked on the card's own — "My screen" over "Sharing your
    /// screen" — which is a label for something that has already said what it
    /// is.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            previewMat
            actionsRow
            if let extraAction {
                Button(extraAction.label, action: extraAction.perform)
            }
            drawingCluster
            peopleCluster
            linkCluster
            settingsCluster
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Green while live — the macOS sharer card's identity, and the
        // strongest at-a-glance answer to "is my screen going out".
        .hubCard(
            fill: isSharing ? HubStyle.sharingCardFill : HubStyle.cardFill,
            stroke: isSharing ? HubStyle.sharingCardStroke : HubStyle.cardStroke)
    }

    /// The macOS card's header: a live dot, the state as a headline, the
    /// viewer count as a pill, and the nuance underneath.
    ///
    /// The count is a pill rather than words in the status line because it is
    /// the one number a sharer re-reads mid-share, and because it belongs to
    /// the *people* half of the card — the roster below spells out who they
    /// are. Nothing here relies on colour alone: the dot has a headline
    /// beside it and the pill has a number in it.
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

    /// The preview on a dark rounded mat, at its own aspect ratio, with the
    /// macOS card's "Capturing…" placeholder holding the space until the
    /// first thumbnail lands.
    ///
    /// `fittedSize` (the scaler's own fit) rather than a fixed frame: the
    /// capture can be any shape — a portrait monitor, one narrow window — and
    /// stretching it to a 16:10 box would show viewers something the wire
    /// does not carry. It also never scales up, so a thumbnail from an older
    /// host renders at its natural size instead of as a blur.
    @ViewBuilder private var previewMat: some View {
        if let preview, let image = preview.image,
            let fitted = ThumbnailScaler.fittedSize(
                width: preview.width, height: preview.height,
                longestEdge: ThumbnailScaler.defaultLongestEdge)
        {
            // Rounded like the macOS card's `clipShape(RoundedRectangle)`,
            // and with nothing behind it: a mat around the image reads as a
            // bevel, and the capture is opaque so there is nothing to bed it
            // on. Both backends implement `cornerRadius` natively.
            Image(image)
                .resizable()
                .frame(width: Double(fitted.width), height: Double(fitted.height))
                .cornerRadius(Int(HubStyle.rowRadius))
        } else if isSharing {
            // Sharing with nothing to show yet. A placeholder rather than
            // nothing, so the card does not visibly jump when the first
            // thumbnail arrives a moment later — and so a backend that never
            // produces one says why it looks empty.
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
    /// while sharing, the one or two ways to start while idle. A row rather
    /// than a stack because these are peers of one decision — what is on the
    /// wire — and a column of lone buttons read as unrelated features.
    ///
    /// Stop goes LAST, as it does on the macOS card: it is the one control
    /// here whose press is felt immediately by everyone watching, so it does
    /// not sit where a hand aiming for the microphone lands.
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
                } else {
                    Button(startLabel, action: onStart)
                    // Only while idle: mid-share this would start a second
                    // one, and the card has a Stop button in that state
                    // precisely because there is already something to stop.
                    if let secondaryStart {
                        Button(secondaryStart.label, action: secondaryStart.perform)
                    }
                }
                Spacer()
            }
        }
    }

    /// The drawing tools on a subtle sub-panel, their caption beneath. The
    /// panel exists so ten glyph buttons across two rows read as one control
    /// group rather than scattered card content.
    @ViewBuilder private var drawingCluster: some View {
        if let drawing {
            VStack(alignment: .leading, spacing: 6) {
                // `.twoRows`: a single row of these buttons is wider than the
                // hub window, and a card child wider than the window makes
                // swift-cross-ui clip every label in the card — see
                // `AnnotationToolbar.Arrangement`.
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
                // The caption is load-bearing rather than decorative:
                // arming a tool hands the whole screen to a
                // click-through-no-longer overlay, so the way back has
                // to be on screen BEFORE it is needed — once armed,
                // this window is behind the overlay and unreadable.
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

    /// The people: viewers waiting at the gate (or asking for control, or
    /// asking this machine to share) first, then everyone watching. Behind a
    /// divider because these rows are about *others* where everything above
    /// is about this machine — and each on its own row card, two lines, so
    /// the name is never crowded out by its own buttons.
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
                            // The answer admits someone from OUTSIDE the
                            // tailnet — said at the moment of deciding.
                            HubGuestChip()
                        }
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        Button(prompt.acceptLabel) { onAccept(prompt.id) }
                        Button(prompt.declineLabel) { onDecline(prompt.id) }
                        Spacer()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Amber, like the macOS pending-viewer list: this is the one
                // row in the card that is waiting on an answer, and it must
                // not look like the rows that are merely reporting.
                .background(
                    RoundedRectangle(cornerRadius: HubStyle.rowRadius)
                        .fill(HubStyle.attentionFill))
            }
            ForEach(viewers, id: \.id) { viewer in
                HubViewerRowView(viewer: viewer)
            }
        }
    }

    /// The share-by-token controls: the Share via Link toggle, and — while a
    /// link is live — the link itself as selectable text (these toolkits have
    /// no clipboard affordance, and a link you can select and paste always
    /// works — the `HubLoginCard` lesson), the guest count, New Link, and the
    /// consent caption. Only while sharing: the link is minted per share and
    /// dies with it, so an idle card has nothing honest to show here.
    @ViewBuilder private var linkCluster: some View {
        if isSharing, let linkSharing {
            Divider()
            Toggle(
                L("Share via Link"),
                isOn: Binding(
                    get: { linkSharing.token != nil || linkSharing.busy },
                    set: { linkSharing.onToggle($0) })
            )
            .toggleStyle(.switch)
            if linkSharing.busy {
                Text(L("Creating link…"))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
            } else if let token = linkSharing.token {
                Text(ShareLinkFormat.link(token: token))
                    .font(.caption)
                    .textSelectionEnabled()
                // The browser form: same token, opens in any browser, no app.
                Text(ShareLinkFormat.webLink(token: token))
                    .font(.caption)
                    .textSelectionEnabled()
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

    private var guestCountLine: String {
        switch linkSharing?.guestCount ?? 0 {
        case 0: return L("No guests yet")
        case 1: return L("1 guest")
        case let n: return L("\(n) guests")
        }
    }

    /// Notes, the approval gate, and quality — the standing configuration,
    /// behind a divider so it reads as the card's footer rather than more
    /// controls for the live share.
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

/// A thumbnail of the frame viewers are currently receiving.
///
/// Raw packed RGBA rather than an encoded image, because the two hosts that
/// render it have no image encoder between them and their capture backends —
/// on macOS the preview crosses a process boundary and is JPEG for that reason,
/// and there is no boundary here to pay for. `ThumbnailScaler` produces exactly
/// this, already scaled and already channel-swapped.
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
    /// an image.
    ///
    /// The length check is not defensive habit: `Image` hands these bytes to a
    /// backend that reads `width * height * 4` of them, so a buffer that is
    /// short reads past the end of an array. Refusing to render is the only
    /// answer to that which is not a crash in somebody's toolkit.
    var image: ImageFormats.Image<RGBA>? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        return ImageFormats.Image<RGBA>(width: width, height: height, bytes: rgba)
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
