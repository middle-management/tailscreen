import AppKit
import SwiftUI

/// Which glyph the menubar status item shows. Pure decision extracted from
/// the label builder so the precedence is unit-testable
/// (`MenubarIconStateTests`): an active share or view always wins, and a
/// pending request-to-share only surfaces while the app is fully idle —
/// mirroring `PendingRequestsBanner`, which keeps requests queued but
/// invisible while a share/connection is up or in flight.
enum MenubarIconState: Equatable {
    case sharing
    case viewing
    case requestPending
    case idle

    static func from(
        sharing: SharingState,
        connection: ConnectionState,
        hasPendingRequests: Bool
    ) -> MenubarIconState {
        if sharing == .active { return .sharing }
        if connection == .viewing { return .viewing }
        if hasPendingRequests && sharing == .idle && connection == .idle {
            return .requestPending
        }
        return .idle
    }
}

struct TailscreenApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
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
            hasPendingRequests: !appState.metadataService.pendingRequests.isEmpty
        )
        let image: NSImage?
        let label: String
        switch state {
        case .sharing:
            image = Self.sharingImage
            label = L("Tailscreen: sharing your screen")
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
