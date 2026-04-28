import AppKit

/// Single object that NSMenu items target. Routes selectors to whichever
/// ``DrawingOverlayView`` is currently active (last keyed window's overlay).
/// AppMenu installs `mainMenu`'s items with `target = ViewerCommands.shared`,
/// so menus light up wherever the user happens to be drawing.
@MainActor
final class ViewerCommands: NSObject {
    static let shared = ViewerCommands()

    /// Weakly held so a viewer-window teardown doesn't keep the overlay
    /// alive past its window. Updated by the overlay's host whenever its
    /// window becomes/resigns key.
    weak var activeOverlay: DrawingOverlayView?

    // MARK: - Tools

    @objc func selectPenTool(_ sender: Any?) { setTool(.pen) }
    @objc func selectLineTool(_ sender: Any?) { setTool(.line) }
    @objc func selectArrowTool(_ sender: Any?) { setTool(.arrow) }
    @objc func selectRectangleTool(_ sender: Any?) { setTool(.rectangle) }
    @objc func selectOvalTool(_ sender: Any?) { setTool(.oval) }

    /// NSToolbarItemGroup with `selectionMode = .selectOne` calls its
    /// action with the group as `sender`; the selectedIndex maps 1:1 to
    /// the toolbar's tool order (pen, line, arrow, rectangle, oval).
    @objc func toolbarSelectedTool(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        let tools: [AnnotationTool] = [.pen, .line, .arrow, .rectangle, .oval]
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
        case #selector(undoLastAnnotation(_:)):
            return overlay?.canUndo ?? false
        case #selector(clearAllAnnotations(_:)):
            return overlay?.canClearAll ?? false
        case #selector(disconnectViewer(_:)):
            return true
        case #selector(toggleMicrophone(_:)):
            return true
        default:
            return true
        }
    }
}

extension Notification.Name {
    static let tailscreenDisconnectRequested = Notification.Name("tailscreen.disconnect.requested")
    static let tailscreenToggleMicrophone = Notification.Name("tailscreen.toggleMicrophone")
}
