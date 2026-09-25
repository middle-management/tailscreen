import SwiftCrossUI
import TailscreenL10n

/// Shared design tokens. Translucent grays, not opaque colors, so cards and
/// rows overlay whatever the platform paints behind them (GTK theme, WinUI
/// Mica) and stay legible in light and dark. Primary text is uncolored, so it
/// follows the host's foreground; only meaning-carrying hues (presence, the
/// sharing chip) are hard-coded.
public enum HubStyle {
    /// The header's height, standing in for a title bar.
    public static let headerHeight = 52
    /// The annotation toolbar's height. Also read by video views that need to
    /// subtract the chrome from their own geometry.
    public static let toolbarHeight = 44
    /// The hub is one column, like the macOS window; wider and rows stretch
    /// into unreadable ribbons on a maximized window.
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
    /// The share card's fill while live — the macOS sharer card's
    /// `Color.green.opacity(0.12)`, same hue as the sharing chip. Never the
    /// only carrier of state — the dot, headline and viewer pill say it too.
    public static let sharingCardFill = Color(red: 0.2, green: 0.7, blue: 0.35, opacity: 0.12)
    public static let sharingCardStroke = Color(red: 0.2, green: 0.7, blue: 0.35, opacity: 0.30)
    /// The viewer-count pill: opaque solid green, since it is a count read at
    /// a glance and a translucent badge over a translucent card is mush.
    public static let countPillFill = Color(red: 0.16, green: 0.62, blue: 0.30)
    /// The "Capturing…" placeholder's bed before the first thumbnail lands.
    public static let previewWell = Color(white: 0.5, opacity: 0.14)
    /// A row waiting on you — the macOS pending-viewer list's orange, so it
    /// doesn't read like a row that needs nothing.
    public static let attentionFill = Color(red: 0.95, green: 0.6, blue: 0.1, opacity: 0.14)
    /// Viewer-health dots, matching the macOS roster. Never alone — the row spells health out beside them.
    public static let healthDegraded = Color(red: 0.9, green: 0.72, blue: 0.1)
    public static let healthThrottled = Color(red: 0.95, green: 0.55, blue: 0.1)
    /// The guest badge, matching the macOS roster's purple capsule — a
    /// share-by-token viewer, identified by node key. Purple reads as
    /// identity-kind, not health or attention.
    public static let guestChipFill = Color(red: 0.55, green: 0.35, blue: 0.85, opacity: 0.18)
    public static let guestChipText = Color(red: 0.45, green: 0.28, blue: 0.75)
    /// The "you are controlling" state — same orange macOS frames the video
    /// with, as a translucent tint.
    public static let controlActiveFill = Color(red: 1.0, green: 0.62, blue: 0.04, opacity: 0.18)
    public static let controlActiveText = Color(red: 0.75, green: 0.46, blue: 0.02)
}

extension View {
    /// The rounded, faintly-tinted, hairline-bordered card the hub uses for its
    /// status/login modules. Apply *after* the content's own padding.
    ///
    /// The border is a background layer, not an `.overlay`: on WinUI,
    /// `renderPath` always gives `WinUI.Path` a fill brush (a transparent one
    /// for `Color.clear`), and XAML hit-testing keys on brush presence, not
    /// alpha — an overlaid stroke swallowed every mouse click in the card,
    /// leaving buttons reachable only by keyboard.
    public func hubCard(radius: Double = HubStyle.cardRadius) -> some View {
        hubCard(radius: radius, fill: HubStyle.cardFill, stroke: HubStyle.cardStroke)
    }

    /// `hubCard` with an explicit palette — for the share card, which tints
    /// itself green while a share is live (see `HubStyle.sharingCardFill`).
    public func hubCard(
        radius: Double = HubStyle.cardRadius,
        fill: Color,
        stroke: Color
    ) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius).fill(fill)
                RoundedRectangle(cornerRadius: radius).stroke(stroke)
            }
    }
}

/// A labelled action whose meaning is the host's to decide — "Take back
/// control", "Stop sharing". A struct, not two parameters, since these travel
/// in optionals/arrays where a mismatched label/action pair would be
/// unrenderable.
public struct HubAction: Sendable {
    public let label: String
    public let perform: @MainActor @Sendable () -> Void

    public init(label: String, perform: @escaping @MainActor @Sendable () -> Void) {
        self.label = label
        self.perform = perform
    }
}

/// A labelled on/off setting the chrome renders and the host owns. Plain
/// value + closure, not a `Binding`: this package must not know where the
/// setting is stored, and both apps rebuild `ShareCard` from a computed
/// property with no view-local state to bind to.
///
/// `caption` says what the setting does when the label alone is a noun
/// phrase — turning a security gate off should say what it will do.
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

/// The share-by-token half of a live share: the Share via Link toggle, the
/// link as selectable text (these toolkits have no clipboard affordance),
/// New Link, and guest count. Nil on `ShareCard` renders nothing.
public struct HubLinkSharing: Sendable {
    /// The live link's token; nil = link off (what the toggle shows).
    public let token: String?
    /// True while the link is being created or rotated (network-bound) — the
    /// card shows progress copy and ignores toggle flips meanwhile.
    public let busy: Bool
    /// Connected + pending guests, for the count line under the link.
    public let guestCount: Int
    /// No tailnet listener at all — started signed out, so the link is the
    /// only way in. States that instead of a toggle, since the off position
    /// would refuse to flip (only Stop ends a link-only share).
    public let isOnlyWayIn: Bool
    public let onToggle: @MainActor @Sendable (Bool) -> Void
    /// New Link rotation (the old link dies, guests drop). Nil hides it.
    public let onNewLink: (@MainActor @Sendable () -> Void)?
    /// Put the given text on the system clipboard — the host's seam, since
    /// neither swift-cross-ui nor this package can reach one.
    ///
    /// Nil renders the link as full selectable text instead of Copy buttons.
    /// Non-nil gets the macOS card's three buttons over one truncated line —
    /// the token is 120 characters that would otherwise wrap over three, twice.
    public let onCopy: (@MainActor @Sendable (String) -> Void)?

    public init(
        token: String?,
        busy: Bool,
        guestCount: Int,
        isOnlyWayIn: Bool = false,
        onToggle: @escaping @MainActor @Sendable (Bool) -> Void,
        onNewLink: (@MainActor @Sendable () -> Void)? = nil,
        onCopy: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.token = token
        self.busy = busy
        self.guestCount = guestCount
        self.isOnlyWayIn = isOnlyWayIn
        self.onToggle = onToggle
        self.onNewLink = onNewLink
        self.onCopy = onCopy
    }
}

/// Something asking the person at this machine for a yes or a no. One type
/// for two features — a viewer waiting to be admitted, and one asking for
/// control — since both are the same sentence-plus-two-buttons interaction.
///
/// Somebody currently watching this screen, and what the sharer can do about them.
///
/// Actions are three separate optionals, not a list: `onKick` is a one-time
/// disconnect, `onAlwaysAllow`/`onDenyAndBlock` are decisions about the
/// *person* that outlive the share. A host that can't do one passes nil.
///
/// `rememberIsDeferred`: a decision was made but the peer's Tailscale
/// identity hasn't resolved yet — the store is StableNodeID-keyed, so there's
/// a real wait. See `ViewerRosterDecision`.
public struct HubViewerRow: Identifiable, Sendable {
    /// Opaque to the chrome; handed back verbatim. The server's `"ip:port"`
    /// viewer key, never the bare IP.
    public let id: String
    /// Hostname once the netmap lookup lands, the IP until then.
    public let label: String
    /// How this viewer's connection is doing. The row derives both the dot
    /// colour and the sentence from this, so they can't disagree. A
    /// chrome-owned enum, not the server's `ViewerHealth` — this package must
    /// not import the sharer tier.
    public let health: HubViewerHealth
    /// What is remembered about this peer, so the row shows the standing
    /// decision instead of offering to make it again.
    public let remembered: HubViewerMemory
    /// True when a remember-decision is queued behind identity resolution.
    public let rememberIsDeferred: Bool
    public let onKick: (@MainActor @Sendable () -> Void)?
    public let onAlwaysAllow: (@MainActor @Sendable () -> Void)?
    public let onDenyAndBlock: (@MainActor @Sendable () -> Void)?
    public let onForget: (@MainActor @Sendable () -> Void)?
    /// A share-by-token guest: badged so the sharer can tell at a glance.
    /// Hosts pass the remember-actions as nil for guests, who have no
    /// StableNodeID (Deny already denylists the guest's node key at the tunnel).
    public let isGuest: Bool

    public init(
        id: String,
        label: String,
        health: HubViewerHealth = .good,
        remembered: HubViewerMemory = .none,
        rememberIsDeferred: Bool = false,
        onKick: (@MainActor @Sendable () -> Void)? = nil,
        onAlwaysAllow: (@MainActor @Sendable () -> Void)? = nil,
        onDenyAndBlock: (@MainActor @Sendable () -> Void)? = nil,
        onForget: (@MainActor @Sendable () -> Void)? = nil,
        isGuest: Bool = false
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
        self.isGuest = isGuest
    }
}

/// How a connected viewer's link is doing, as the chrome needs it — the
/// server's `ViewerHealth` case for case, mapped by each host so wording
/// stays identical on all three platforms.
public enum HubViewerHealth: Sendable, Equatable {
    /// No meaningful loss. The row says nothing — a sentence on every row would bury the one that matters.
    case good
    /// Over the loss threshold, but still getting full frames.
    case degraded
    /// Keyframe-only: this viewer's link is isolating the session.
    case throttled

    /// The sentence beside the dot, non-nil for everything but `.good` — the
    /// dot must not be the only carrier of a problem.
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

/// What the sharer has decided about a peer, if anything. Three states, not
/// `Bool?`: "nothing decided" is a real answer with its own affordances.
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
    /// A share-by-token guest knocking — badged, since this admits someone
    /// outside the tailnet.
    public let isGuest: Bool

    public init(
        id: String, message: String, acceptLabel: String = L("Allow"),
        declineLabel: String = L("Deny"), isGuest: Bool = false
    ) {
        self.id = id
        self.message = message
        self.acceptLabel = acceptLabel
        self.declineLabel = declineLabel
        self.isGuest = isGuest
    }
}

/// The header's signed-in line. Prefers the tailnet over the login, matching
/// the macOS hub — the screen list is scoped to a tailnet, so that's what
/// explains an expected machine being absent. Login is the fallback since
/// some control planes (headscale) report no tailnet name at all.
public func hubSignedInSubtitle(tailnet: String?, account: String?) -> String {
    if let tailnet, !tailnet.isEmpty { return tailnet }
    if let account, !account.isEmpty { return account }
    return L("Signed in")
}
