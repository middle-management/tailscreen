import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// Annotation toolbar, mirroring the macOS viewer's `NSToolbar`: a
/// radio-selected tool group in the same order — pen, line, arrow, rect, oval,
/// click — then Undo, Clear and a Stats toggle. Shown only when the sharer
/// advertised `ScreenShareCaps.annotations`.
///
/// Two callers, two shapes (see `Arrangement`): pinned across the top of a
/// viewer window, and stacked inside the sharer's share card, where the window
/// is far narrower than a video.
///
/// Differences from the macOS toolbar, and why:
///   • Unicode geometric glyphs instead of SF Symbols (Apple-only). GTK's own
///     named icon theme was the first choice — swift-cross-ui's `Gtk.Button`
///     even takes an `iconName` — but it is an app-chrome set with no line /
///     rectangle / oval / pointer icons, so half the tool group would have
///     fallen back anyway, and nothing equivalent exists on Windows. These
///     glyphs render from the system font on both.
///
///     They do not match each other especially well, and that is inherent:
///     the six come from four Unicode blocks (box-drawing `╱`, geometric
///     shapes `▭ ◯`, dingbats `✎ ✕`, arrows `↗ ↶`), drawn at different
///     weights and optical sizes by their designers. Two ways out were
///     costed and both are currently worse:
///       - SVG assets: swift-cross-ui's `Image` decodes png/jpg/webp or raw
///         RGBA only. There is no SVG decoder in the graph.
///       - Vector icons drawn natively: entirely possible — the public
///         `Shape`/`Path` API has béziers, arcs and stroke caps/joins, and
///         both backends render it. But `Button` takes a `String` label and
///         nothing else ("a temporary solution until arbitrary labels are
///         supported", says its own doc), there are no button styles to
///         make one transparent, and an overlaid shape swallows clicks on
///         WinUI (see `hubCard`). So an icon tool would have to be a bare
///         `Shape` + `onTapGesture` — and GTK's tap target is a
///         `GestureClick` controller on the child widget, which is not
///         focusable. That trades every tool button's keyboard and
///         screen-reader access for looks, on a toolbar whose armed state
///         takes over the screen and whose way out is a keypress.
///     Revisit when swift-cross-ui supports arbitrary button labels; the
///     icons become free then, with nothing given up.
///   • The armed tool is bracketed rather than highlighted: swift-cross-ui has
///     no segmented control, so radio selection has to be spelled in the label.
///   • The color picker is a `Menu` of named rows with the current color
///     checked, beside a swatch showing it: a swift-cross-ui menu label is a
///     String, so the macOS toolbar's swatch-icon menu (`makeColorMenu`)
///     becomes name-plus-checkmark here. Identity still seeds the DEFAULT
///     color; a pick overrides it, and per-stroke color rides the annotation
///     wire (`Annotation.color`) exactly as on macOS.
public struct AnnotationToolbar: View {
    /// Tool order — matches the macOS `ViewerToolbar.toolOrder` exactly.
    /// Glyphs: pencil, diagonal, arrow, rectangle, ellipse, target.
    public static let tools: [(tool: AnnotationTool, glyph: String, name: String)] = [
        (.pen, "✎", L("Pen")), (.line, "╱", L("Line")), (.arrow, "↗", L("Arrow")),
        (.rectangle, "▭", L("Rect")), (.oval, "◯", L("Oval")), (.click, "◎", L("Click"))
    ]

    /// Localized names for `Annotation.RGBA.palette`, index-aligned with it —
    /// the same eight names (and catalog keys) the macOS color menu speaks, so
    /// a color is called the same thing on every platform.
    public static let paletteColorNames: [String] = [
        L("Red"), L("Blue"), L("Green"), L("Orange"),
        L("Purple"), L("Teal"), L("Pink"), L("Yellow")
    ]

    /// The palette with its spoken names, zipped so a palette edit that
    /// forgets a name can never index out of range.
    static var paletteRows: [(name: String, color: Annotation.RGBA)] {
        zip(paletteColorNames, Annotation.RGBA.palette).map { (name: $0.0, color: $0.1) }
    }

    /// How the controls are laid out.
    ///
    /// `.singleRow` is the over-video bar this toolbar was born as: one
    /// full-width strip at a fixed height, viable because a video window is
    /// as wide as the video. `.twoRows` exists for the share card, whose
    /// window is hub-narrow (460 pt by default): a single row of ten buttons
    /// is wider than that window, and a child wider than the window does not
    /// merely clip — swift-cross-ui's GTK layout squeezes every *other* label
    /// in the card to make room, so the whole card renders with its text cut
    /// off at the left. Tools on the first row, color/undo/clear on the
    /// second, and the row hugs its content instead of claiming the bar
    /// height.
    public enum Arrangement: Sendable {
        case singleRow
        case twoRows
    }

    /// The armed tool, or nil when drawing is off (pointer drags then zoom/pan
    /// or drive remote control).
    let activeTool: AnnotationTool?
    /// This viewer's assigned stroke color (identity-derived, not chosen).
    let inkColor: Annotation.RGBA
    let arrangement: Arrangement
    let statsShown: Bool
    /// Whether to offer the stats toggle at all.
    ///
    /// False on the SHARER, which reuses this toolbar to draw on its own
    /// screen: there is no decoded video on that side and therefore no
    /// resolution or fps to show, so the button would open an empty HUD.
    let showsStats: Bool
    let onSelectTool: @MainActor @Sendable (AnnotationTool) -> Void
    /// Pick a drawing color from the palette menu. Nil renders the swatch
    /// alone, read-only — the sharer's card keeps its identity-derived color.
    let onSelectColor: (@MainActor @Sendable (Annotation.RGBA) -> Void)?
    let onUndo: @MainActor @Sendable () -> Void
    let onClear: @MainActor @Sendable () -> Void
    let onToggleStats: @MainActor @Sendable () -> Void

    public init(
        activeTool: AnnotationTool?,
        inkColor: Annotation.RGBA,
        arrangement: Arrangement = .singleRow,
        statsShown: Bool = false,
        showsStats: Bool = true,
        onSelectTool: @escaping @MainActor @Sendable (AnnotationTool) -> Void,
        onSelectColor: (@MainActor @Sendable (Annotation.RGBA) -> Void)? = nil,
        onUndo: @escaping @MainActor @Sendable () -> Void,
        onClear: @escaping @MainActor @Sendable () -> Void,
        onToggleStats: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.activeTool = activeTool
        self.inkColor = inkColor
        self.arrangement = arrangement
        self.statsShown = statsShown
        self.showsStats = showsStats
        self.onSelectTool = onSelectTool
        self.onSelectColor = onSelectColor
        self.onUndo = onUndo
        self.onClear = onClear
        self.onToggleStats = onToggleStats
    }

    /// The radio-selected tool group, shared by both arrangements.
    private var toolButtons: some View {
        ForEach(Array(Self.tools.enumerated()), id: \.offset) { item in
            let isActive = activeTool == item.element.tool
            Button(isActive ? "[\(item.element.glyph)]" : " \(item.element.glyph) ") {
                onSelectTool(item.element.tool)
            }
            // The name the mac toolbar shows as a label; here it is the
            // hover answer to six otherwise-unlabelled marks.
            .help(item.element.name)
        }
    }

    /// The swatch says which color this viewer draws in; the menu beside it
    /// changes it. Split in two because a swift-cross-ui menu label is a
    /// String — the current color cannot ride the label the way the macOS
    /// item's swatch icon does.
    private var colorSwatch: some View {
        Circle()
            .fill(
                Color(
                    red: inkColor.r, green: inkColor.g, blue: inkColor.b,
                    opacity: inkColor.a)
            )
            .frame(width: 16, height: 16)
    }

    @ViewBuilder private var colorMenu: some View {
        if let onSelectColor {
            Menu(L("Color")) {
                // Checked rows over `Toggle`, the proven mapping the
                // header's filter menu uses (GTK: stateful GSimpleAction,
                // WinUI: ToggleMenuFlyoutItem). Re-picking the current
                // color is ignored rather than treated as "no color" —
                // the palette is a radio group, not a bank of switches.
                ForEach(Array(Self.paletteRows.enumerated()), id: \.offset) { row in
                    Toggle(
                        row.element.name,
                        isOn: Binding(
                            get: { row.element.color == inkColor },
                            set: { isOn in
                                if isOn { onSelectColor(row.element.color) }
                            }))
                }
            }
        }
    }

    public var body: some View {
        if arrangement == .twoRows {
            // The share card's block: tools on one row, color/undo/clear on
            // the next, hugging content. No bar background or fixed height —
            // inside a card these sit like any other control cluster, and the
            // whole point of the split is that neither row outgrows a
            // hub-narrow window.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    toolButtons
                    Spacer()
                }
                HStack(spacing: 6) {
                    // Chipped, unlike the single-row bar's bare dot: there the
                    // swatch sits against a "Color" menu that gives it a
                    // reason to be round and small. Here the sharer's ink is
                    // fixed, so the swatch is on its own — and a lone dot
                    // beside two buttons reads as a stray mark rather than
                    // "this is the colour you draw in".
                    colorSwatch
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(HubStyle.rowFill))
                        .help(L("Your drawing colour"))
                    colorMenu
                    Button("↶", action: onUndo)
                    Button("✕", action: onClear)
                    if showsStats {
                        Button(statsShown ? L("Hide stats") : L("Stats"), action: onToggleStats)
                    }
                    Spacer()
                }
            }
        } else {
            HStack(spacing: 6) {
                toolButtons
                Divider()
                colorSwatch
                colorMenu
                Divider()
                Button("↶", action: onUndo)
                Button("✕", action: onClear)
                if showsStats {
                    // Worded, not a glyph, and behind a divider. As `▤` at the
                    // end of a row of drawing glyphs it read as a seventh
                    // drawing tool and was reported as a missing feature by
                    // someone looking straight at it. The no-annotations
                    // fallback in the Windows app has always spelled it out;
                    // these now match.
                    Divider()
                    Button(statsShown ? L("Hide stats") : L("Stats"), action: onToggleStats)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            // Fixed height so the row hugs its buttons; without it the
            // enclosing VStack hands the toolbar an equal share of the window
            // and squeezes the video.
            .frame(height: Double(HubStyle.toolbarHeight))
            .frame(maxWidth: .infinity)
            .background(HubStyle.barFill)
        }
    }
}

/// Small translucent stats pill over the video (top-left): resolution + fps.
public struct StatsHUD: View {
    let width: Int
    let height: Int
    let fps: Int

    public init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    public var body: some View {
        Text(L("\(width)×\(height) · \(fps) fps"))
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0, opacity: 0.55)))
    }
}

/// The remote-control toolbar, pinned to the bottom over live video, as a
/// floating pill: the Request/Release button, a "you are controlling" state
/// line while the grant is live, and, if control was declined, the reason.
/// Shown only when the sharer advertised `.remoteControl`.
public struct RemoteControlBar: View {
    let buttonLabel: String
    let declinedReason: String?
    /// True while THIS viewer holds the control grant. Renders the tinted
    /// state line beside Release: the button label alone says what pressing
    /// does, not what is happening, and a live grant is the one state worth
    /// announcing — the macOS viewer frames the whole video orange for it.
    let isControlling: Bool
    /// The sharer's name for the state line, when the host knows it. Nil
    /// falls back to the generic sentence rather than printing a blank.
    let controllingHost: String?
    let onToggle: @MainActor @Sendable () -> Void

    public init(
        buttonLabel: String, declinedReason: String?,
        isControlling: Bool = false, controllingHost: String? = nil,
        onToggle: @escaping @MainActor @Sendable () -> Void
    ) {
        self.buttonLabel = buttonLabel
        self.declinedReason = declinedReason
        self.isControlling = isControlling
        self.controllingHost = controllingHost
        self.onToggle = onToggle
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button(buttonLabel, action: onToggle)
            if isControlling {
                Text(
                    controllingHost.map { L("You are controlling \($0)") }
                        ?? L("You are controlling this screen")
                )
                .font(.caption)
                .foregroundColor(HubStyle.controlActiveText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(HubStyle.controlActiveFill))
            }
            if let declinedReason {
                Text(L("Control declined: \(declinedReason)"))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hubCard(radius: 10)
    }
}

/// The microphone control: talk, or don't. Over live video as a floating pill
/// for the viewer, and plain inside the sharer's card (see `floating`).
///
/// **Absent, not disabled, when there is no microphone.** A host builds this
/// only when it actually opened a capture device, the same capability-not-
/// configuration rule the annotation toolbar and Request Control follow. A mute
/// button that cannot unmute teaches somebody their microphone is broken when
/// what is broken is the app.
///
/// The label says what the microphone IS, not what pressing does. Both readings
/// are defensible in isolation and only one can be right on a control that also
/// has to communicate state at a glance — and "Mute"/"Unmute" on a button that
/// looks identical either way is how people end up talking to a muted room.
public struct MicrophoneButton: View {
    let isOn: Bool
    /// Set once the capture device has failed — the mic is gone for this
    /// session and saying so beats a control that silently stops working.
    let failureNote: String?
    /// The system-wide mute chord's spelling ("Ctrl+Alt+M"), when the host
    /// actually holds it — folded into the tooltip so the shortcut is
    /// discoverable from the control it drives, like the macOS mic item's
    /// parenthetical. Nil hides the hint rather than advertising a chord
    /// that does nothing.
    let chordHint: String?
    /// Whether to draw the floating-pill chrome (padding + hubCard).
    ///
    /// True for the over-video control this button was born as, where it
    /// needs its own surface to be readable over arbitrary frames. The share
    /// card passes false: there it sits in a row of plain buttons on a card
    /// that already has a background, and a pill-in-card reads as a second
    /// card rather than a control.
    let floating: Bool
    let onToggle: @MainActor @Sendable () -> Void

    public init(
        isOn: Bool, failureNote: String? = nil, chordHint: String? = nil,
        floating: Bool = true,
        onToggle: @escaping @MainActor @Sendable () -> Void
    ) {
        self.isOn = isOn
        self.failureNote = failureNote
        self.chordHint = chordHint
        self.floating = floating
        self.onToggle = onToggle
    }

    /// Hover text: the ACTION (the label already carries the state), plus the
    /// chord when one is registered — the macOS mic tooltip's exact wording
    /// and keys.
    private var tooltip: String {
        if isOn {
            return chordHint.map { L("Mute microphone (\($0))") } ?? L("Mute microphone")
        }
        return chordHint.map { L("Unmute microphone (\($0))") } ?? L("Unmute microphone")
    }

    public var body: some View {
        if floating {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .hubCard(radius: 10)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            // Bracketed when live, matching the annotation toolbar's active
            // state: swift-cross-ui's Button takes a String label, so "which of
            // these is on" has to be carried by the text itself.
            Button(isOn ? "[\(L("🎙 On"))]" : " \(L("🎙 Off")) ", action: onToggle)
                .help(tooltip)
            if let failureNote {
                Text(failureNote)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// The share-card sentence for a system-wide mute chord that could not be
/// taken, per `GlobalHotkeyUnavailability` case.
///
/// One catalog key per case rather than interpolating `unavailability.reason`
/// — that property is English source text meant for logs, and a sentence
/// assembled around it would ship half-translated. `chord` is the platform
/// spelling ("Ctrl+Alt+M"); chords are never localized. Shared here because
/// both swift-cross-ui hosts append the same sentence to their share cards,
/// and two spellings of one warning would drift.
public enum MuteHotkeyNote {
    public static func text(
        chord: String, unavailability: GlobalHotkeyUnavailability
    ) -> String {
        switch unavailability {
        case .waylandSession:
            return L("The mute shortcut (\(chord)) doesn't work on Wayland — use the microphone button here")
        case .noDisplay:
            return L("The mute shortcut (\(chord)) needs an X display — use the microphone button here")
        case .alreadyOwned:
            return L("Another app already uses the mute shortcut (\(chord)) — use the microphone button here")
        case .unmappableChord:
            return L("The mute shortcut (\(chord)) can't be registered system-wide — use the microphone button here")
        case .unsupportedPlatform:
            return L("This build has no system-wide shortcuts — use the microphone button here")
        }
    }
}
