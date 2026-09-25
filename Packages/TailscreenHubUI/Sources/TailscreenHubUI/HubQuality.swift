import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// The quality knobs, as the hub needs them: the current value, and one
/// setter that persists. A reference type like `HubFilter`, so a rebuild
/// doesn't hand the setter stale settings.
public final class HubQuality {
    public var settings: QualitySettings
    /// Applies and persists. One call, with the whole struct — the knobs
    /// interact (setting one makes the preset `.custom`), so a per-field
    /// setter would need the host to get that relationship right twice.
    public let onChange: @MainActor @Sendable (QualitySettings) -> Void
    /// True while a share is running. Only changes the caption — the knobs
    /// stay live since mid-call is exactly when a sharer wants to change them.
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

/// Human labels for the portable enums. Kept off the enums themselves since
/// `QualitySettings` lives in the Foundation-only `TailscreenProtocol`, which
/// carries no presentation.
extension QualitySettings.Preset {
    var hubLabel: String {
        switch self {
        case .low: return L("Save bandwidth")
        case .balanced: return L("Balanced")
        case .high: return L("Best quality")
        // Never a pickable choice — reached by moving a knob — but the menu
        // title must still be able to name it.
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

/// The share card's quality control: a `Menu` of checked rows, not a
/// `Picker` — swift-cross-ui's `Picker` renders options by string-
/// interpolating the value (`low`/`balanced`/`high` enum case names).
///
/// Rows are radio-shaped despite `Toggle` being a checkbox: un-picking the
/// active row does nothing, since "no preset"/"no frame rate" aren't states
/// this model has — each binding ignores `false`.
public struct HubQualityMenu: View {
    let model: HubQuality

    public init(model: HubQuality) {
        self.model = model
    }

    public var body: some View {
        Menu(L("Quality: \(model.settings.preset.hubLabel)")) {
            Text(L("Preset"))
            // `.custom` excluded — a row that could never do anything.
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

    /// Radio-shaped: turning a row on selects it, turning the active row off
    /// is ignored. Mutates a copy and hands the whole struct to the host, like
    /// `HubFilterMenu.bind`.
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
