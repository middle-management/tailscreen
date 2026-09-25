import AppKit
import SwiftUI

/// AppKit shell that hosts ``AnnotationCanvasView``, forwarding what SwiftUI
/// doesn't cover for a borderless overlay panel:
///
///   • `acceptsFirstMouse` so a click registers without activating the app
///     first (the sharer panel sits at `.statusBar` level).
///   • `keyDown` for tool shortcuts, Cmd-Z, Esc — `.onKeyPress` doesn't
///     reliably get focus in a borderless panel.
///   • `rightMouseDown` for clear-all — SwiftUI has no right-click gesture.
@MainActor
final class AnnotationOverlayHostView: NSView {
    let model: AnnotationCanvasModel
    private let hostingView: NSHostingView<AnnotationCanvasView>

    init(model: AnnotationCanvasModel) {
        self.model = model
        self.hostingView = NSHostingView(rootView: AnnotationCanvasView(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard model.isInputEnabled else {
            super.rightMouseDown(with: event)
            return
        }
        model.clearAll()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            model.escapePressed()
            return
        }
        if event.modifierFlags.contains(.command),  // Cmd-Z
            event.charactersIgnoringModifiers?.lowercased() == "z"
        {
            model.performLocalUndo()
            return
        }
        switch event.charactersIgnoringModifiers {
        case "1": model.currentTool = .pen
        case "2": model.currentTool = .line
        case "3": model.currentTool = .arrow
        case "4": model.currentTool = .rectangle
        case "5": model.currentTool = .oval
        case "6": model.currentTool = .click
        default:
            super.keyDown(with: event)
        }
    }
}
