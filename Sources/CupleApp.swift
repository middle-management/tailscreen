import AppKit
import SwiftUI

@main
struct CupleApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // The menubar icon reflects current state: a slashed tv while
        // not yet authenticated, a "broadcasting" tv with a tower icon
        // glyph while sharing, a play-glyph tv while viewing a remote
        // share, and a plain tv at idle. SwiftUI re-evaluates this
        // expression whenever AppState publishes a change, so the icon
        // updates without explicit binding.
        MenuBarExtra("Cuple", systemImage: menubarIconName) {
            MenuBarView()
                .environmentObject(appState)
                .task {
                    // Install the NSMenu the first time the menubar
                    // popover renders. Doing this in CupleApp.init()
                    // crashes — NSApp isn't set up yet at that point.
                    AppMenu.installIfNeeded()
                }
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
