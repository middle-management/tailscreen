import SwiftCrossUI
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
///   • No color picker — as on macOS, each participant's color comes from their
///     identity; the swatch beside the tools just shows which color this viewer
///     draws in.
public struct AnnotationToolbar: View {
    /// Tool order — matches the macOS `ViewerToolbar.toolOrder` exactly.
    /// Glyphs: pencil, diagonal, arrow, rectangle, ellipse, target.
    public static let tools: [(tool: AnnotationTool, glyph: String, name: String)] = [
        (.pen, "✎", "Pen"), (.line, "╱", "Line"), (.arrow, "↗", "Arrow"),
        (.rectangle, "▭", "Rect"), (.oval, "◯", "Oval"), (.click, "◎", "Click"),
    ]

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
    let onUndo: @MainActor @Sendable () -> Void
    let onClear: @MainActor @Sendable () -> Void
    let onToggleStats: @MainActor @Sendable () -> Void

    public init(
        activeTool: AnnotationTool?,
        inkColor: Annotation.RGBA,
        statsShown: Bool = false,
        showsStats: Bool = true,
        onSelectTool: @escaping @MainActor @Sendable (AnnotationTool) -> Void,
        onUndo: @escaping @MainActor @Sendable () -> Void,
        onClear: @escaping @MainActor @Sendable () -> Void,
        onToggleStats: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.activeTool = activeTool
        self.inkColor = inkColor
        self.statsShown = statsShown
        self.showsStats = showsStats
        self.onSelectTool = onSelectTool
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
            }
            Divider()
            // Read-only swatch: the color this viewer's strokes appear in.
            Circle()
                .fill(Color(
                    red: inkColor.r, green: inkColor.g, blue: inkColor.b,
                    opacity: inkColor.a))
                .frame(width: 16, height: 16)
            Divider()
            Button("↶", action: onUndo)
            Button("✕", action: onClear)
            if showsStats {
                Button(statsShown ? "[▤]" : " ▤ ", action: onToggleStats)
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
        Text("\(width)×\(height) · \(fps) fps")
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0, opacity: 0.55)))
    }
}

/// The remote-control toolbar, pinned to the bottom over live video, as a
/// floating pill: the Request/Release button and, if control was declined, the
/// reason. Shown only when the sharer advertised `.remoteControl`.
public struct RemoteControlBar: View {
    let buttonLabel: String
    let declinedReason: String?
    let onToggle: @MainActor @Sendable () -> Void

    public init(
        buttonLabel: String, declinedReason: String?,
        onToggle: @escaping @MainActor @Sendable () -> Void
    ) {
        self.buttonLabel = buttonLabel
        self.declinedReason = declinedReason
        self.onToggle = onToggle
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button(buttonLabel, action: onToggle)
            if let declinedReason {
                Text("Control declined: \(declinedReason)")
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
    let onToggle: @MainActor @Sendable () -> Void

    public init(
        isOn: Bool, failureNote: String? = nil,
        onToggle: @escaping @MainActor @Sendable () -> Void
    ) {
        self.isOn = isOn
        self.failureNote = failureNote
        self.onToggle = onToggle
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Bracketed when live, matching the annotation toolbar's active
            // state: swift-cross-ui's Button takes a String label, so "which of
            // these is on" has to be carried by the text itself.
            Button(isOn ? "[🎙 On]" : " 🎙 Off ", action: onToggle)
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
