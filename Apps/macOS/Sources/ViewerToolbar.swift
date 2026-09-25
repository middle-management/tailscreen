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
    private static let colorMenu = NSToolbarItem.Identifier("tool.color")
    private static let microphone = NSToolbarItem.Identifier("action.microphone")
    private static let undo = NSToolbarItem.Identifier("action.undo")
    private static let clearAll = NSToolbarItem.Identifier("action.clearAll")
    private static let stats = NSToolbarItem.Identifier("action.stats")
    private static let shortcuts = NSToolbarItem.Identifier("action.shortcuts")
    private static let remoteControl = NSToolbarItem.Identifier("action.remoteControl")
    private static let openLink = NSToolbarItem.Identifier("action.openLink")

    private static let toolGroup = NSToolbarItem.Identifier("group.tools")

    let toolbar: NSToolbar

    private weak var appState: AppState?
    private weak var micToolbarItem: NSToolbarItem?
    private var micCancellable: AnyCancellable?
    private weak var toolGroupItem: NSToolbarItemGroup?
    private weak var undoToolbarItem: NSToolbarItem?
    private weak var clearAllToolbarItem: NSToolbarItem?
    /// Drives the drawing tools' + undo/clear items' enabled state so the
    /// viewer doesn't offer annotation UI a non-supporting sharer would ignore.
    private var annotationsEnabled = true
    private var toolCancellable: AnyCancellable?
    private weak var canvasModel: AnnotationCanvasModel?
    private weak var statsToolbarItem: NSToolbarItem?
    private var statsCancellable: AnyCancellable?
    private weak var statsModel: ViewerStatsModel?
    /// Inserted/removed dynamically (see `updateControlItem`), genuinely
    /// hidden against a sharer that can't inject input.
    private weak var controlToolbarItem: NSToolbarItem?
    private var controlCancellable: AnyCancellable?
    private var controlState: ViewerControlState = .none
    private var openLinkCancellable: AnyCancellable?
    private weak var colorMenuItem: NSMenuToolbarItem?
    private var colorCancellable: AnyCancellable?
    private var currentColor: Annotation.RGBA = Annotation.defaultColor

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
            controlCancellable = appState.$viewerControlState
                .combineLatest(appState.$sharerSupportsRemoteControl)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state, supported in
                    self?.updateControlItem(state: state, supported: supported)
                }
            openLinkCancellable = appState.$sharerSupportsOpenLink
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] supported in
                    self?.updateOpenLinkItem(supported: supported)
                }
        }
    }

    private func updateMicIcon(isOn: Bool) {
        let symbol = isOn ? "mic.fill" : "mic.slash"
        let a11y = isOn ? L("Mute microphone") : L("Unmute microphone")
        // Hidden when the stored chord can't be spelled, rather than misprinted.
        let chord = appState?.micShortcutDisplay
        let tip =
            isOn
            ? (chord.map { L("Mute microphone (\($0))") } ?? a11y)
            : (chord.map { L("Unmute microphone (\($0))") } ?? a11y)
        micToolbarItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: a11y)
        micToolbarItem?.toolTip = tip
    }

    /// Present only while the sharer advertised support, or a request/grant
    /// is still live so the exit affordance can't vanish mid-teardown.
    private func updateControlItem(state: ViewerControlState, supported: Bool) {
        controlState = state
        let wanted = supported || state != .none
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.remoteControl }
        if wanted, index == nil {
            let statsIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.stats }
            toolbar.insertItem(
                withItemIdentifier: Self.remoteControl,
                at: statsIndex ?? toolbar.items.count)
        } else if !wanted, let index {
            toolbar.removeItem(at: index)
        }
        if let item = controlToolbarItem {
            applyControlVisuals(to: item)
        }
    }

    /// Present only while the sharer advertised `.openLink`, beside the
    /// remote-control item.
    private func updateOpenLinkItem(supported: Bool) {
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.openLink }
        if supported, index == nil {
            let statsIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.stats }
            toolbar.insertItem(
                withItemIdentifier: Self.openLink,
                at: statsIndex ?? toolbar.items.count)
        } else if !supported, let index {
            toolbar.removeItem(at: index)
        }
    }

    /// Label + VoiceOver description carry the state too, so the tint is
    /// never the only signal.
    private func applyControlVisuals(to item: NSToolbarItem) {
        switch controlState {
        case .none:
            item.label = L("Request Control")
            let tip = L("Request control of the shared Mac")
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: tip)
        case .requested:
            item.label = L("Requesting…")
            item.toolTip = L("Waiting for the sharer to grant control — click to cancel")
            item.image = NSImage(
                systemSymbolName: "hourglass",
                accessibilityDescription: L("Cancel the pending control request"))
        case .controlling:
            item.label = L("Stop Controlling")
            item.toolTip = L("You are controlling the shared Mac — click to stop")
            let base = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            let tinted =
                base?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.systemOrange])) ?? base
            tinted?.accessibilityDescription = L("Stop controlling the shared Mac")
            item.image = tinted
        }
    }

    /// Keeps the toolbar's selected segment in sync with keyboard shortcuts
    /// (`1`-`6`, `⌘1`-`⌘6`) that change `currentTool` directly.
    func bind(canvasModel: AnnotationCanvasModel) {
        self.canvasModel = canvasModel
        toolCancellable = canvasModel.$currentTool
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tool in
                self?.updateToolSelection(tool)
            }
        updateToolSelection(canvasModel.currentTool)
        colorCancellable = canvasModel.$currentColor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] color in
                self?.updateColorSelection(color)
            }
        updateColorSelection(canvasModel.currentColor)
    }

    private func updateColorSelection(_ color: Annotation.RGBA) {
        currentColor = color
        if let item = colorMenuItem {
            applyColorVisuals(to: item)
        }
    }

    /// Folds the color into the tooltip/VoiceOver description — the swatch
    /// alone would be color-only status.
    private func applyColorVisuals(to item: NSMenuToolbarItem) {
        let name = Self.paletteColorName(for: currentColor)
        let label = L("Drawing color: \(name)")
        let image = Self.swatchImage(for: currentColor)
        image.accessibilityDescription = label
        item.image = image
        item.toolTip = label
    }

    private func updateToolSelection(_ tool: AnnotationTool) {
        guard let idx = Self.toolOrder.firstIndex(of: tool) else { return }
        toolGroupItem?.selectedIndex = idx
    }

    /// The stats toolbar button doubles as an always-visible
    /// degraded-connection badge, since the stats overlay itself may be hidden.
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
        let tip = degraded ? L("Connection degraded — click for stats") : L("Toggle stream stats overlay")
        statsToolbarItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        statsToolbarItem?.toolTip = tip
    }

    func setAnnotationsEnabled(_ enabled: Bool) {
        annotationsEnabled = enabled
        toolGroupItem?.isEnabled = enabled
        undoToolbarItem?.isEnabled = enabled
        clearAllToolbarItem?.isEnabled = enabled
        colorMenuItem?.isEnabled = enabled
        toolbar.validateVisibleItems()
    }

    /// Called by `AppState.micHotkeyChord.didSet`, since the `$isMicOn` sink
    /// only fires on mic toggles, not on a Settings remap.
    func refreshMicChordDisplay() {
        guard let appState else { return }
        updateMicIcon(isOn: appState.isMicOn)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `remoteControl`/`openLink` inserted dynamically, see
        // `updateControlItem`/`updateOpenLinkItem`.
        [
            Self.toolGroup, Self.colorMenu, .flexibleSpace, Self.stats, Self.shortcuts,
            Self.microphone, Self.undo, Self.clearAll
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolGroup, Self.colorMenu, Self.remoteControl, Self.openLink, Self.stats,
            Self.shortcuts, Self.microphone, Self.undo, Self.clearAll, .flexibleSpace, .space
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
            let item = makeButton(
                id: itemIdentifier,
                label: L("Undo"),
                symbol: "arrow.uturn.backward",
                action: #selector(ViewerCommands.undoLastAnnotation(_:)),
                accessibilityLabel: L("Undo last annotation"),
                toolTip: L("Undo last annotation (⌘Z)")
            )
            item.isEnabled = annotationsEnabled
            undoToolbarItem = item
            return item
        case Self.clearAll:
            let item = makeButton(
                id: itemIdentifier,
                label: L("Clear"),
                symbol: "trash",
                action: #selector(ViewerCommands.clearAllAnnotations(_:)),
                accessibilityLabel: L("Clear all annotations"),
                toolTip: L("Clear all annotations (⇧⌘⌫ or right-click)")
            )
            item.isEnabled = annotationsEnabled
            clearAllToolbarItem = item
            return item
        case Self.microphone:
            let item = makeButton(
                id: itemIdentifier,
                label: L("Mic"),
                symbol: appState?.isMicOn == true ? "mic.fill" : "mic.slash",
                action: #selector(ViewerCommands.toggleMicrophone(_:))
            )
            micToolbarItem = item
            updateMicIcon(isOn: appState?.isMicOn == true)
            return item
        case Self.colorMenu:
            return makeColorMenu()
        case Self.remoteControl:
            let item = makeButton(
                id: itemIdentifier,
                label: L("Request Control"),
                symbol: "cursorarrow.rays",
                action: #selector(ViewerCommands.toggleRemoteControlRequest(_:))
            )
            controlToolbarItem = item
            applyControlVisuals(to: item)
            return item
        case Self.openLink:
            return makeButton(
                id: itemIdentifier,
                label: L("Open Link on Sharer…"),
                symbol: "link",
                action: #selector(ViewerCommands.openLinkOnSharer(_:)),
                toolTip: L("The sharer sees the whole link and chooses whether to open it.")
            )
        case Self.stats:
            let item = makeButton(
                id: itemIdentifier,
                label: L("Stats"),
                symbol: "chart.bar.xaxis",
                action: #selector(ViewerCommands.toggleStatsOverlay(_:)),
                accessibilityLabel: L("Toggle stream stats overlay")
            )
            statsToolbarItem = item
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
        let labels = [L("Pen"), L("Line"), L("Arrow"), L("Rect"), L("Oval"), L("Click")]
        let symbols = [
            "pencil.tip",
            "line.diagonal",
            "arrow.up.right",
            "rectangle",
            "circle",
            "scope"
        ]
        // Spelled out — "Rect" reads as "r-e-c-t" otherwise.
        let a11y = [
            L("Pen annotation tool"),
            L("Line annotation tool"),
            L("Arrow annotation tool"),
            L("Rectangle annotation tool"),
            L("Oval annotation tool"),
            L("Pointer click tool")
        ]
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

        // NSToolbarItemGroup doesn't pick up images via its initializer.
        for (i, sym) in symbols.enumerated() where i < group.subitems.count {
            let sub = group.subitems[i]
            sub.image = NSImage(systemSymbolName: sym, accessibilityDescription: a11y[i])
            sub.label = labels[i]
            sub.toolTip = tips[i]
        }
        toolGroupItem = group
        group.isEnabled = annotationsEnabled
        let initialTool = canvasModel?.currentTool ?? .pen
        group.selectedIndex = Self.toolOrder.firstIndex(of: initialTool) ?? 0
        return group
    }

    private static let paletteColorNames: [String] = [
        L("Red"), L("Blue"), L("Green"), L("Orange"),
        L("Purple"), L("Teal"), L("Pink"), L("Yellow")
    ]

    /// Anything off-palette degrades to a generic name rather than lying.
    private static func paletteColorName(for color: Annotation.RGBA) -> String {
        guard let idx = Annotation.RGBA.palette.firstIndex(of: color),
            paletteColorNames.indices.contains(idx)
        else { return L("Custom") }
        return paletteColorNames[idx]
    }

    private static func swatchImage(for color: Annotation.RGBA, diameter: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(
                srgbRed: CGFloat(color.r), green: CGFloat(color.g),
                blue: CGFloat(color.b), alpha: CGFloat(color.a)
            ).setFill()
            path.fill()
            // Faint outline so light swatches (yellow) stay visible.
            NSColor.black.withAlphaComponent(0.2).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    private func makeColorMenu() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: Self.colorMenu)
        item.label = L("Color")
        item.paletteLabel = L("Color")
        item.showsIndicator = true
        let menu = NSMenu(title: L("Drawing Color"))
        for (idx, color) in Annotation.RGBA.palette.enumerated()
        where Self.paletteColorNames.indices.contains(idx) {
            let row = NSMenuItem(
                title: Self.paletteColorNames[idx],
                action: #selector(ViewerCommands.selectAnnotationColor(_:)),
                keyEquivalent: "")
            row.target = ViewerCommands.shared
            row.tag = idx  // indexes Annotation.RGBA.palette
            row.image = Self.swatchImage(for: color)
            menu.addItem(row)
        }
        item.menu = menu
        item.isEnabled = annotationsEnabled
        colorMenuItem = item
        applyColorVisuals(to: item)
        return item
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
        // accessibilityLabel stays free of glyphs like "⌘" that screen
        // readers spell out awkwardly.
        item.toolTip = toolTip ?? accessibilityLabel ?? label
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
