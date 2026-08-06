import AppKit
import Combine
import SwiftUI

/// "Press ⇧⌘/" cheat-sheet listing every keyboard shortcut and pointer
/// gesture the app responds to, with the remote-control shortcuts split by
/// role. Modelled on ``ViewerStatsOverlay``: a SwiftUI view bound to a small
/// ObservableObject, wrapped in an `NSHostingView` so AppKit code in
/// `AppState.ensureViewer()` can pin it as a subview of the viewer's content
/// view. The same content also renders standalone (``ViewerShortcutsPanelHost``)
/// so ⌘? answers while *sharing*, when no viewer window exists.
///
/// Toggled by the toolbar's `questionmark.circle` button, the Help menu's
/// "Keyboard Shortcuts" item, Esc, or by clicking on the overlay itself to
/// dismiss it. Backdrop covers the entire content view so a click anywhere
/// closes it.
final class ViewerShortcutsModel: ObservableObject, @unchecked Sendable {
    @Published var isVisible: Bool = false
    /// Display chords for the two remappable global hotkeys, refreshed by
    /// `AppState.syncShortcutChordDisplays()` so a Settings remap shows up
    /// in the sheet. nil = the stored chord can't be spelled — the affected
    /// rows are dropped rather than misprinted.
    @Published var micChord: String? = "⌃⌥M"
    @Published var controlChord: String? = "⌃⌥."
}

struct ViewerShortcutsOverlay: View {
    @ObservedObject var model: ViewerShortcutsModel
    /// The in-window overlay draws a dimmed tap-to-dismiss backdrop over the
    /// video; the standalone sharing-time panel is just the card and skips it.
    var showsBackdrop: Bool = true
    /// Footer line telling the user how to leave — the two hosts dismiss
    /// differently (tap-anywhere vs. Esc / close), so the host supplies it.
    var dismissHint: String = L("Click anywhere or press Esc to dismiss.")

    /// The full-screen chord, mentioned only here (its menu item carries
    /// the real key equivalent). Not remappable, unlike the mic/control
    /// chords, which come off the model so Settings remaps show up live.
    private static let fullScreenChord = "⌃⌘F"

    /// Fixed key-column width scales with the monospaced text it holds.
    @ScaledMetric(relativeTo: .callout) private var keyColumnWidth: CGFloat = 110

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

    /// Computed (not static) because the mic/control rows print the
    /// *current* chords off the model — a Settings remap re-renders the
    /// sheet. A chord the display vocabulary can't spell drops its rows
    /// (and an emptied section) rather than misprinting the default.
    private var sections: [Section] {
        var out: [Section] = [
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
                title: L("Zoom"),
                items: [
                    Shortcut(keys: L("Pinch"), description: L("Zoom in or out at the cursor")),
                    Shortcut(keys: L("⌥ Scroll"), description: L("Zoom in or out at the cursor")),
                    Shortcut(keys: L("Scroll"), description: L("Pan while zoomed in")),
                    Shortcut(keys: L("Double-tap"), description: L("Toggle 2× zoom")),
                    Shortcut(keys: "⌥⌘+ / ⌥⌘-", description: L("Zoom in / out")),
                    Shortcut(keys: "⌘0", description: L("Reset zoom and window size"))
                ]),
        ]
        if let micChord = model.micChord {
            out.append(
                Section(
                    title: L("Audio"),
                    items: [
                        Shortcut(keys: micChord, description: L("Toggle microphone (system-wide)"))
                    ]))
        }
        // Both roles keep the same exit chord (⌃⌥. unless remapped) — the
        // viewer releases the control it holds, the sharer revokes the
        // control it granted. Split into role-labelled sections: the old
        // single "Remote Control" heading listed only the sharer's revoke,
        // in the sheet the *viewer* is most likely to be reading.
        if let controlChord = model.controlChord {
            out.append(
                Section(
                    title: L("Remote control — while viewing"),
                    items: [
                        Shortcut(keys: controlChord, description: L("Release remote control"))
                    ]))
            out.append(
                Section(
                    title: L("Remote control — while sharing"),
                    items: [
                        Shortcut(
                            keys: controlChord,
                            description: L("Revoke remote control (system-wide)"))
                    ]))
        }
        out.append(
            Section(
                title: L("Window"),
                items: [
                    Shortcut(keys: "⌘W", description: L("Disconnect viewer")),
                    Shortcut(keys: Self.fullScreenChord, description: L("Enter or exit full screen")),
                    Shortcut(keys: "⌘Q", description: L("Quit Tailscreen")),
                    Shortcut(keys: "⇧⌘/", description: L("Show / hide this help"))
                ]))
        return out
    }

    var body: some View {
        ZStack {
            if showsBackdrop {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { model.isVisible = false }
            }

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
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    model.isVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close keyboard shortcuts"))
            }

            Divider().background(Color.white.opacity(0.2))

            VStack(alignment: .leading, spacing: 14) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }

            Divider().background(Color.white.opacity(0.2))

            Text(dismissHint)
                .font(.caption)
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
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(0.8)
            ForEach(section.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.keys)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .frame(width: keyColumnWidth, alignment: .leading)
                        .foregroundStyle(.white)
                    Text(item.description)
                        .font(.callout)
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

/// Standalone ⌘? panel used while SHARING, when there is no viewer window
/// to overlay: the same SwiftUI card in a borderless floating panel,
/// centered on the screen the mouse is on. Owned by AppState for the
/// process lifetime, mirroring the settings window.
@MainActor
final class ViewerShortcutsPanelHost {
    let model = ViewerShortcutsModel()
    private var panel: ShortcutsPanel?
    private var visibilityCancellable: AnyCancellable?

    init() {
        visibilityCancellable = model.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                self?.setPanelVisible(isVisible)
            }
    }

    var isVisible: Bool { model.isVisible }

    func toggle() { model.isVisible.toggle() }

    private func setPanelVisible(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel()
        // Center on the screen the user is working on — while sharing
        // that's wherever the mouse is, not necessarily the main display.
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(
                NSPoint(
                    x: visibleFrame.midX - panel.frame.width / 2,
                    y: visibleFrame.midY - panel.frame.height / 2
                ))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensurePanel() -> ShortcutsPanel {
        if let panel { return panel }
        // No backdrop: the card carries its own material + shadow, so the
        // panel itself is a transparent shell around it.
        let hosting = NSHostingView(
            rootView: ViewerShortcutsOverlay(
                model: model,
                showsBackdrop: false,
                dismissHint: L("Press Esc to dismiss.")))
        let size = hosting.fittingSize
        let panel = ShortcutsPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card's own SwiftUI shadow fits inside its 40 pt padding.
        panel.hasShadow = false
        panel.level = .floating
        // Reachable over a full-screen app being shared, and it must not
        // vanish when the user clicks back into the app they're sharing
        // (NSPanel hides on deactivate by default).
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.onCancel = { [weak self] in
            self?.model.isVisible = false
        }
        self.panel = panel
        return panel
    }
}

/// Borderless panel that can become key (so Esc reaches it) and turns Esc
/// into a dismiss instead of a beep.
@MainActor
private final class ShortcutsPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
