import AppKit
import SwiftUI

/// Which glyph the menubar status item shows. Pure decision extracted from
/// the label builder so the precedence is unit-testable
/// (`MenubarIconStateTests`): an active share or view always wins, and a
/// pending request-to-share only surfaces while the app is fully idle —
/// mirroring `PendingRequestsBanner`, which keeps requests queued but
/// invisible while a share/connection is up or in flight. While sharing,
/// a pending remote-control request or a viewer parked on the approval
/// gate badges the sharing glyph — both are decisions only the sharer can
/// unblock, and the OS notification is bundled-app-only, so the menubar
/// must carry the signal too. Control outranks a waiting viewer: granting
/// control of the Mac is the higher-stakes prompt.
enum MenubarIconState: Equatable {
    case sharing
    case sharingControlRequested
    case sharingViewerWaiting
    case viewing
    case requestPending
    case idle

    static func from(
        sharing: SharingState,
        connection: ConnectionState,
        hasPendingRequests: Bool,
        hasControlRequests: Bool,
        hasWaitingViewers: Bool
    ) -> MenubarIconState {
        if sharing == .active {
            // Control requests and pending viewers only exist while a
            // share is up (the server surfaces them and stopSharing
            // clears them), so these badges are meaningful only on the
            // sharing glyph.
            if hasControlRequests { return .sharingControlRequested }
            if hasWaitingViewers { return .sharingViewerWaiting }
            return .sharing
        }
        if connection == .viewing { return .viewing }
        if hasPendingRequests && sharing == .idle && connection == .idle {
            return .requestPending
        }
        return .idle
    }
}

struct TailscreenApp: App {
    @StateObject private var appState = AppState()

    /// Scene id of the docked main window. `AppState.presentMainWindow`
    /// re-opens the scene through the stashed `openWindow` action and, as a
    /// fallback, matches `NSWindow.identifier` prefixes against this.
    /// `nonisolated` (SE-0434) so non-MainActor contexts could read the
    /// constant too.
    nonisolated static let mainWindowID = "main"

    var body: some Scene {
        // The docked main window — the app's hub (sign-in, peer list,
        // identity). Presented at launch like a normal Mac app; closing it
        // leaves the app running in the menubar. The MenuBarExtra below
        // stays focused on the sharing session ("the sharer tool").
        Window("Tailscreen", id: Self.mainWindowID) {
            MainWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 400, height: 580)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        // The toolbar carries the identity block ("Tailscreen" + tailnet
        // login) instead of a window title — the Tailscale-app look.
        .windowStyle(.hiddenTitleBar)
        // The whole menu bar, declared where SwiftUI owns it — see
        // `AppCommands` for why this replaced the hand-built `NSMenu`
        // (scene updates used to stomp the AppKit menu mid-share).
        .commands {
            AppCommands(appState: appState)
        }

        // The menubar icon shows the brand mark at idle and switches to
        // state-conveying SF Symbols while sharing or viewing — the
        // brand glyph alone wouldn't tell the user *what* the app is
        // doing right now. SwiftUI re-evaluates this whenever AppState
        // publishes a change, so the icon updates without explicit
        // binding.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            menubarIcon
        }
        .menuBarExtraStyle(.window)
    }

    private var menubarIcon: some View {
        let state = MenubarIconState.from(
            sharing: appState.sharingState,
            connection: appState.connectionState,
            hasPendingRequests: !appState.pendingShareRequests.isEmpty,
            hasControlRequests: !appState.controlRequests.isEmpty,
            hasWaitingViewers: !appState.pendingViewers.isEmpty
        )
        let image: NSImage?
        let label: String
        switch state {
        case .sharing:
            image = Self.sharingImage
            label = L("Tailscreen: sharing your screen")
        case .sharingControlRequested:
            image = Self.sharingAttentionImage
            label = L("Tailscreen: a viewer is asking to control your Mac")
        case .sharingViewerWaiting:
            image = Self.sharingAttentionImage
            label = L("Tailscreen: a viewer is waiting for your approval")
        case .viewing:
            image = Self.viewingImage
            label = L("Tailscreen: viewing a shared screen")
        case .requestPending:
            image = Self.requestImage
            label = L("Tailscreen: someone wants you to share")
        case .idle:
            image = Self.idleImage
            label = "Tailscreen"
        }
        return Group {
            if let image {
                Image(nsImage: image)
            } else {
                // Bundle resources missing — fall back to SF Symbols so the
                // menu item still has *something* and never disappears.
                Image(systemName: appState.tailscaleAuth.isAuthenticated ? "tv" : "tv.slash")
            }
        }
        .accessibilityLabel(label)
    }

    /// Idle / unauthenticated brand glyph (TV outline).
    private static let idleImage = loadMenubarTemplate("MenubarIcon")

    /// Active-sharing variant: same TV silhouette, screen filled solid
    /// — visual echo of macOS's screen-recording badge.
    private static let sharingImage = loadMenubarTemplate("MenubarSharing")

    /// Active-viewing variant: TV outline with a centred play triangle.
    private static let viewingImage = loadMenubarTemplate("MenubarViewing")

    /// Idle glyph with an attention dot at top-right, shown while a
    /// request-to-share is waiting for the user. Composed at runtime from
    /// the idle template (rather than shipping a fourth PDF) so the badge
    /// can never drift from the base artwork. `nil` exactly when the base
    /// is missing — the SF Symbol fallback in `menubarIcon` covers that.
    private static let requestImage = idleImage.map(badgedWithAttentionDot)

    /// Sharing glyph with the same attention dot, shown while a viewer's
    /// remote-control request is awaiting Grant / Deny or a viewer is
    /// parked on the approval gate awaiting Accept / Deny. One image for
    /// both: at 6pt in an 18pt template, distinct badge shapes wouldn't
    /// read — the accessibility label and the popover disambiguate.
    /// Reuses the sharing template so the "you are sharing" signal stays
    /// visible under the badge.
    private static let sharingAttentionImage = sharingImage.map(badgedWithAttentionDot)

    /// Draw `base` with a small filled dot in the top-right corner. A
    /// slightly larger circle is knocked out of the base first so the dot
    /// is separated from the TV outline by a transparent gap and reads as
    /// a badge rather than a smudge. The result stays a template image, so
    /// it adapts to menubar appearance like the other states.
    ///
    /// `nonisolated` because `TailscreenApp` is MainActor-isolated (via
    /// `App`) and `Optional.map` takes a nonisolated function value —
    /// passing an isolated method there is a Swift 6 error. The body only
    /// constructs an NSImage (the drawing handler runs later, at render
    /// time), so it has no main-actor dependency.
    private nonisolated static func badgedWithAttentionDot(_ base: NSImage) -> NSImage {
        let dotDiameter: CGFloat = 6
        let gap: CGFloat = 1.5
        let badged = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let dotRect = NSRect(
                x: rect.maxX - dotDiameter,
                y: rect.maxY - dotDiameter,
                width: dotDiameter,
                height: dotDiameter)
            if let cg = NSGraphicsContext.current?.cgContext {
                cg.setBlendMode(.destinationOut)
                cg.setFillColor(NSColor.black.cgColor)
                cg.fillEllipse(in: dotRect.insetBy(dx: -gap, dy: -gap))
                cg.setBlendMode(.normal)
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        badged.isTemplate = true
        return badged
    }

    /// Load a PDF from `Sources/Resources/` (delivered via SwiftPM
    /// `Bundle.module`), mark it as a menubar template image, and size it
    /// to Apple HIG's 18pt status-item recommendation.
    /// https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras
    private static func loadMenubarTemplate(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
            let img = NSImage(contentsOf: url)
        else {
            return nil
        }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }
}
