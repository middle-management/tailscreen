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

    // MARK: - Application

    /// App menu → Settings… (⌘,). Opens the preferences window; `AppState`
    /// owns the `NSWindow` + hosting controller.
    @objc func openSettings(_ sender: Any?) {
        appState?.presentSettings()
    }

    /// Window → Tailscreen (also the menubar popover's "Open Tailscreen"
    /// row). Opens or re-focuses the docked main window.
    @objc func showMainWindow(_ sender: Any?) {
        appState?.presentMainWindow()
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

    /// File → Stop Remote Control (⌃⌥.). Instantly revokes any live
    /// remote-control grant the sharer has issued. Menu-validated to only
    /// enable while a viewer holds control.
    @objc func stopRemoteControl(_ sender: Any?) {
        appState?.revokeRemoteControl(reason: "menu")
    }

    /// File → Release Remote Control (⌃⌥., viewer side). Releases the
    /// control *we* hold on someone else's Mac (or cancels a pending
    /// request). Shares the chord with the sharer-side revoke above;
    /// validation keeps the two disjoint by state.
    @objc func releaseRemoteControl(_ sender: Any?) {
        appState?.stopViewerControl()
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

    /// View → Enter Full Screen (⌃⌘F). Targets the viewer window
    /// specifically — a responder-chain `toggleFullScreen` would grab
    /// whichever window happens to be key, hub included.
    @objc func toggleViewerFullScreen(_ sender: Any?) {
        appState?.toggleViewerWindowFullScreen()
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

    /// View → Zoom In (⌥⌘+). Continuous *content* zoom — magnifies a
    /// region of the received video inside the current window, unlike the
    /// presets above which resize the window itself. Center-anchored;
    /// pinch and ⌥-scroll on the viewer zoom at the cursor instead.
    /// Routed straight into AppState (both classes are @MainActor) —
    /// no notification hop needed.
    @objc func viewerContentZoomIn(_ sender: Any?) {
        appState?.zoomViewerContent(by: ViewerZoomMath.menuZoomStep)
    }

    /// View → Zoom Out (⌥⌘-). Inverse step of `viewerContentZoomIn`;
    /// clamps back to aspect-fit at 1×.
    @objc func viewerContentZoomOut(_ sender: Any?) {
        appState?.zoomViewerContent(by: 1 / ViewerZoomMath.menuZoomStep)
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
        case #selector(selectAnnotationColor(_:)):
            // Checkmark on the current color; the tag indexes the palette.
            let palette = Annotation.RGBA.palette
            let isCurrent =
                palette.indices.contains(menuItem.tag)
                && overlay?.currentColor == palette[menuItem.tag]
            menuItem.state = isCurrent ? .on : .off
            return overlay != nil && (appState?.sharerSupportsAnnotations ?? true)
        case #selector(disconnectViewer(_:)):
            // ⌘W acts on an actual session: disconnect while viewing, or
            // close the ended-state viewer window. Anything else has no
            // session to end.
            guard let appState else { return false }
            return appState.connectionState == .viewing || appState.viewerSessionEnding != nil
        case #selector(stopRemoteControl(_:)):
            // Sharer-side: enabled only while a viewer is actively
            // controlling. The chord is shared with Release Remote Control
            // below, and sharing-while-viewing makes both roles live at
            // once — menu key equivalents dispatch to the FIRST enabled
            // item, so while *we* are controlling someone else's Mac the
            // release must win the chord (revoking our own grantee on a
            // release keypress would be the wrong grant). Yielding here
            // only cedes the keypress — the sharer-side revoke stays one
            // click away in the SharingCard either way.
            guard let appState else { return false }
            return appState.controlGrantee != nil
                && appState.viewerControlState != .controlling
        case #selector(releaseRemoteControl(_:)):
            // Viewer-side ⌃⌥.; see the disambiguation note above.
            return appState?.viewerControlState == .controlling
        case #selector(toggleViewerFullScreen(_:)):
            guard let win = appState?.viewerWindow else { return false }
            menuItem.title =
                win.styleMask.contains(.fullScreen)
                ? L("Exit Full Screen") : L("Enter Full Screen")
            return win.isVisible
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
            let overlayUp = shortcutsModel?.isVisible ?? false
            let panelUp = appState?.isShortcutsPanelVisible ?? false
            menuItem.state = (overlayUp || panelUp) ? .on : .off
            // ⌘? answers while sharing too, not only in the viewer window
            // (the panel presentation covers the no-viewer-window case).
            guard let appState else { return shortcutsModel != nil }
            let sharing = appState.sharingState != .idle
            let viewing = appState.viewerWindow?.isVisible == true
            return sharing || viewing || panelUp
        case #selector(viewerZoomActualSize(_:)),
            #selector(viewerZoomHalf(_:)),
            #selector(viewerZoomDouble(_:)),
            #selector(viewerContentZoomIn(_:)),
            #selector(viewerContentZoomOut(_:)):
            // Zoom acts on a live stream. The old always-enabled answer
            // left ⌘0/⌘±/⌥⌘± silently no-op'ing with no session at all.
            return appState?.connectionState == .viewing
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
