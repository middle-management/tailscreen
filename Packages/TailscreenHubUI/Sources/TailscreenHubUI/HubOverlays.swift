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
/// Differences from the macOS toolbar:
///   • Unicode geometric glyphs instead of SF Symbols (Apple-only) — neither
///     GTK's icon theme nor Windows has a matching set, and `Button` here
///     takes only a `String` label (no room for a `Shape`-drawn vector icon
///     without losing GTK's keyboard/screen-reader tap target). Revisit if
///     swift-cross-ui ever supports arbitrary button labels.
///   • The armed tool is bracketed, not highlighted: no segmented control here.
///   • The color picker is a `Menu` of named rows with the current color
///     checked, since a menu label is a plain String (no swatch icon like
///     macOS's `makeColorMenu`). Identity seeds the default color; a pick
///     overrides it, and per-stroke color rides `Annotation.color` as on macOS.
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

    /// How the controls are laid out. `.singleRow`: the over-video bar, a
    /// full-width strip since a video window is as wide as the video.
    /// `.twoRows`: for the share card, whose hub-narrow window would clip a
    /// single row of ten buttons and squeeze every other label in the card
    /// to make room. Tools on row one, color/undo/clear on row two.
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
    /// Whether to offer the stats toggle at all. False on the sharer, which
    /// reuses this toolbar to draw on its own screen: no decoded video, no
    /// resolution/fps to show.
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
            // The mac toolbar's label, here the hover answer to an unlabelled glyph.
            .help(item.element.name)
        }
    }

    /// The swatch says which color this viewer draws in; the menu beside it
    /// changes it — split because a menu label can't carry a swatch icon here.
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
                // Checked `Toggle` rows, like the header's filter menu. The
                // palette is a radio group: re-picking the current color is ignored.
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
            // No bar background or fixed height: rows hug content so neither outgrows the card.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    toolButtons
                    Spacer()
                }
                HStack(spacing: 6) {
                    // Chipped, unlike the single-row bar's bare dot: a lone dot
                    // beside two buttons would read as a stray mark.
                    colorSwatch
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(HubStyle.rowFill)
                        )
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
                    // Worded, not a glyph: as `▤` it read as a seventh drawing tool.
                    Divider()
                    Button(statsShown ? L("Hide stats") : L("Stats"), action: onToggleStats)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            // Fixed height, else the enclosing VStack gives the toolbar an equal share and squeezes the video.
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
    /// The stream's colour encoding, already formatted (`VideoColorInfo`'s
    /// `shortLabel` — "BT.709 · limited"). Empty prints no line: unknown
    /// until a frame decodes.
    let colorLabel: String

    public init(width: Int, height: Int, fps: Int, colorLabel: String = "") {
        self.width = width
        self.height = height
        self.fps = fps
        self.colorLabel = colorLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("\(width)×\(height) · \(fps) fps"))
                .font(.caption)
                .foregroundColor(.white)
            if !colorLabel.isEmpty {
                // Standards names ("BT.709", "limited") — not through `L(_:)`,
                // like codec names: unlocalizable, and a runtime-built string
                // can't satisfy `LocalizationCatalogTests`'s literal scan anyway.
                Text(colorLabel)
                    .font(.caption)
                    .foregroundColor(.white)
            }
        }
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
    /// True while this viewer holds the control grant — renders the tinted
    /// state line beside Release, since the button label alone says what
    /// pressing does, not what is happening.
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
/// Absent, not disabled, when there is no microphone — a host builds this
/// only when it actually opened a capture device.
///
/// The label says what the microphone IS, not what pressing does: "Mute" on a
/// button that looks the same either way is how people end up talking to a
/// muted room.
public struct MicrophoneButton: View {
    let isOn: Bool
    /// Set once the capture device has failed — mic is gone for this session.
    let failureNote: String?
    /// The system-wide mute chord's spelling ("Ctrl+Alt+M"), folded into the
    /// tooltip. Nil hides the hint rather than advertising a dead chord.
    let chordHint: String?
    /// Whether to draw the floating-pill chrome (padding + hubCard). True for
    /// the over-video control, which needs its own surface over arbitrary
    /// frames. False in the share card, where a pill would read as a nested card.
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

    /// Hover text: the action (label already carries state), plus the chord
    /// when registered.
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
            // Bracketed when live, matching the annotation toolbar's convention for a String-only label.
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
/// One catalog key per case, not an interpolated `unavailability.reason`
/// (that's log-only English). `chord` is the platform spelling
/// ("Ctrl+Alt+M") and is never localized. Shared so both hosts' warnings don't drift.
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
