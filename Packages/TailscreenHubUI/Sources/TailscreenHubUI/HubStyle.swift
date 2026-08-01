import SwiftCrossUI

/// Shared design tokens.
///
/// Translucent grays rather than opaque colors, so cards and rows read as
/// subtle overlays on whatever the platform paints behind them — GTK's theme,
/// WinUI's Mica — and stay legible in both light and dark. Primary text is left
/// uncolored on purpose so it follows the host's own foreground color; the only
/// hard-coded hues are the ones that carry meaning (presence, the sharing chip)
/// and would be a lie in any other color.
public enum HubStyle {
    /// The header's height, standing in for a title bar.
    public static let headerHeight = 52
    /// The annotation toolbar's height. Also read by video views that need to
    /// subtract the chrome from their own geometry.
    public static let toolbarHeight = 44
    /// The hub is one column, like the macOS window. Wider than this and the
    /// rows stretch into unreadable ribbons on a maximized window.
    public static let contentMaxWidth = 460.0
    public static let cardRadius = 12.0
    public static let rowRadius = 10.0

    public static let secondaryText = Color(white: 0.5)
    public static let tertiaryText = Color(white: 0.5, opacity: 0.7)
    public static let barFill = Color(white: 0.5, opacity: 0.08)
    public static let cardFill = Color(white: 0.5, opacity: 0.10)
    public static let cardStroke = Color(white: 0.5, opacity: 0.22)
    public static let rowFill = Color(white: 0.5, opacity: 0.10)
    public static let rowFillSelected = Color(white: 0.5, opacity: 0.18)
    public static let searchFill = Color(white: 0.5, opacity: 0.12)
    public static let detailFill = Color(white: 0.5, opacity: 0.06)
    public static let online = Color.green
    public static let offline = Color(white: 0.5, opacity: 0.55)
    public static let chipFill = Color(red: 0.2, green: 0.7, blue: 0.35, opacity: 0.18)
    public static let chipText = Color(red: 0.13, green: 0.55, blue: 0.27)
}

extension View {
    /// The rounded, faintly-tinted, hairline-bordered card the hub uses for its
    /// status/login modules. Apply *after* the content's own padding.
    ///
    /// The hairline border is a *background* layer (stacked over the fill,
    /// under the content) — deliberately NOT an `.overlay`. On the WinUI
    /// backend an overlaid shape is hit-testable across its whole interior even
    /// when stroked with a clear fill: `renderPath` always assigns the
    /// `WinUI.Path` a fill brush (a transparent `SolidColorBrush` for
    /// `Color.clear`), and XAML hit-testing keys on brush *presence*, not
    /// alpha. An overlay sized to the card therefore sat over every control in
    /// it and swallowed all mouse clicks — the login card's button worked by
    /// keyboard (focus traversal bypasses hit-testing) and never by mouse.
    /// Content is padded well off the card edge, so drawing the stroke under
    /// it instead is visually identical.
    public func hubCard(radius: Double = HubStyle.cardRadius) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius).fill(HubStyle.cardFill)
                RoundedRectangle(cornerRadius: radius).stroke(HubStyle.cardStroke)
            }
    }
}

/// A labelled action, for the places the chrome offers a button whose meaning
/// is the host's to decide — "Take back control", "Stop sharing".
///
/// A struct rather than two parameters because these travel in optionals and
/// arrays, where a label with no action (or the reverse) would be a state the
/// caller could construct and the view could not render.
public struct HubAction: Sendable {
    public let label: String
    public let perform: @MainActor @Sendable () -> Void

    public init(label: String, perform: @escaping @MainActor @Sendable () -> Void) {
        self.label = label
        self.perform = perform
    }
}

/// A labelled on/off setting the chrome renders and the host owns.
///
/// Plain value + closure rather than a `Binding`, for the same reason
/// `HubAction` is a struct: this package must not know where the setting is
/// stored. The host reads it from wherever it persists (or does not), and the
/// card turns the pair back into the `Binding` SwiftCrossUI's `Toggle` wants.
/// A `Binding` in the public API would have made the card's caller reach for
/// `@State` it does not own — both apps rebuild their `ShareCard` from a
/// computed property on every model change, so there is no view-local state to
/// bind to.
///
/// `caption` carries what the setting means when the label alone is a noun
/// phrase. Turning a security gate off is the kind of thing that should say
/// what it will do before it does it.
public struct HubToggle: Sendable {
    public let label: String
    public let caption: String?
    public let isOn: Bool
    public let set: @MainActor @Sendable (Bool) -> Void

    public init(
        label: String, caption: String? = nil, isOn: Bool,
        set: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.label = label
        self.caption = caption
        self.isOn = isOn
        self.set = set
    }
}

/// Something asking the person at this machine for a yes or a no.
///
/// One type for what were two features: a viewer waiting to be admitted, and a
/// viewer asking for control. They are the same interaction — a sentence and
/// two buttons — and the sharer should not have to learn two shapes of prompt
/// depending on which one arrived.
public struct HubPrompt: Identifiable, Sendable {
    /// Opaque to the chrome; handed back verbatim to the accept/decline
    /// callbacks. An IP on one platform, a connection UUID on another.
    public let id: String
    public let message: String
    public let acceptLabel: String
    public let declineLabel: String

    public init(
        id: String, message: String, acceptLabel: String = "Allow",
        declineLabel: String = "Deny"
    ) {
        self.id = id
        self.message = message
        self.acceptLabel = acceptLabel
        self.declineLabel = declineLabel
    }
}
