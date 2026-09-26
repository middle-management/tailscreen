import AppKit

/// Single object the viewer window's AppKit toolbar targets. Routes actions
/// to whichever ``AnnotationCanvasModel`` is currently active and to
/// `AppState`. Main-menu duties moved to SwiftUI `Commands` (`AppCommands`);
/// what remains is target/action endpoints, toolbar validation, and the
/// color-submenu's checkmarks.
@MainActor
final class ViewerCommands: NSObject {
    static let shared = ViewerCommands()

    /// Weakly held so a viewer-window teardown doesn't keep the canvas alive
    /// past its window.
    weak var activeOverlay: AnnotationCanvasModel?

    weak var appState: AppState?

    // MARK: - Tools

    /// `selectionMode = .selectOne` calls its action with the group as
    /// `sender`; `selectedIndex` maps 1:1 to the toolbar's tool order.
    @objc func toolbarSelectedTool(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        let tools: [AnnotationTool] = [.pen, .line, .arrow, .rectangle, .oval, .click]
        let idx = group.selectedIndex
        guard tools.indices.contains(idx) else { return }
        setTool(tools[idx])
    }

    private func setTool(_ tool: AnnotationTool) {
        activeOverlay?.currentTool = tool
        NSApp.mainMenu?.update()  // re-evaluate so the checkmark/segment moves
    }

    /// `sender`'s `tag` indexes `Annotation.RGBA.palette`.
    @objc func selectAnnotationColor(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let palette = Annotation.RGBA.palette
        guard palette.indices.contains(item.tag) else { return }
        activeOverlay?.currentColor = palette[item.tag]
    }

    // MARK: - Edit

    @objc func undoLastAnnotation(_ sender: Any?) {
        activeOverlay?.performLocalUndo()
    }

    @objc func clearAllAnnotations(_ sender: Any?) {
        activeOverlay?.clearAll()
    }

    // MARK: - Toolbar actions

    @objc func toggleMicrophone(_ sender: Any?) {
        NotificationCenter.default.post(name: .tailscreenToggleMicrophone, object: nil)
    }

    /// Request when idle, cancel a pending request, or stop controlling — one
    /// affordance cycling the state machine the menubar popover renders.
    @objc func toggleRemoteControlRequest(_ sender: Any?) {
        guard let appState else { return }
        switch appState.viewerControlState {
        case .none:
            appState.requestRemoteControl()
        case .requested, .controlling:
            appState.stopViewerControl()
        }
    }

    @objc func openLinkOnSharer(_ sender: Any?) {
        appState?.presentOpenLinkSheet()
    }

    @objc func toggleStatsOverlay(_ sender: Any?) {
        statsModel?.isVisible.toggle()
    }

    /// Set by AppState on `ensureViewer()`.
    weak var statsModel: ViewerStatsModel?

    /// With a viewer window on screen the cheat-sheet overlays it; while
    /// sharing (no viewer window) the same content opens in its own panel.
    @objc func toggleShortcutsOverlay(_ sender: Any?) {
        if let appState, appState.viewerWindow?.isVisible != true {
            appState.toggleShortcutsPanel()
            return
        }
        shortcutsModel?.isVisible.toggle()
    }

    weak var shortcutsModel: ViewerShortcutsModel?
}

extension ViewerCommands: NSMenuItemValidation {
    /// The one AppKit menu left after the main menu moved to SwiftUI Commands.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let overlay = activeOverlay
        switch menuItem.action {
        case #selector(selectAnnotationColor(_:)):
            let palette = Annotation.RGBA.palette
            let isCurrent =
                palette.indices.contains(menuItem.tag)
                && overlay?.currentColor == palette[menuItem.tag]
            menuItem.state = isCurrent ? .on : .off
            return overlay != nil && (appState?.sharerSupportsAnnotations ?? true)
        default:
            return true
        }
    }
}

extension ViewerCommands: NSToolbarItemValidation {
    /// The AppKit default re-enables any item whose target merely responds
    /// to its action, which silently undid `ViewerToolbar.setAnnotationsEnabled(false)`.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let annotationsAvailable = appState?.sharerSupportsAnnotations ?? true
        switch item.action {
        case #selector(toolbarSelectedTool(_:)):
            return annotationsAvailable && activeOverlay != nil
        case #selector(undoLastAnnotation(_:)):
            return annotationsAvailable && (activeOverlay?.canUndo ?? false)
        case #selector(clearAllAnnotations(_:)):
            return annotationsAvailable && (activeOverlay?.canClearAll ?? false)
        case #selector(toggleRemoteControlRequest(_:)):
            guard let appState else { return false }
            // Requesting needs a live session against a supporting sharer;
            // the cancel/stop forms stay enabled so an exit affordance
            // can't grey out mid-teardown.
            return appState.viewerControlState != .none
                || (appState.sharerSupportsRemoteControl && appState.connectionState == .viewing)
        case #selector(openLinkOnSharer(_:)):
            guard let appState else { return false }
            return appState.sharerSupportsOpenLink && appState.connectionState == .viewing
        default:
            return true
        }
    }
}

extension Notification.Name {
    static let tailscreenDisconnectRequested = Notification.Name("tailscreen.disconnect.requested")
    static let tailscreenToggleMicrophone = Notification.Name("tailscreen.toggleMicrophone")
    static let tailscreenViewerSetZoom = Notification.Name("tailscreen.viewer.setZoom")
}
