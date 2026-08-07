import AppKit

/// Single object the viewer window's AppKit toolbar targets. Routes
/// actions to whichever ``AnnotationCanvasModel`` is currently active and
/// to `AppState`. (The main-menu duties this used to carry moved into
/// SwiftUI `Commands` — see `AppCommands`; what stays is exactly what the
/// AppKit toolbar needs: target/action endpoints and toolbar validation,
/// plus the color-submenu's `NSMenuItemValidation` checkmarks.)
@MainActor
final class ViewerCommands: NSObject {
    static let shared = ViewerCommands()

    /// Weakly held so a viewer-window teardown doesn't keep the canvas
    /// alive past its window. Updated by the overlay's host whenever its
    /// window becomes/resigns key.
    weak var activeOverlay: AnnotationCanvasModel?

    /// Set by AppState during init so toolbar validation can read state.
    weak var appState: AppState?

    // MARK: - Tools

    /// NSToolbarItemGroup with `selectionMode = .selectOne` calls its
    /// action with the group as `sender`; the selectedIndex maps 1:1 to
    /// the toolbar's tool order (pen, line, arrow, rectangle, oval, click).
    @objc func toolbarSelectedTool(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        let tools: [AnnotationTool] = [.pen, .line, .arrow, .rectangle, .oval, .click]
        let idx = group.selectedIndex
        guard tools.indices.contains(idx) else { return }
        setTool(tools[idx])
    }

    private func setTool(_ tool: AnnotationTool) {
        activeOverlay?.currentTool = tool
        // Force the menu (and any toolbar validation) to re-evaluate so
        // the checkmark / selected segment moves.
        NSApp.mainMenu?.update()
    }

    /// Toolbar color menu → set the drawing color for new annotations.
    /// The sender's `tag` indexes `Annotation.RGBA.palette` (see
    /// `ViewerToolbar.makeColorMenu`).
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

    /// Toolbar mic button. Posts a notification AppState observes to
    /// toggle the local mic on/off during an active share or connection.
    @objc func toggleMicrophone(_ sender: Any?) {
        NotificationCenter.default.post(name: .tailscreenToggleMicrophone, object: nil)
    }

    /// Viewer-toolbar remote-control button: request when idle, cancel a
    /// pending request, or stop controlling — one affordance cycling the
    /// same state machine the menubar popover renders.
    @objc func toggleRemoteControlRequest(_ sender: Any?) {
        guard let appState else { return }
        switch appState.viewerControlState {
        case .none:
            appState.requestRemoteControl()
        case .requested, .controlling:
            appState.stopViewerControl()
        }
    }

    /// Toolbar → Show Stats. Flips the renderer's stats-overlay
    /// visibility. The hosting view subscribes to `model.$isVisible`
    /// with Combine, so the change propagates without an extra signal.
    @objc func toggleStatsOverlay(_ sender: Any?) {
        statsModel?.isVisible.toggle()
    }

    /// Weakly held reference to the viewer's stats model. AppState sets
    /// this on `ensureViewer()` so the toolbar action above can flip
    /// `isVisible` without depending on AppState directly.
    weak var statsModel: ViewerStatsModel?

    /// Help → Keyboard Shortcuts (⇧⌘/). With a viewer window on screen the
    /// cheat-sheet overlays it; while sharing (no viewer window) the same
    /// content opens in its own centered panel, so ⌘? answers everywhere a
    /// session is running.
    @objc func toggleShortcutsOverlay(_ sender: Any?) {
        if let appState, appState.viewerWindow?.isVisible != true {
            appState.toggleShortcutsPanel()
            return
        }
        shortcutsModel?.isVisible.toggle()
    }

    /// Weakly held reference to the shortcut overlay's model. Set by
    /// `AppState.ensureViewer()` alongside `statsModel`.
    weak var shortcutsModel: ViewerShortcutsModel?
}

extension ViewerCommands: NSMenuItemValidation {
    /// The one AppKit menu left after the main menu moved to SwiftUI
    /// Commands: the toolbar color item's submenu (`NSMenuToolbarItem`
    /// vends real `NSMenuItem`s, which validate through their target).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let overlay = activeOverlay
        switch menuItem.action {
        case #selector(selectAnnotationColor(_:)):
            // Checkmark on the current color; the tag indexes the palette.
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
    /// Explicit toolbar validation. The AppKit default re-enables any item
    /// whose target merely responds to its action — which silently undid
    /// `ViewerToolbar.setAnnotationsEnabled(false)` and left Undo/Clear
    /// clickable with nothing to undo or clear. Toolbar items target this
    /// object, so this is the single mirror of the menu validation above.
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
