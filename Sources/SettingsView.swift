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
                    L(
                        "New viewers wait on a Connecting prompt until you Accept or Deny them. On by default — turn off to let anyone on your tailnet connect instantly."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(L("Remembered viewers")) {
                if appState.viewerAccessPolicies.entries.isEmpty {
                    Text(L("Viewers you Always Allow or Deny & Block will appear here."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.viewerAccessPolicies.entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(entry.policy == .allow ? L("Allowed") : L("Blocked"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(entry.policy == .allow ? Color.green : Color.red)
                            Button(L("Remove")) {
                                appState.viewerAccessPolicies.remove(stableID: entry.stableID)
                            }
                            .controlSize(.small)
                            .accessibilityLabel(L("Remove \(entry.displayName)"))
                        }
                    }
                }
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
                    // (see CLAUDE.md's Localization section). No HEVC row:
                    // Automatic already prefers HEVC (with H.264 fallback),
                    // so a dedicated HEVC choice would behave identically.
                    Text(L("Automatic")).tag(QualitySettings.CodecPreference.auto)
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
                    // `normalized()` keeps the ceiling clamped to the
                    // bounds and rounded to a whole Mbps, so the integer
                    // division here is always exact — no display fudging.
                    Stepper(
                        value: Binding(
                            get: { ceilingBps / 1_000_000 },
                            set: { mbps in
                                appState.qualitySettings =
                                    appState.qualitySettings.updating(maxBitrateBps: mbps * 1_000_000)
                            }
                        ),
                        in: (QualitySettings.minCeilingBps / 1_000_000)...(QualitySettings.maxCeilingBps / 1_000_000)
                    ) {
                        Text(L("\(ceilingBps / 1_000_000) Mbps"))
                    }
                }
                Text(L("Frame rate and codec changes apply the next time you start sharing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Audio")) {
                Toggle(
                    L("Share system audio when sharing starts"),
                    isOn: $appState.shareSystemAudioByDefault)
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
        .frame(width: 440, height: 600)
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
