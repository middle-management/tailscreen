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
        if appState.isSharing {
            Image(systemName: "dot.radiowaves.left.and.right")
        } else if appState.isConnected {
            Image(systemName: "play.tv")
        } else if let brand = Self.brandMenubarImage {
            // Brand glyph for idle / unauth states. NSImage marked as a
            // template so macOS auto-tints it for light/dark menubar.
            Image(nsImage: brand)
        } else {
            // Bundle resource missing — fall back to SF Symbols so the
            // menu item still has *something* and never disappears.
            Image(systemName: appState.tailscaleAuth.isAuthenticated ? "tv" : "tv.slash")
        }
    }

    /// Loaded once at first access. The PDF lives in `Sources/Resources/`
    /// and is delivered via SwiftPM `Bundle.module`. `isTemplate = true`
    /// is what tells AppKit to render it as a 1-bit menubar mask rather
    /// than as the raw artwork.
    private static let brandMenubarImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "MenubarIcon", withExtension: "pdf"),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        img.isTemplate = true
        // Standard menubar glyph height. AppKit scales the PDF
        // accordingly and the user's "Menu bar size" preference still
        // applies on top.
        img.size = NSSize(width: 18, height: 18)
        return img
    }()
}
