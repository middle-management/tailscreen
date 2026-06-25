import AppKit
import Combine
import SwiftUI

/// "Press ⇧⌘/" cheat-sheet overlay listing every keyboard shortcut and
/// pointer gesture the viewer responds to. Modelled on
/// ``ViewerStatsOverlay``: a SwiftUI view bound to a small ObservableObject,
/// wrapped in an `NSHostingView` so AppKit code in `AppState.ensureViewer()`
/// can pin it as a subview of the viewer's content view.
///
/// Toggled by the toolbar's `questionmark.circle` button, the Help menu's
/// "Keyboard Shortcuts" item, or by clicking on the overlay itself to
/// dismiss it. Backdrop covers the entire content view so a click anywhere
/// closes it.
final class ViewerShortcutsModel: ObservableObject, @unchecked Sendable {
    @Published var isVisible: Bool = false
}

struct ViewerShortcutsOverlay: View {
    @ObservedObject var model: ViewerShortcutsModel

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let description: String
    }

    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let items: [Shortcut]
    }

    private static let sections: [Section] = [
        Section(
            title: L("Tools"),
            items: [
                Shortcut(keys: "1  or  ⌘1", description: L("Pen")),
                Shortcut(keys: "2  or  ⌘2", description: L("Line")),
                Shortcut(keys: "3  or  ⌘3", description: L("Arrow")),
                Shortcut(keys: "4  or  ⌘4", description: L("Rectangle")),
                Shortcut(keys: "5  or  ⌘5", description: L("Oval")),
                Shortcut(keys: "6  or  ⌘6", description: L("Pointer / Click"))
            ]),
        Section(
            title: L("Annotation"),
            items: [
                Shortcut(keys: "⌘Z", description: L("Undo last annotation")),
                Shortcut(keys: "⇧⌘⌫", description: L("Clear all annotations")),
                Shortcut(keys: "Esc", description: L("Cancel current drag")),
                Shortcut(keys: "Right-click", description: L("Clear all annotations"))
            ]),
        Section(
            title: L("Audio"),
            items: [
                Shortcut(keys: "⌃⌥M", description: L("Toggle microphone (system-wide)"))
            ]),
        Section(
            title: L("Window"),
            items: [
                Shortcut(keys: "⌘W", description: L("Disconnect viewer")),
                Shortcut(keys: "⌘Q", description: L("Quit Tailscreen")),
                Shortcut(keys: "⇧⌘/", description: L("Show / hide this help"))
            ])
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { model.isVisible = false }

            card
                .frame(maxWidth: 460)
                .padding(40)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Keyboard shortcuts"))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Keyboard Shortcuts"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    model.isVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close keyboard shortcuts"))
            }

            Divider().background(Color.white.opacity(0.2))

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.sections) { section in
                    sectionView(section)
                }
            }

            Divider().background(Color.white.opacity(0.2))

            Text(L("Click anywhere or press ⇧⌘/ to dismiss."))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 4)
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(0.8)
            ForEach(section.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.keys)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 110, alignment: .leading)
                        .foregroundStyle(.white)
                    Text(item.description)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
    }
}

/// Wraps `ViewerShortcutsOverlay` in an `NSHostingView` pinned to the full
/// content view of the viewer window. Visibility is driven off
/// `model.isVisible` via Combine, matching the pattern in
/// `ViewerStatsOverlayHost`.
@MainActor
final class ViewerShortcutsOverlayHost {
    let view: NSHostingView<ViewerShortcutsOverlay>
    let model: ViewerShortcutsModel
    private var visibilityCancellable: AnyCancellable?

    init(model: ViewerShortcutsModel = ViewerShortcutsModel()) {
        self.model = model
        let host = NSHostingView(rootView: ViewerShortcutsOverlay(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.isHidden = !model.isVisible
        self.view = host
        self.visibilityCancellable = model.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak host] isVisible in
                host?.isHidden = !isVisible
            }
    }

    /// Pin the overlay to fill `parent`. Caller adds `view` as a subview
    /// before calling.
    func layout(in parent: NSView) {
        view.frame = parent.bounds
        view.autoresizingMask = [.width, .height]
    }
}
