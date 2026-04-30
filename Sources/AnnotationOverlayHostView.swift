import AppKit
import SwiftUI

/// AppKit shell that hosts ``AnnotationCanvasView``. Lives inside an
/// `NSPanel` (sharer) or a sibling `NSView` (viewer) and forwards the bits
/// SwiftUI doesn't cover for a borderless overlay panel:
///
///   • `acceptsFirstMouse` so a click registers without first activating the
///     app — important on the sharer panel which sits at `.statusBar` level.
///   • `keyDown` for tool shortcuts (1–6), Cmd-Z, Esc — `.onKeyPress` inside
///     a borderless panel doesn't reliably get focus.
///   • `rightMouseDown` for clear-all — SwiftUI gestures have no
///     right-click equivalent.
///
/// The hosted SwiftUI view handles every other piece of input (drag-to-draw)
/// and all rendering.
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
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        // Esc (keyCode 53) — let the host decide what to do.
        if event.keyCode == 53 {
            model.escapePressed()
            return
        }
        // Cmd-Z — undo the most recent shape this canvas created.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
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
