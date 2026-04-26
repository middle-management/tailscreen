import AppKit
import SwiftUI

@main
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
                .task {
                    // Install the NSMenu the first time the menubar
                    // popover renders. Doing this in TailscreenApp.init()
                    // crashes — NSApp isn't set up yet at that point.
                    AppMenu.installIfNeeded()
                }
        } label: {
            menubarIcon
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menubarIcon: some View {
        if appState.isSharing, let img = Self.sharingImage {
            Image(nsImage: img)
        } else if appState.isConnected, let img = Self.viewingImage {
            Image(nsImage: img)
        } else if let img = Self.idleImage {
            Image(nsImage: img)
        } else {
            // Bundle resources missing — fall back to SF Symbols so the
            // menu item still has *something* and never disappears.
            Image(systemName: appState.tailscaleAuth.isAuthenticated ? "tv" : "tv.slash")
        }
    }

    /// Idle / unauthenticated brand glyph (TV outline).
    private static let idleImage = loadMenubarTemplate("MenubarIcon")

    /// Active-sharing variant: same TV silhouette, screen filled solid
    /// — visual echo of macOS's screen-recording badge.
    private static let sharingImage = loadMenubarTemplate("MenubarSharing")

    /// Active-viewing variant: TV outline with a centred play triangle.
    private static let viewingImage = loadMenubarTemplate("MenubarViewing")

    /// Load a PDF from `Sources/Resources/` (delivered via SwiftPM
    /// `Bundle.module`), mark it as a menubar template image, and size it
    /// to Apple HIG's 18pt status-item recommendation.
    /// https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras
    private static func loadMenubarTemplate(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }
}
