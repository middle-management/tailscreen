import SwiftCrossUI
import TailscreenL10n

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
    /// The share card's fill while a share is LIVE — the macOS sharer card's
    /// `Color.green.opacity(0.12)`, in this package's green.
    ///
    /// The card changing colour is the strongest "your screen is going out"
    /// signal either hub has, and it is deliberately the same hue as the
    /// sharing chip in the screen list: one green means one thing everywhere.
    /// Never the only carrier of that state — the dot, the headline and the
    /// viewer pill all say it too, per this repo's colour-alone rule.
    public static let sharingCardFill = Color(red: 0.2, green: 0.7, blue: 0.35, opacity: 0.12)
    public static let sharingCardStroke = Color(red: 0.2, green: 0.7, blue: 0.35, opacity: 0.30)
    /// The viewer-count pill: solid green behind white, like the macOS card's
    /// `Capsule().fill(Color.green)`. Opaque on purpose — it is a count, read
    /// at a glance, and a translucent badge over a translucent card is mush.
    public static let countPillFill = Color(red: 0.16, green: 0.62, blue: 0.30)
    /// The bed the "Capturing…" placeholder sits on while a share has started
    /// but no thumbnail has arrived — the macOS card's dimmed preview well.
    /// The live preview needs no mat: it is opaque and rounds itself.
    public static let previewWell = Color(white: 0.5, opacity: 0.14)
    /// A row that is WAITING ON YOU — the macOS pending-viewer list's
    /// `Color.orange.opacity(0.12)`. Its whole job is to not look like the
    /// rows that need nothing: a viewer parked at the gate is stuck on a
    /// placard with nothing on screen, and an approval that reads like a
    /// status line is one nobody answers.
    public static let attentionFill = Color(red: 0.95, green: 0.6, blue: 0.1, opacity: 0.14)
    /// Viewer-health dots, matching the macOS roster: green / yellow / orange.
    /// Never alone — the row spells the health out beside them.
    public static let healthDegraded = Color(red: 0.9, green: 0.72, blue: 0.1)
    public static let healthThrottled = Color(red: 0.95, green: 0.55, blue: 0.1)
    /// The "you are controlling" state — the same orange the macOS viewer
    /// frames the video with while a grant is live, as a translucent tint so
    /// it reads on both light and dark like the sharing chip does.
    public static let controlActiveFill = Color(red: 1.0, green: 0.62, blue: 0.04, opacity: 0.18)
    public static let controlActiveText = Color(red: 0.75, green: 0.46, blue: 0.02)
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
        hubCard(radius: radius, fill: HubStyle.cardFill, stroke: HubStyle.cardStroke)
    }

    /// `hubCard` with an explicit palette — for the share card, which tints
    /// itself green while a share is live (see `HubStyle.sharingCardFill`).
    public func hubCard(radius: Double = HubStyle.cardRadius, fill: Color, stroke: Color)
        -> some View
    {
        self
            .background {
                RoundedRectangle(cornerRadius: radius).fill(fill)
                RoundedRectangle(cornerRadius: radius).stroke(stroke)
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
/// Somebody currently watching this screen, and what the sharer can do about
/// them.
///
/// The row that closes the alignment plan's worst gap: before this, Linux and
/// Windows could admit a viewer and then had **no way to change their mind** —
/// the roster was a list of IP strings in `ShareCard.notes`.
///
/// Actions are three separate optionals rather than a list, because they are
/// not interchangeable and the difference matters at a glance: `onKick` is a
/// one-time disconnect that remembers nothing, `onAlwaysAllow` and
/// `onDenyAndBlock` are decisions about the *person* that outlive the share.
/// A host that cannot do one of them passes nil and the button is absent —
/// never present-and-inert.
///
/// `rememberIsDeferred` is what the row says when a decision has been made
/// but the peer's Tailscale identity has not resolved yet. The store is keyed
/// by StableNodeID and nothing else is safe to key on, so there genuinely is
/// a wait — and a button that appears to do nothing for a second is worse than
/// one that says it is waiting. See `ViewerRosterDecision`.
public struct HubViewerRow: Identifiable, Sendable {
    /// Opaque to the chrome; handed back verbatim. The server's `"ip:port"`
    /// viewer key on both hosts — never the bare IP, which matches nothing.
    public let id: String
    /// Hostname once the netmap lookup lands, the IP until then.
    public let label: String
    /// How this viewer's connection is doing. The row derives BOTH its dot
    /// colour and the sentence beside it from this, so the two cannot
    /// disagree — and so the wording is written (and translated) once for
    /// both hosts.
    ///
    /// A chrome-owned enum rather than the server's `ViewerHealth`, and a
    /// plain word rather than the host's pre-rendered string: this package
    /// must not import the sharer tier to draw a dot (the same
    /// import-direction rule `hubPhase` follows), and both hosts used to
    /// interpolate the raw enum — so a degraded viewer read as a lowercase
    /// `degraded` beside their hostname, in English, on every platform.
    public let health: HubViewerHealth
    /// What is remembered about this peer right now, so the row can show the
    /// standing decision instead of offering to make it again.
    public let remembered: HubViewerMemory
    /// True when a remember-decision is queued behind identity resolution.
    public let rememberIsDeferred: Bool
    public let onKick: (@MainActor @Sendable () -> Void)?
    public let onAlwaysAllow: (@MainActor @Sendable () -> Void)?
    public let onDenyAndBlock: (@MainActor @Sendable () -> Void)?
    public let onForget: (@MainActor @Sendable () -> Void)?

    public init(
        id: String,
        label: String,
        health: HubViewerHealth = .good,
        remembered: HubViewerMemory = .none,
        rememberIsDeferred: Bool = false,
        onKick: (@MainActor @Sendable () -> Void)? = nil,
        onAlwaysAllow: (@MainActor @Sendable () -> Void)? = nil,
        onDenyAndBlock: (@MainActor @Sendable () -> Void)? = nil,
        onForget: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.label = label
        self.health = health
        self.remembered = remembered
        self.rememberIsDeferred = rememberIsDeferred
        self.onKick = onKick
        self.onAlwaysAllow = onAlwaysAllow
        self.onDenyAndBlock = onDenyAndBlock
        self.onForget = onForget
    }
}

/// How a connected viewer's link is doing, as the chrome needs it — the
/// server's `ViewerHealth` case for case, mapped by each host for the same
/// import-direction reason `hubPhase` exists.
///
/// The wording matches the macOS roster's, and reuses its catalog keys, so a
/// degraded viewer is described identically on all three platforms.
public enum HubViewerHealth: Sendable, Equatable {
    /// No meaningful loss. The row says nothing — a healthy viewer needs no
    /// sentence, and one for every row would bury the one that matters.
    case good
    /// Over the loss threshold, but still getting full frames.
    case degraded
    /// Keyframe-only: this viewer's link is isolating the session.
    case throttled

    /// The sentence beside the dot, or nil when there is nothing to say.
    /// Non-nil for everything but `.good`, which is what keeps the dot from
    /// being the only carrier of a problem.
    public var note: String? {
        switch self {
        case .good: return nil
        case .degraded: return L("Connection degraded — packet loss")
        case .throttled: return L("Limited to keyframes — poor connection")
        }
    }

    var dotColor: Color {
        switch self {
        case .good: return HubStyle.online
        case .degraded: return HubStyle.healthDegraded
        case .throttled: return HubStyle.healthThrottled
        }
    }
}

/// What the sharer has decided about a peer, if anything.
///
/// Three states rather than a `Bool?` for the same reason `PeerSharingState`
/// is an enum: "nothing decided" is a real answer with its own affordances
/// (offer both), not the absence of one.
public enum HubViewerMemory: Sendable, Equatable {
    case none
    case allowed
    case blocked
}

public struct HubPrompt: Identifiable, Sendable {
    /// Opaque to the chrome; handed back verbatim to the accept/decline
    /// callbacks. An IP on one platform, a connection UUID on another.
    public let id: String
    public let message: String
    public let acceptLabel: String
    public let declineLabel: String

    public init(
        id: String, message: String, acceptLabel: String = L("Allow"),
        declineLabel: String = L("Deny")
    ) {
        self.id = id
        self.message = message
        self.acceptLabel = acceptLabel
        self.declineLabel = declineLabel
    }
}

/// The header's signed-in line, decided once so both hubs say the same thing.
///
/// Prefers the TAILNET over the login, which is the macOS hub's choice and the
/// more useful of the two here: the login answers "who am I", but the screen
/// list below is scoped to a tailnet, so the tailnet is what explains an
/// expected machine being absent. The login is the fallback because some
/// control planes (headscale commonly) report no tailnet name at all, and a
/// blank header is worse than a less-specific one.
public func hubSignedInSubtitle(tailnet: String?, account: String?) -> String {
    if let tailnet, !tailnet.isEmpty { return tailnet }
    if let account, !account.isEmpty { return account }
    return L("Signed in")
}
