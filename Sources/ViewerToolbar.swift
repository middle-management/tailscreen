import AppKit
import Combine

/// Builds an NSToolbar for the viewer window so users can pick a drawing
/// tool / undo / clear without going to the menu bar. All actions route
/// through `ViewerCommands.shared`, which holds the active overlay weakly
/// and applies the same selectors the app menu uses — toolbar and menu
/// stay in sync because they invoke the same code path.
@MainActor
final class ViewerToolbar: NSObject, NSToolbarDelegate {
    private static let identifier = NSToolbar.Identifier("dev.tailscreen.viewer-toolbar")

    private static let pen = NSToolbarItem.Identifier("tool.pen")
    private static let line = NSToolbarItem.Identifier("tool.line")
    private static let arrow = NSToolbarItem.Identifier("tool.arrow")
    private static let rectangle = NSToolbarItem.Identifier("tool.rectangle")
    private static let oval = NSToolbarItem.Identifier("tool.oval")
    private static let microphone = NSToolbarItem.Identifier("action.microphone")
    private static let undo = NSToolbarItem.Identifier("action.undo")
    private static let clearAll = NSToolbarItem.Identifier("action.clearAll")
    private static let stats = NSToolbarItem.Identifier("action.stats")

    private static let toolGroup = NSToolbarItem.Identifier("group.tools")

    let toolbar: NSToolbar

    private weak var appState: AppState?
    private weak var micToolbarItem: NSToolbarItem?
    private var micCancellable: AnyCancellable?

    init(appState: AppState? = nil) {
        let tb = NSToolbar(identifier: Self.identifier)
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.autosavesConfiguration = false
        self.toolbar = tb
        self.appState = appState
        super.init()
        tb.delegate = self

        if let appState = appState {
            micCancellable = appState.$isMicOn
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isOn in
                    self?.updateMicIcon(isOn: isOn)
                }
        }
    }

    private func updateMicIcon(isOn: Bool) {
        let symbol = isOn ? "mic.fill" : "mic.slash"
        micToolbarItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolGroup, .flexibleSpace, Self.stats, Self.microphone, Self.undo, Self.clearAll]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolGroup, Self.stats, Self.microphone, Self.undo, Self.clearAll, .flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.toolGroup:
            return makeToolGroup()
        case Self.undo:
            return makeButton(
                id: itemIdentifier,
                label: "Undo",
                symbol: "arrow.uturn.backward",
                action: #selector(ViewerCommands.undoLastAnnotation(_:)),
                accessibilityLabel: "Undo last annotation"
            )
        case Self.clearAll:
            return makeButton(
                id: itemIdentifier,
                label: "Clear",
                symbol: "trash",
                action: #selector(ViewerCommands.clearAllAnnotations(_:)),
                accessibilityLabel: "Clear all annotations"
            )
        case Self.microphone:
            let item = makeButton(
                id: itemIdentifier,
                label: "Mic",
                symbol: appState?.isMicOn == true ? "mic.fill" : "mic.slash",
                action: #selector(ViewerCommands.toggleMicrophone(_:)),
                accessibilityLabel: appState?.isMicOn == true
                    ? "Mute microphone"
                    : "Unmute microphone"
            )
            micToolbarItem = item
            return item
        case Self.stats:
            return makeButton(
                id: itemIdentifier,
                label: "Stats",
                symbol: "chart.bar.xaxis",
                action: #selector(ViewerCommands.toggleStatsOverlay(_:)),
                accessibilityLabel: "Toggle stream stats overlay"
            )
        default:
            return nil
        }
    }

    // MARK: - Item builders

    private func makeToolGroup() -> NSToolbarItem {
        // NSToolbarItemGroup with selectionMode = .selectOne gives radio
        // behaviour — clicking one tool deselects the others. The selected
        // index drives ViewerCommands.setTool().
        let labels = ["Pen", "Line", "Arrow", "Rect", "Oval", "Click"]
        let symbols = [
            "pencil.tip",
            "line.diagonal",
            "arrow.up.right",
            "rectangle",
            "circle",
            "scope",
        ]
        // Spelled-out VoiceOver descriptions — "Rect" reads as
        // "r-e-c-t" otherwise, and "Click" alone doesn't convey that
        // it's a pointer/laser tool.
        let a11y = [
            "Pen annotation tool",
            "Line annotation tool",
            "Arrow annotation tool",
            "Rectangle annotation tool",
            "Oval annotation tool",
            "Pointer click tool",
        ]

        let group = NSToolbarItemGroup(
            itemIdentifier: Self.toolGroup,
            titles: labels,
            selectionMode: .selectOne,
            labels: labels,
            target: ViewerCommands.shared,
            action: #selector(ViewerCommands.toolbarSelectedTool(_:))
        )

        // Replace each subitem's image with the SF Symbol so the toolbar
        // looks idiomatic. NSToolbarItemGroup does NOT pick up images via
        // its initializer.
        for (i, sym) in symbols.enumerated() where i < group.subitems.count {
            let sub = group.subitems[i]
            sub.image = NSImage(systemSymbolName: sym, accessibilityDescription: a11y[i])
            sub.label = labels[i]
            sub.toolTip = a11y[i]
        }
        group.selectedIndex = 0
        return group
    }

    private func makeButton(
        id: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        accessibilityLabel: String? = nil
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = accessibilityLabel ?? label
        // The SF Symbol's accessibilityDescription drives VoiceOver
        // unless the toolbar item carries an explicit override — supply
        // a richer label for the actionable items where the short tool
        // label ("Mic", "Stats") would read ambiguously.
        item.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel ?? label
        )
        item.target = ViewerCommands.shared
        item.action = action
        item.isBordered = true
        return item
    }
}
