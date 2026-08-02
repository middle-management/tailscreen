import Foundation

/// Every keyboard shortcut the app defines, as data.
///
/// A shortcut is invisible by construction: nothing on screen implies ⌃⌥M, so
/// registering one accomplishes nothing unless the app also says so somewhere
/// the user will look. Each host renders that differently — menu items and a
/// cheat sheet on macOS, `GtkShortcutsWindow` on Linux, `KeyboardAccelerator`
/// on Windows — but all three are rendering the same list, and a list
/// maintained three times is a list that disagrees three ways.
///
/// macOS proved that before this existed: it kept the menu and the cheat sheet
/// in two hand-written places, and they drifted apart on ⌃⌥., the panic key
/// whose entire purpose is to be remembered under pressure. It appeared in
/// neither list.
public enum ShortcutCommand: String, Codable, Sendable, CaseIterable {
    // Audio
    case toggleMicrophone

    // Remote control
    case stopRemoteControl

    // Annotation tools
    case toolPen
    case toolLine
    case toolArrow
    case toolRectangle
    case toolOval
    case toolClick

    // Annotation
    case undoAnnotation
    case clearAnnotations

    // Zoom
    case zoomActualSize
    case zoomHalf
    case zoomDouble
    case contentZoomIn
    case contentZoomOut

    // Window
    case disconnect
    case showShortcuts
    case quit
}

/// A shortcut's modifier keys, expressed by *role* rather than by glyph.
///
/// `primary` is the difference that makes one catalog serve three platforms:
/// the "app command" modifier is ⌘ on macOS and Ctrl everywhere else, so a
/// catalog holding literal ⌘ would be a macOS catalog with extra steps.
///
/// Deliberately **not** `KeyModifiers`, despite the overlap. That type is the
/// remote-control **wire** model: it names physical keys because it describes
/// keystrokes being replayed on another machine, where "the same physical key"
/// is exactly what must survive the trip. This one describes intent being
/// rendered for a human, where the same intent is a *different* physical key
/// per platform. Merging them would force one of the two to lie.
public struct ShortcutModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The app-command modifier: ⌘ on macOS, Ctrl elsewhere.
    public static let primary = ShortcutModifiers(rawValue: 1 << 0)
    /// ⌥ on macOS, Alt elsewhere.
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    /// The literal Control key. On macOS this is ⌃, which is *not* ⌘ — the two
    /// are distinct there and both are in use (⌘Z undo, ⌃⌥. panic revoke).
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

/// The non-modifier half of a chord.
///
/// Characters, not scancodes or HID usages: this catalog exists to be
/// *displayed*, and "⌘/" is what a user reads. The physical-key model belongs
/// to remote control, where a keystroke is being replayed rather than shown.
public enum ShortcutKey: Equatable, Sendable, Codable {
    case character(String)
    case escape
    case delete

    /// How the key reads in a shortcut list.
    public var display: String {
        switch self {
        case .character(let value): value.uppercased()
        case .escape: "Esc"
        case .delete: "⌫"
        }
    }
}

/// Modifiers plus a key.
public struct ShortcutChord: Equatable, Sendable, Codable {
    public let modifiers: ShortcutModifiers
    public let key: ShortcutKey

    /// Key first, modifiers second-and-defaulted: a leading defaulted
    /// parameter would make `.init(.character("1"))` ambiguous against the
    /// synthesized `init(from:)`, which the compiler resolves in favour of
    /// `Decodable` with a confusing error.
    public init(_ key: ShortcutKey, _ modifiers: ShortcutModifiers = []) {
        self.modifiers = modifiers
        self.key = key
    }
}

/// How a chord is spelled for the reader.
public enum ShortcutDisplayStyle: Sendable {
    /// Apple's glyphs, in Apple's canonical order (⌃⌥⇧⌘). The order is not a
    /// preference — macOS renders modifiers this way everywhere, and a list
    /// that used another order would look wrong beside the menu bar it
    /// documents.
    case appleSymbols
    /// `Ctrl+Alt+M`, for GTK and Windows.
    case words
}

extension ShortcutChord {
    /// Spell this chord for a platform.
    public func display(_ style: ShortcutDisplayStyle) -> String {
        switch style {
        case .appleSymbols:
            var out = ""
            if modifiers.contains(.control) { out += "⌃" }
            if modifiers.contains(.option) { out += "⌥" }
            if modifiers.contains(.shift) { out += "⇧" }
            if modifiers.contains(.primary) { out += "⌘" }
            return out + key.display
        case .words:
            var parts: [String] = []
            // `primary` and `control` both land on Ctrl off macOS. That is
            // correct, and `ShortcutCatalog.collisions` is what stops two
            // commands quietly becoming the same chord because of it.
            if modifiers.contains(.control) || modifiers.contains(.primary) { parts.append("Ctrl") }
            if modifiers.contains(.option) { parts.append("Alt") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            parts.append(key.display)
            return parts.joined(separator: "+")
        }
    }
}

/// Where a shortcut appears in a grouped list.
public enum ShortcutSection: String, Codable, Sendable, CaseIterable {
    case tools
    case annotation
    case zoom
    case audio
    case remoteControl
    case window

    /// English source text; hosts localize.
    public var title: String {
        switch self {
        case .tools: "Tools"
        case .annotation: "Annotation"
        case .zoom: "Zoom"
        case .audio: "Audio"
        case .remoteControl: "Remote Control"
        case .window: "Window"
        }
    }
}

/// One catalog row.
public struct ShortcutEntry: Equatable, Sendable {
    public let command: ShortcutCommand
    public let section: ShortcutSection
    public let chord: ShortcutChord
    /// English source text describing what it does; hosts localize.
    public let summary: String

    /// Registered with the OS so it fires while the app is **not** frontmost.
    ///
    /// The distinction is what makes a shortcut reachable mid-share, when the
    /// sharer is in the app they are sharing. It also carries an obligation:
    /// a global registration can be refused because another app already owns
    /// the combo, and every platform's API reports that by returning a value
    /// nobody reads. A host that advertises a global shortcut must be prepared
    /// to say it did not take.
    public let isGlobal: Bool

    public init(
        command: ShortcutCommand,
        section: ShortcutSection,
        chord: ShortcutChord,
        summary: String,
        isGlobal: Bool = false
    ) {
        self.command = command
        self.section = section
        self.chord = chord
        self.summary = summary
        self.isGlobal = isGlobal
    }
}

/// The catalog itself.
public enum ShortcutCatalog {
    public static let entries: [ShortcutEntry] = [
        .init(
            command: .toolPen, section: .tools, chord: .init(.character("1")),
            summary: "Pen"),
        .init(
            command: .toolLine, section: .tools, chord: .init(.character("2")),
            summary: "Line"),
        .init(
            command: .toolArrow, section: .tools, chord: .init(.character("3")),
            summary: "Arrow"),
        .init(
            command: .toolRectangle, section: .tools, chord: .init(.character("4")),
            summary: "Rectangle"),
        .init(
            command: .toolOval, section: .tools, chord: .init(.character("5")),
            summary: "Oval"),
        .init(
            command: .toolClick, section: .tools, chord: .init(.character("6")),
            summary: "Pointer / Click"),

        .init(
            command: .undoAnnotation, section: .annotation,
            chord: .init(.character("z"), .primary),
            summary: "Undo last annotation"),
        .init(
            command: .clearAnnotations, section: .annotation,
            chord: .init(.delete, [.primary, .shift]),
            summary: "Clear all annotations"),

        .init(
            command: .zoomActualSize, section: .zoom, chord: .init(.character("0"), .primary),
            summary: "Reset zoom and window size"),
        .init(
            command: .zoomHalf, section: .zoom, chord: .init(.character("-"), .primary),
            summary: "Zoom to 50%"),
        .init(
            command: .zoomDouble, section: .zoom, chord: .init(.character("+"), .primary),
            summary: "Zoom to 200%"),
        .init(
            command: .contentZoomIn, section: .zoom,
            chord: .init(.character("+"), [.primary, .option]),
            summary: "Zoom in at the cursor"),
        .init(
            command: .contentZoomOut, section: .zoom,
            chord: .init(.character("-"), [.primary, .option]),
            summary: "Zoom out at the cursor"),

        // Global: muting is a reflex, and during a share the app is behind
        // whatever is being shared.
        .init(
            command: .toggleMicrophone, section: .audio,
            chord: .init(.character("m"), [.control, .option]),
            summary: "Toggle microphone", isGlobal: true),

        // Global, and the reason the global tier exists at all: a sharer
        // taking their machine back from a viewer cannot be asked to find a
        // window first. Registered only while a grant is live, so an idle app
        // does not hold ⌃⌥. system-wide for a handler with nothing to do.
        .init(
            command: .stopRemoteControl, section: .remoteControl,
            chord: .init(.character("."), [.control, .option]),
            summary: "Revoke remote control", isGlobal: true),

        .init(
            command: .disconnect, section: .window, chord: .init(.character("w"), .primary),
            summary: "Disconnect viewer"),
        .init(
            command: .showShortcuts, section: .window,
            chord: .init(.character("/"), [.primary, .shift]),
            summary: "Show / hide keyboard shortcuts"),
        .init(
            command: .quit, section: .window, chord: .init(.character("q"), .primary),
            summary: "Quit Tailscreen")
    ]

    public static func entry(for command: ShortcutCommand) -> ShortcutEntry? {
        entries.first { $0.command == command }
    }

    public static func entries(in section: ShortcutSection) -> [ShortcutEntry] {
        entries.filter { $0.section == section }
    }

    /// Shortcuts registered with the OS — the ones a host must also report a
    /// registration failure for.
    public static var globals: [ShortcutEntry] {
        entries.filter(\.isGlobal)
    }

    /// Commands whose chords collide once spelled for `style`.
    ///
    /// Not decoration. `primary` and `control` are distinct on macOS (⌘ vs ⌃)
    /// and both become Ctrl everywhere else, so a pair that is unambiguous in
    /// the menu bar can silently become one chord on GTK and WinUI — where the
    /// symptom is not an error but a shortcut that runs the wrong command.
    /// Sections do not scope this: these are application-wide accelerators.
    public static func collisions(_ style: ShortcutDisplayStyle) -> [String: [ShortcutCommand]] {
        var byChord: [String: [ShortcutCommand]] = [:]
        for entry in entries {
            byChord[entry.chord.display(style), default: []].append(entry.command)
        }
        return byChord.filter { $0.value.count > 1 }
    }
}
