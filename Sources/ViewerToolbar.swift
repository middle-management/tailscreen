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
    private static let shortcuts = NSToolbarItem.Identifier("action.shortcuts")

    private static let toolGroup = NSToolbarItem.Identifier("group.tools")

    let toolbar: NSToolbar

    private weak var appState: AppState?
    private weak var micToolbarItem: NSToolbarItem?
    private var micCancellable: AnyCancellable?
    private weak var toolGroupItem: NSToolbarItemGroup?
    private var toolCancellable: AnyCancellable?
    private weak var canvasModel: AnnotationCanvasModel?
    private weak var statsToolbarItem: NSToolbarItem?
    private var statsCancellable: AnyCancellable?
    private weak var statsModel: ViewerStatsModel?

    /// Tool order — must match `ViewerCommands.toolbarSelectedTool` and
    /// the `makeToolGroup` subitem order.
    private static let toolOrder: [AnnotationTool] = [.pen, .line, .arrow, .rectangle, .oval, .click]

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

    /// Subscribe to the canvas model so keyboard shortcuts (`1`–`6`,
    /// `⌘1`–`⌘6`) that change `currentTool` directly keep the toolbar's
    /// selected segment in sync. Without this the toolbar only updates
    /// when the user clicks it.
    func bind(canvasModel: AnnotationCanvasModel) {
        self.canvasModel = canvasModel
        toolCancellable = canvasModel.$currentTool
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tool in
                self?.updateToolSelection(tool)
            }
        updateToolSelection(canvasModel.currentTool)
    }

    private func updateToolSelection(_ tool: AnnotationTool) {
        guard let idx = Self.toolOrder.firstIndex(of: tool) else { return }
        toolGroupItem?.selectedIndex = idx
    }

    /// Subscribe to the viewer stats model so the stats toolbar button
    /// doubles as an always-visible degraded-connection badge — the stats
    /// overlay itself may be hidden when the decode ladder trips, but the
    /// toolbar is always on screen.
    func bind(statsModel: ViewerStatsModel) {
        self.statsModel = statsModel
        statsCancellable = statsModel.$stats
            .map(\.isDegraded)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDegraded in
                self?.updateStatsIcon(degraded: isDegraded)
            }
        updateStatsIcon(degraded: statsModel.stats.isDegraded)
    }

    private func updateStatsIcon(degraded: Bool) {
        let symbol = degraded ? "exclamationmark.triangle" : "chart.bar.xaxis"
        // The symbol's accessibilityDescription is what VoiceOver reads for
        // the item (see `makeButton`) — passing nil here would clobber the
        // description the initial build set and leave VoiceOver users with
        // no degraded signal at all.
        let tip = degraded ? L("Connection degraded — click for stats") : L("Toggle stream stats overlay")
        statsToolbarItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        statsToolbarItem?.toolTip = tip
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolGroup, .flexibleSpace, Self.stats, Self.shortcuts,
            Self.microphone, Self.undo, Self.clearAll
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolGroup, Self.stats, Self.shortcuts, Self.microphone,
            Self.undo, Self.clearAll, .flexibleSpace, .space
        ]
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
                label: L("Undo"),
                symbol: "arrow.uturn.backward",
                action: #selector(ViewerCommands.undoLastAnnotation(_:)),
                accessibilityLabel: L("Undo last annotation"),
                toolTip: L("Undo last annotation (⌘Z)")
            )
        case Self.clearAll:
            return makeButton(
                id: itemIdentifier,
                label: L("Clear"),
                symbol: "trash",
                action: #selector(ViewerCommands.clearAllAnnotations(_:)),
                accessibilityLabel: L("Clear all annotations"),
                toolTip: L("Clear all annotations (⇧⌘⌫ or right-click)")
            )
        case Self.microphone:
            let item = makeButton(
                id: itemIdentifier,
                label: L("Mic"),
                symbol: appState?.isMicOn == true ? "mic.fill" : "mic.slash",
                action: #selector(ViewerCommands.toggleMicrophone(_:)),
                accessibilityLabel: appState?.isMicOn == true
                    ? L("Mute microphone")
                    : L("Unmute microphone"),
                toolTip: L("Toggle microphone (⌃⌥M)")
            )
            micToolbarItem = item
            return item
        case Self.stats:
            let item = makeButton(
                id: itemIdentifier,
                label: L("Stats"),
                symbol: "chart.bar.xaxis",
                action: #selector(ViewerCommands.toggleStatsOverlay(_:)),
                accessibilityLabel: L("Toggle stream stats overlay")
            )
            statsToolbarItem = item
            // Reflect a degraded state that predates AppKit asking the
            // delegate for this item (mirrors the tool-group's late bind).
            if let model = statsModel, model.stats.isDegraded {
                updateStatsIcon(degraded: true)
            }
            return item
        case Self.shortcuts:
            return makeButton(
                id: itemIdentifier,
                label: L("Shortcuts"),
                symbol: "questionmark.circle",
                action: #selector(ViewerCommands.toggleShortcutsOverlay(_:)),
                accessibilityLabel: L("Show keyboard shortcuts"),
                toolTip: L("Keyboard shortcuts (⇧⌘/)")
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
        let labels = [L("Pen"), L("Line"), L("Arrow"), L("Rect"), L("Oval"), L("Click")]
        let symbols = [
            "pencil.tip",
            "line.diagonal",
            "arrow.up.right",
            "rectangle",
            "circle",
            "scope"
        ]
        // Spelled-out VoiceOver descriptions — "Rect" reads as
        // "r-e-c-t" otherwise, and "Click" alone doesn't convey that
        // it's a pointer/laser tool.
        let a11y = [
            L("Pen annotation tool"),
            L("Line annotation tool"),
            L("Arrow annotation tool"),
            L("Rectangle annotation tool"),
            L("Oval annotation tool"),
            L("Pointer click tool")
        ]
        // Tooltip text shown on hover. Mirrors a11y but appends the
        // keyboard shortcut so the toolbar doubles as discovery for the
        // 1–6 / ⌘1–⌘6 bindings.
        let tips = [
            L("Pen (1 or ⌘1)"),
            L("Line (2 or ⌘2)"),
            L("Arrow (3 or ⌘3)"),
            L("Rectangle (4 or ⌘4)"),
            L("Oval (5 or ⌘5)"),
            L("Pointer / Click (6 or ⌘6)")
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
            sub.toolTip = tips[i]
        }
        toolGroupItem = group
        // Reflect the canvas model's current tool if `bind(canvasModel:)`
        // was called before AppKit asked the delegate for items.
        let initialTool = canvasModel?.currentTool ?? .pen
        group.selectedIndex = Self.toolOrder.firstIndex(of: initialTool) ?? 0
        return group
    }

    private func makeButton(
        id: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        accessibilityLabel: String? = nil,
        toolTip: String? = nil
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        // Tooltip includes the key equivalent so users can discover the
        // shortcut by hovering; accessibilityLabel is the VoiceOver-only
        // description and stays free of glyphs like "⌘" that screen
        // readers spell out awkwardly.
        item.toolTip = toolTip ?? accessibilityLabel ?? label
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
