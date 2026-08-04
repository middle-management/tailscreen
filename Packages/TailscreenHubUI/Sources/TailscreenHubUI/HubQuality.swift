import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// The quality knobs, as the hub needs them: the current value, and one
/// setter that persists.
///
/// A reference type for the same reason `HubFilter` is: the menu below is
/// rebuilt on every redraw, and a value copied into each rebuild would hand
/// stale settings back to the host's setter.
public final class HubQuality {
    public var settings: QualitySettings
    /// Applies AND persists. One call per change, with the whole struct — the
    /// knobs interact (a preset is a combination, and setting one knob makes
    /// the preset `.custom`), so a per-field setter would need the host to
    /// reassemble them and get that relationship right twice.
    public let onChange: @MainActor @Sendable (QualitySettings) -> Void
    /// True while a share is running. Only changes the caption: the knobs stay
    /// live because a sharer fiddling with quality mid-call is exactly when
    /// they care, and a disabled control would just look broken.
    public let isSharing: Bool

    public init(
        settings: QualitySettings,
        isSharing: Bool,
        onChange: @escaping @MainActor @Sendable (QualitySettings) -> Void
    ) {
        self.settings = settings
        self.isSharing = isSharing
        self.onChange = onChange
    }
}

/// Human labels for the portable enums.
///
/// Here rather than on the enums themselves: `QualitySettings` lives in
/// `TailscreenProtocol`, which is Foundation-only and deliberately carries no
/// presentation. macOS localizes its own copies through `L(…)`, and putting
/// English in the protocol tier would make that the one place a translator
/// cannot reach.
extension QualitySettings.Preset {
    var hubLabel: String {
        switch self {
        case .low: return L("Save bandwidth")
        case .balanced: return L("Balanced")
        case .high: return L("Best quality")
        // Never offered as a CHOICE — you cannot pick "custom", you arrive at
        // it by moving a knob — but it is a state the menu title must be able
        // to name, or a sharer who changed the frame rate sees a title
        // claiming a preset they are no longer on.
        case .custom: return L("Custom")
        }
    }

    var hubCaption: String? {
        switch self {
        case .low: return L("15 fps, smaller picture — for slow or metered links")
        case .balanced: return L("30 fps — the default")
        case .high: return L("60 fps, sharpest picture — needs a fast link")
        case .custom: return nil
        }
    }
}

extension QualitySettings.CodecPreference {
    var hubLabel: String {
        switch self {
        case .auto: return L("Automatic")
        case .hevc: return L("HEVC only")
        case .h264: return "H.264"
        }
    }
}

/// The share card's quality control: a `Menu` of checked rows.
///
/// A menu of `Toggle`s rather than a `Picker`, which is the same conclusion
/// `HubFilterMenu` reached and for a sturdier reason than taste.
/// swift-cross-ui's `Picker` labels its options by **string-interpolating the
/// value** (`options.map { "\($0)" }`), so a `Preset` would render as `low` /
/// `balanced` / `high` — enum case names, in a user-facing control — and its
/// availability is backend-conditional (`PickerStyle.isSupported`). Menus of
/// checked rows are what both backends are already proven to render here.
///
/// The rows are radio-shaped even though `Toggle` is a checkbox: picking one
/// selects it, and un-picking the active one does nothing, because "no preset"
/// and "no frame rate" are not states this model has. That is why each row's
/// binding ignores `false`.
public struct HubQualityMenu: View {
    let model: HubQuality

    public init(model: HubQuality) {
        self.model = model
    }

    public var body: some View {
        Menu(L("Quality: \(model.settings.preset.hubLabel)")) {
            Text(L("Preset"))
            // `.custom` is excluded: it names "any other combination", so
            // offering it would be a row that cannot do anything.
            ForEach(QualitySettings.Preset.allCases.filter { $0 != .custom }, id: \.self) {
                preset in
                Toggle(preset.hubLabel, isOn: presetBinding(preset))
            }
            Divider()
            Text(L("Frame rate"))
            ForEach(QualitySettings.allowedFPSCaps, id: \.self) { fps in
                Toggle(L("\(fps) fps"), isOn: fpsBinding(fps))
            }
            Divider()
            Text(L("Codec"))
            ForEach(QualitySettings.CodecPreference.allCases, id: \.self) { codec in
                Toggle(codec.hubLabel, isOn: codecBinding(codec))
            }
        }
    }

    /// Radio-shaped bindings: turning a row ON selects it, turning the active
    /// row off is ignored. Each mutates a COPY and hands the whole struct to
    /// the host, so persistence fires exactly once per change — the same shape
    /// as `HubFilterMenu.bind`.
    ///
    /// The closures are non-`Sendable` and formed in this main-actor `body`,
    /// so they inherit its isolation and may call `onChange`.
    private func presetBinding(_ preset: QualitySettings.Preset) -> Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.settings.preset == preset },
            set: { isOn in
                guard isOn else { return }
                model.onChange(
                    QualitySettings.applying(preset: preset, to: model.settings))
            })
    }

    private func fpsBinding(_ fps: Int) -> Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.settings.fpsCap == fps },
            set: { isOn in
                guard isOn else { return }
                model.onChange(model.settings.updating(fpsCap: fps))
            })
    }

    private func codecBinding(_ codec: QualitySettings.CodecPreference) -> Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.settings.codecPreference == codec },
            set: { isOn in
                guard isOn else { return }
                model.onChange(model.settings.updating(codecPreference: codec))
            })
    }
}
