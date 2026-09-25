import AppKit
import SwiftUI

/// Pure decision, unit-testable (`MenubarIconStateTests`): an active
/// share/view always wins; a pending request-to-share only surfaces while
/// fully idle, mirroring `PendingRequestsBanner`. While sharing, a pending
/// control request or waiting viewer badges the glyph, since the OS
/// notification is bundled-app-only. Control outranks a waiting viewer.
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
        if sharing == .sharing {
            if hasControlRequests { return .sharingControlRequested }
            if hasWaitingViewers { return .sharingViewerWaiting }
            return .sharing
        }
        if connection == .viewing { return .viewing }
        // Matches the popover's own banner gate.
        if hasPendingRequests && !sharing.isLive && connection == .idle {
            return .requestPending
        }
        return .idle
    }
}

struct TailscreenApp: App {
    @StateObject private var appState = AppState()

    /// `AppState.presentMainWindow` re-opens the scene through the stashed
    /// `openWindow` action and, as a fallback, matches `NSWindow.identifier`
    /// prefixes against this. `nonisolated` (SE-0434) so non-MainActor
    /// contexts can read it too.
    nonisolated static let mainWindowID = "main"

    var body: some Scene {
        // Presented at launch like a normal Mac app; closing it leaves the
        // app running in the menubar.
        Window("Tailscreen", id: Self.mainWindowID) {
            MainWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 400, height: 580)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        // Toolbar carries the identity block instead of a window title.
        .windowStyle(.hiddenTitleBar)
        // See `AppCommands` for why this replaced a hand-built `NSMenu`
        // (scene updates used to stomp it mid-share).
        .commands {
            AppCommands(appState: appState)
        }

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
                // Bundle resources missing — fall back to SF Symbols.
                Image(systemName: appState.tailscaleAuth.isAuthenticated ? "tv" : "tv.slash")
            }
        }
        .accessibilityLabel(label)
    }

    private static let idleImage = loadMenubarTemplate("MenubarIcon")
    private static let sharingImage = loadMenubarTemplate("MenubarSharing")
    private static let viewingImage = loadMenubarTemplate("MenubarViewing")

    /// Composed at runtime rather than shipping a fourth PDF, so the badge
    /// can never drift from the base artwork.
    private static let requestImage = idleImage.map(badgedWithAttentionDot)

    /// One image for both control-request and waiting-viewer states: at 6pt
    /// in an 18pt template, distinct badge shapes wouldn't read; the
    /// accessibility label disambiguates.
    private static let sharingAttentionImage = sharingImage.map(badgedWithAttentionDot)

    /// A slightly larger circle is knocked out of the base first, so the dot
    /// reads as a badge rather than a smudge.
    ///
    /// `nonisolated`: `TailscreenApp` is MainActor-isolated and
    /// `Optional.map` takes a nonisolated function value; the body only
    /// constructs an NSImage (the drawing handler runs later), so it's safe.
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

    /// Sizes to Apple HIG's 18pt status-item recommendation.
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
