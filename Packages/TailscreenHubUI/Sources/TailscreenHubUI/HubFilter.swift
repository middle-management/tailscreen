import SwiftCrossUI
import TailscreenProtocol

/// Everything the header needs to draw the peer-list filter, in one value.
///
/// Bundled rather than spread across four more `ViewerHeader` parameters, for
/// the same reason `HubAction` exists: an optional struct says "this host has a
/// filter" in one place, and a header that already takes nine arguments does not
/// need four more that are only ever passed together.
///
/// Deliberately NOT a `Binding<PeerListFilter>`. Both hosts keep the filter on a
/// main-actor model that also has to persist every change, and a binding would
/// let the chrome write the field while the persistence sat somewhere else.
/// A value in and a closure out keeps "who owns this" answerable.
public struct HubFilter: Sendable {
    /// The filter as it stands — drives the toggles' checkmarks and whether the
    /// menu reads as active.
    public var filter: PeerListFilter
    /// Every ACL tag seen across the host's RAW (unfiltered) peer list. Empty ⇒
    /// the tag section is omitted entirely; a tailnet with no tagged nodes
    /// should not grow an empty submenu.
    public var tags: [String]
    /// Whether this host actually knows which peers are sharing.
    ///
    /// The sharing axis hides every peer whose state is `.unknown`, so on a host
    /// with no metadata sweep the toggle would empty the list and look broken.
    /// Withholding the row is the same conditional-capability move the viewer
    /// makes with Request Control: do not offer what cannot be served.
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
/// **A menu of `Toggle`s, not a popover**, on purpose. swift-cross-ui is a
/// SwiftUI subset: `Menu` takes a `String` label and a `MenuItem` list, and the
/// only things that list can hold are `Button`, `Toggle`, `Text`, `Divider` and
/// submenus (`SwiftCrossUI.MenuItem`). There is no `.popover` modifier and no
/// custom-view menu label, so the macOS hub's funnel-glyph button opening a
/// panel of arbitrary content has no equivalent here. What DOES exist is
/// checked menu rows on both backends we ship — `GtkBackend` maps `.toggle` to a
/// stateful `GSimpleAction`, `WinUIBackend` to a `ToggleMenuFlyoutItem` — which
/// is the same interaction the macOS `PeerFilterMenu` offers, and the header
/// already proves `Menu` renders here (the account menu). Proven primitive over
/// pretty one.
///
/// The label carries the active state as text (`Filter ●`) because a menu label
/// is a String: the mac app's filled-vs-outline funnel glyph is an SF Symbol,
/// and SF Symbols are exactly what this package cannot have.
struct HubFilterMenu: View {
    let model: HubFilter

    var body: some View {
        // A dot rather than a count: the count of *active axes* is not what
        // anyone wants to know, and the count of hidden rows is already printed
        // under the list where the rows are missing from.
        Menu(model.filter.isActive ? "Filter ●" : "Filter") {
            Toggle("Hide offline devices", isOn: bind(\.hideOffline))
            if model.offersSharingAxis {
                Toggle("Only screens being shared", isOn: bind(\.onlySharing))
            }
            if !model.tags.isEmpty {
                Divider()
                // A `Text` row resolves to a menu item with no action — inert on
                // both backends — which is the closest this subset gets to
                // SwiftUI's `Section` header. There is no `Section` in a
                // swift-cross-ui menu.
                Text("Filter by tag")
                ForEach(model.tags, id: \.self) { tag in
                    Toggle(PeerListFilter.displayName(forTag: tag), isOn: bindTag(tag))
                }
                if !model.filter.selectedTags.isEmpty {
                    // Only meaningful while a tag filter is active — with no
                    // tags selected the tag axis is off and every peer passes
                    // it, so an "Untagged" toggle would do nothing.
                    Toggle("Untagged", isOn: bind(\.includeUntagged))
                }
            }
            if model.filter.isActive {
                Divider()
                Button("Clear Filters") { model.onChange(.default) }
            }
        }
    }

    /// A binding onto one `Bool` axis that mutates a COPY and hands the whole
    /// struct back, so the host's setter (and its persistence) fires exactly
    /// once per toggle — the same shape as the macOS `PeerFilterMenu`'s helper.
    ///
    /// The closures are non-`Sendable` and formed in this main-actor `body`, so
    /// they inherit its isolation and may call `onChange`.
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
