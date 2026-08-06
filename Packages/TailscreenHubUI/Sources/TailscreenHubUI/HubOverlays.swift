import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// Annotation toolbar pinned to the TOP of a viewer window, mirroring the macOS
/// viewer's `NSToolbar`: a radio-selected tool group in the same order — pen,
/// line, arrow, rect, oval, click — then Undo, Clear and a Stats toggle. Shown
/// only when the sharer advertised `ScreenShareCaps.annotations`.
///
/// Differences from the macOS toolbar, and why:
///   • Unicode geometric glyphs instead of SF Symbols (Apple-only). GTK's own
///     named icon theme was the first choice — swift-cross-ui's `Gtk.Button`
///     even takes an `iconName` — but it is an app-chrome set with no line /
///     rectangle / oval / pointer icons, so half the tool group would have
///     fallen back anyway, and nothing equivalent exists on Windows. These
///     glyphs render from the system font on both.
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
        (.rectangle, "▭", L("Rect")), (.oval, "◯", L("Oval")), (.click, "◎", L("Click")),
    ]

    /// Localized names for `Annotation.RGBA.palette`, index-aligned with it —
    /// the same eight names (and catalog keys) the macOS color menu speaks, so
    /// a color is called the same thing on every platform.
    public static let paletteColorNames: [String] = [
        L("Red"), L("Blue"), L("Green"), L("Orange"),
        L("Purple"), L("Teal"), L("Pink"), L("Yellow"),
    ]

    /// The palette with its spoken names, zipped so a palette edit that
    /// forgets a name can never index out of range.
    static var paletteRows: [(name: String, color: Annotation.RGBA)] {
        zip(paletteColorNames, Annotation.RGBA.palette).map { (name: $0.0, color: $0.1) }
    }

    /// The armed tool, or nil when drawing is off (pointer drags then zoom/pan
    /// or drive remote control).
    let activeTool: AnnotationTool?
    /// This viewer's assigned stroke color (identity-derived, not chosen).
    let inkColor: Annotation.RGBA
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
        self.statsShown = statsShown
        self.showsStats = showsStats
        self.onSelectTool = onSelectTool
        self.onSelectColor = onSelectColor
        self.onUndo = onUndo
        self.onClear = onClear
        self.onToggleStats = onToggleStats
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.tools.enumerated()), id: \.offset) { item in
                let isActive = activeTool == item.element.tool
                Button(isActive ? "[\(item.element.glyph)]" : " \(item.element.glyph) ") {
                    onSelectTool(item.element.tool)
                }
                // The name the mac toolbar shows as a label; here it is the
                // hover answer to six otherwise-unlabelled marks.
                .help(item.element.name)
            }
            Divider()
            // The swatch says which color this viewer draws in; the menu
            // beside it changes it. Split in two because a swift-cross-ui menu
            // label is a String — the current color cannot ride the label the
            // way the macOS item's swatch icon does.
            Circle()
                .fill(Color(
                    red: inkColor.r, green: inkColor.g, blue: inkColor.b,
                    opacity: inkColor.a))
                .frame(width: 16, height: 16)
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
            Divider()
            Button("↶", action: onUndo)
            Button("✕", action: onClear)
            if showsStats {
                // Worded, not a glyph, and behind a divider. As `▤` at the end
                // of a row of drawing glyphs it read as a seventh drawing tool
                // and was reported as a missing feature by someone looking
                // straight at it. The no-annotations fallback in the Windows
                // app has always spelled it out; these now match.
                Divider()
                Button(statsShown ? L("Hide stats") : L("Stats"), action: onToggleStats)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        // Fixed height so the row hugs its buttons; without it the enclosing
        // VStack hands the toolbar an equal share of the window and squeezes
        // the video.
        .frame(height: Double(HubStyle.toolbarHeight))
        .frame(maxWidth: .infinity)
        .background(HubStyle.barFill)
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

/// The microphone control over live video: talk, or don't.
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
    let onToggle: @MainActor @Sendable () -> Void

    public init(
        isOn: Bool, failureNote: String? = nil, chordHint: String? = nil,
        onToggle: @escaping @MainActor @Sendable () -> Void
    ) {
        self.isOn = isOn
        self.failureNote = failureNote
        self.chordHint = chordHint
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hubCard(radius: 10)
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
