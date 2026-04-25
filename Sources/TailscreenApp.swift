import SwiftUI

@main
struct TailscreenApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // The menubar icon reflects current state: a slashed tv while
        // not yet authenticated, a "broadcasting" tv with a tower icon
        // glyph while sharing, a play-glyph tv while viewing a remote
        // share, and a plain tv at idle. SwiftUI re-evaluates this
        // expression whenever AppState publishes a change, so the icon
        // updates without explicit binding.
        MenuBarExtra("Tailscreen", systemImage: menubarIconName) {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }

    private var menubarIconName: String {
        if !appState.tailscaleAuth.isAuthenticated {
            // Loading and "logged out" share the same glyph; the menu
            // itself shows a "Signing in…" row while isLoading.
            return "tv.slash"
        }
        if appState.isSharing { return "dot.radiowaves.left.and.right" }
        if appState.isConnected { return "play.tv" }
        return "tv"
    }
}
