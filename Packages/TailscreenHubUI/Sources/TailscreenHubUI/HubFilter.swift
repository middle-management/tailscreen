import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// Everything the header needs to draw the peer-list filter, in one value —
/// bundled like `HubAction` rather than four more `ViewerHeader` parameters.
///
/// Deliberately not a `Binding<PeerListFilter>`: both hosts persist filter
/// changes from a main-actor model, and a binding would let the chrome write
/// the field while persistence sat elsewhere.
public struct HubFilter: Sendable {
    /// The filter as it stands — drives the toggles' checkmarks and whether the
    /// menu reads as active.
    public var filter: PeerListFilter
    /// Every ACL tag seen across the host's raw (unfiltered) peer list. Empty
    /// omits the tag section entirely.
    public var tags: [String]
    /// Whether this host actually knows which peers are sharing. The sharing
    /// axis hides every `.unknown`-state peer, so on a host with no metadata
    /// sweep the toggle would empty the list and look broken.
    public var offersSharingAxis: Bool
    public var onChange: @MainActor @Sendable (PeerListFilter) -> Void

    public init(
        filter: PeerListFilter,
        tags: [String] = [],
        offersSharingAxis: Bool = true,
        onChange: @escaping @MainActor @Sendable (PeerListFilter) -> Void
    ) {
        self.filter = filter
        self.tags = tags
        self.offersSharingAxis = offersSharingAxis
        self.onChange = onChange
    }
}

/// The header's filter affordance: a menu of toggles over `PeerListFilter`'s
/// three axes — hide-offline, only-sharing, and any-of-selected-tags with its
/// explicit untagged bucket.
///
/// A menu of `Toggle`s, not a popover: swift-cross-ui's `Menu` only holds
/// `Button`/`Toggle`/`Text`/`Divider`/submenus, with no `.popover` and no
/// custom-view label — so the macOS funnel-button-opens-a-panel design has no
/// equivalent here. Checked menu rows (`GtkBackend`'s `GSimpleAction`,
/// `WinUIBackend`'s `ToggleMenuFlyoutItem`) are the closest available.
///
/// The label carries active state as text (`Filter ●`) since a menu label is
/// a plain `String` — no SF Symbols here.
struct HubFilterMenu: View {
    let model: HubFilter

    var body: some View {
        // A dot, not a count of active axes — hidden-row counts print under the list.
        Menu(model.filter.isActive ? L("Filter ●") : L("Filter")) {
            Toggle(L("Hide offline devices"), isOn: bind(\.hideOffline))
            if model.offersSharingAxis {
                Toggle(L("Only screens being shared"), isOn: bind(\.onlySharing))
            }
            if !model.tags.isEmpty {
                Divider()
                // An inert `Text` row stands in for `Section`, which swift-cross-ui's menu lacks.
                Text(L("Filter by Tag"))
                ForEach(model.tags, id: \.self) { tag in
                    Toggle(PeerListFilter.displayName(forTag: tag), isOn: bindTag(tag))
                }
                if !model.filter.selectedTags.isEmpty {
                    // Only meaningful once a tag is selected — otherwise the axis is off.
                    Toggle(L("Untagged"), isOn: bind(\.includeUntagged))
                }
            }
            if model.filter.isActive {
                Divider()
                Button(L("Clear Filters")) { model.onChange(.default) }
            }
        }
    }

    /// A binding onto one `Bool` axis that mutates a copy and hands the whole
    /// struct back, so `onChange` (and its persistence) fires once per toggle.
    private func bind(_ keyPath: WritableKeyPath<PeerListFilter, Bool>) -> Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.filter[keyPath: keyPath] },
            set: { isOn in
                var updated = model.filter
                updated[keyPath: keyPath] = isOn
                model.onChange(updated)
            }
        )
    }

    private func bindTag(_ tag: String) -> Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.filter.selectedTags.contains(tag) },
            set: { isOn in
                var updated = model.filter
                if isOn {
                    updated.selectedTags.insert(tag)
                } else {
                    updated.selectedTags.remove(tag)
                }
                model.onChange(updated)
            }
        )
    }
}
