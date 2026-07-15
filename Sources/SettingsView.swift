import AppKit
import CoreAudio
import SwiftUI

/// Native System-Settings-style preferences surface, presented in its own
/// window via ⌘, (`AppMenu`'s "Settings…" item and the in-popover
/// "Settings…" row both route to `AppState.presentSettings()`).
///
/// The menubar module surfaces the same quick toggles inline — Control Center
/// style — but a Mac user reflexively reaches for ⌘, , so the preferences also
/// get a proper home here with room to grow. A grouped `Form` gives the
/// inset-rounded look of System Settings without hand-rolled chrome.
struct SettingsView: View {
    @ObservedObject var appState: AppState

    private static let projectURL = URL(
        string: "https://github.com/middle-management/tailscreen")!

    var body: some View {
        Form {
            Section(L("Viewers")) {
                Toggle(
                    L("Require approval for new viewers"),
                    isOn: $appState.requireViewerApproval)
                Text(
                    L("New viewers wait on a Connecting prompt until you Accept or Deny them.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(L("Quality")) {
                Picker(
                    L("Preset"),
                    selection: Binding(
                        get: { appState.qualitySettings.preset },
                        set: { newPreset in
                            appState.qualitySettings = QualitySettings.applying(
                                preset: newPreset, to: appState.qualitySettings)
                        }
                    )
                ) {
                    Text(L("Low")).tag(QualitySettings.Preset.low)
                    Text(L("Balanced")).tag(QualitySettings.Preset.balanced)
                    Text(L("High")).tag(QualitySettings.Preset.high)
                    Text(L("Custom")).tag(QualitySettings.Preset.custom)
                }
                .pickerStyle(.segmented)
                Picker(
                    L("Frame rate"),
                    selection: Binding(
                        get: { appState.qualitySettings.fpsCap },
                        set: { appState.qualitySettings = appState.qualitySettings.updating(fpsCap: $0) }
                    )
                ) {
                    ForEach(QualitySettings.allowedFPSCaps, id: \.self) { fps in
                        Text(L("\(fps) fps")).tag(fps)
                    }
                }
                Picker(
                    L("Codec"),
                    selection: Binding(
                        get: { appState.qualitySettings.codecPreference },
                        set: { newCodec in
                            appState.qualitySettings =
                                appState.qualitySettings.updating(codecPreference: newCodec)
                        }
                    )
                ) {
                    // Codec names are brand nouns — deliberately unlocalized
                    // (see CLAUDE.md's Localization section).
                    Text(L("Automatic")).tag(QualitySettings.CodecPreference.auto)
                    Text(verbatim: "HEVC").tag(QualitySettings.CodecPreference.hevc)
                    Text(verbatim: "H.264").tag(QualitySettings.CodecPreference.h264)
                }
                Toggle(
                    L("Limit bandwidth"),
                    isOn: Binding(
                        get: { appState.qualitySettings.maxBitrateBps != nil },
                        set: { enabled in
                            let ceiling = enabled ? QualitySettings.initialCeilingBps : nil
                            appState.qualitySettings =
                                appState.qualitySettings.updating(maxBitrateBps: ceiling)
                        }
                    ))
                if let ceilingBps = appState.qualitySettings.maxBitrateBps {
                    Stepper(
                        value: Binding(
                            get: { max(1, ceilingBps / 1_000_000) },
                            set: { mbps in
                                appState.qualitySettings =
                                    appState.qualitySettings.updating(maxBitrateBps: mbps * 1_000_000)
                            }
                        ),
                        in: 1...50
                    ) {
                        Text(L("\(max(1, ceilingBps / 1_000_000)) Mbps"))
                    }
                }
                Text(L("Frame rate and codec changes apply the next time you start sharing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Audio")) {
                Picker(
                    L("Microphone"),
                    selection: Binding(
                        get: { appState.selectedInputDeviceID },
                        set: { appState.selectInputDevice($0) }
                    )
                ) {
                    Text(L("System default")).tag(AudioDeviceID?.none)
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
                Picker(
                    L("Speaker"),
                    selection: Binding(
                        get: { appState.selectedOutputDeviceID },
                        set: { appState.selectOutputDevice($0) }
                    )
                ) {
                    Text(L("System default")).tag(AudioDeviceID?.none)
                    ForEach(appState.availableOutputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
            }

            Section(L("About")) {
                LabeledContent(L("Version"), value: Self.versionString)
                Link(L("Project on GitHub"), destination: Self.projectURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
        .onAppear { appState.refreshAudioDevices() }
    }

    /// Marketing version, with the build number appended only when it
    /// differs — matches the About panel's logic in `AppMenu`.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        if let build = info["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
