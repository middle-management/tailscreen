import AppKit

/// Single object that NSMenu items target. Routes selectors to whichever
/// ``AnnotationCanvasModel`` is currently active (last keyed window's
/// overlay). AppMenu installs `mainMenu`'s items with
/// `target = ViewerCommands.shared`, so menus light up wherever the user
/// happens to be drawing.
@MainActor
final class ViewerCommands: NSObject {
    static let shared = ViewerCommands()

    /// Weakly held so a viewer-window teardown doesn't keep the canvas
    /// alive past its window. Updated by the overlay's host whenever its
    /// window becomes/resigns key.
    weak var activeOverlay: AnnotationCanvasModel?

    /// Set by AppState during init so menu validation can read mic state.
    weak var appState: AppState?

    // MARK: - Tools

    @objc func selectPenTool(_ sender: Any?) { setTool(.pen) }
    @objc func selectLineTool(_ sender: Any?) { setTool(.line) }
    @objc func selectArrowTool(_ sender: Any?) { setTool(.arrow) }
    @objc func selectRectangleTool(_ sender: Any?) { setTool(.rectangle) }
    @objc func selectOvalTool(_ sender: Any?) { setTool(.oval) }
    @objc func selectClickTool(_ sender: Any?) { setTool(.click) }

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

    // MARK: - Edit

    @objc func undoLastAnnotation(_ sender: Any?) {
        activeOverlay?.performLocalUndo()
    }

    @objc func clearAllAnnotations(_ sender: Any?) {
        activeOverlay?.clearAll()
    }

    // MARK: - Application

    /// App menu → Settings… (⌘,). Opens the preferences window; `AppState`
    /// owns the `NSWindow` + hosting controller and the activation-policy
    /// promotion an `.accessory` app needs to key it.
    @objc func openSettings(_ sender: Any?) {
        appState?.presentSettings()
    }

    // MARK: - Window

    /// File → Disconnect. Posts a notification AppState observes — that
    /// keeps menu wiring decoupled from the actor-isolated AppState.
    @objc func disconnectViewer(_ sender: Any?) {
        NotificationCenter.default.post(name: .tailscreenDisconnectRequested, object: nil)
    }

    /// File → Microphone. Posts a notification AppState observes to
    /// toggle the local mic on/off during an active share or connection.
    @objc func toggleMicrophone(_ sender: Any?) {
        NotificationCenter.default.post(name: .tailscreenToggleMicrophone, object: nil)
    }

    /// Toolbar/menu → Show Stats. Flips the renderer's stats-overlay
    /// visibility. The hosting view subscribes to `model.$isVisible`
    /// with Combine, so the change propagates without an extra signal.
    @objc func toggleStatsOverlay(_ sender: Any?) {
        statsModel?.isVisible.toggle()
    }

    // MARK: - View

    /// View → Actual Size (⌘0). Snaps the viewer window so the captured
    /// video renders at 1:1 pixel mapping.
    @objc func viewerZoomActualSize(_ sender: Any?) {
        postViewerZoom(1.0)
    }

    /// View → 50% (⌘-). Half-scale view; useful for very large shares
    /// on small viewer displays.
    @objc func viewerZoomHalf(_ sender: Any?) {
        postViewerZoom(0.5)
    }

    /// View → 200% (⌘+). Double-scale view for legibility on tiny
    /// captured windows. AppState clamps the resulting frame to the
    /// screen's `visibleFrame` so it can't grow off-screen.
    @objc func viewerZoomDouble(_ sender: Any?) {
        postViewerZoom(2.0)
    }

    private func postViewerZoom(_ factor: Double) {
        NotificationCenter.default.post(
            name: .tailscreenViewerSetZoom,
            object: nil,
            userInfo: ["factor": factor])
    }

    /// View → Zoom In (⇧⌘+). Continuous *content* zoom — magnifies a
    /// region of the received video inside the current window, unlike the
    /// presets above which resize the window itself. Center-anchored;
    /// pinch and ⌥-scroll on the viewer zoom at the cursor instead.
    @objc func viewerContentZoomIn(_ sender: Any?) {
        postViewerContentZoom(1.25)
    }

    /// View → Zoom Out (⇧⌘-). Inverse step of `viewerContentZoomIn`;
    /// clamps back to aspect-fit at 1×.
    @objc func viewerContentZoomOut(_ sender: Any?) {
        postViewerContentZoom(1.0 / 1.25)
    }

    private func postViewerContentZoom(_ delta: Double) {
        NotificationCenter.default.post(
            name: .tailscreenViewerContentZoom,
            object: nil,
            userInfo: ["delta": delta])
    }

    /// Weakly held reference to the viewer's stats model. AppState sets
    /// this on `ensureViewer()` so the toolbar action above can flip
    /// `isVisible` without depending on AppState directly.
    weak var statsModel: ViewerStatsModel?

    /// Help → Keyboard Shortcuts (⇧⌘/). Flips the visibility of the
    /// shortcut cheat-sheet overlay above the viewer window.
    @objc func toggleShortcutsOverlay(_ sender: Any?) {
        shortcutsModel?.isVisible.toggle()
    }

    /// Weakly held reference to the shortcut overlay's model. Set by
    /// `AppState.ensureViewer()` alongside `statsModel`.
    weak var shortcutsModel: ViewerShortcutsModel?
}

extension ViewerCommands: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let overlay = activeOverlay
        switch menuItem.action {
        case #selector(selectPenTool(_:)):
            menuItem.state = (overlay?.currentTool == .pen) ? .on : .off
            return overlay != nil
        case #selector(selectLineTool(_:)):
            menuItem.state = (overlay?.currentTool == .line) ? .on : .off
            return overlay != nil
        case #selector(selectArrowTool(_:)):
            menuItem.state = (overlay?.currentTool == .arrow) ? .on : .off
            return overlay != nil
        case #selector(selectRectangleTool(_:)):
            menuItem.state = (overlay?.currentTool == .rectangle) ? .on : .off
            return overlay != nil
        case #selector(selectOvalTool(_:)):
            menuItem.state = (overlay?.currentTool == .oval) ? .on : .off
            return overlay != nil
        case #selector(selectClickTool(_:)):
            menuItem.state = (overlay?.currentTool == .click) ? .on : .off
            return overlay != nil
        case #selector(undoLastAnnotation(_:)):
            return overlay?.canUndo ?? false
        case #selector(clearAllAnnotations(_:)):
            return overlay?.canClearAll ?? false
        case #selector(disconnectViewer(_:)):
            return true
        case #selector(toggleMicrophone(_:)):
            let isOn = appState?.isMicOn ?? false
            menuItem.state = isOn ? .on : .off
            menuItem.title = isOn ? L("Mute Microphone") : L("Unmute Microphone")
            return appState != nil
        case #selector(toggleStatsOverlay(_:)):
            let isVisible = statsModel?.isVisible ?? false
            menuItem.state = isVisible ? .on : .off
            return statsModel != nil
        case #selector(toggleShortcutsOverlay(_:)):
            let isVisible = shortcutsModel?.isVisible ?? false
            menuItem.state = isVisible ? .on : .off
            return shortcutsModel != nil
        case #selector(viewerZoomActualSize(_:)),
            #selector(viewerZoomHalf(_:)),
            #selector(viewerZoomDouble(_:)),
            #selector(viewerContentZoomIn(_:)),
            #selector(viewerContentZoomOut(_:)):
            // `setViewerZoom` / `zoomViewerContent` already no-op when
            // there's no viewer window or no decoded frame yet, so leaving
            // these enabled always is harmless — and avoids the pill-style
            // menus on macOS 15+ rendering disabled items so faintly that
            // users miss them entirely.
            return true
        default:
            return true
        }
    }
}

extension Notification.Name {
    static let tailscreenDisconnectRequested = Notification.Name("tailscreen.disconnect.requested")
    static let tailscreenToggleMicrophone = Notification.Name("tailscreen.toggleMicrophone")
    static let tailscreenViewerSetZoom = Notification.Name("tailscreen.viewer.setZoom")
    static let tailscreenViewerContentZoom = Notification.Name("tailscreen.viewer.contentZoom")
}
