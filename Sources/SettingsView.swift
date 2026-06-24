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
            Section("Viewers") {
                Toggle(
                    "Require approval for new viewers",
                    isOn: $appState.requireViewerApproval)
                Text(
                    "New viewers wait on a Connecting prompt until you Accept or Deny them."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker(
                    "Microphone",
                    selection: Binding(
                        get: { appState.selectedInputDeviceID },
                        set: { appState.selectInputDevice($0) }
                    )
                ) {
                    Text("System default").tag(AudioDeviceID?.none)
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
                Picker(
                    "Speaker",
                    selection: Binding(
                        get: { appState.selectedOutputDeviceID },
                        set: { appState.selectOutputDevice($0) }
                    )
                ) {
                    Text("System default").tag(AudioDeviceID?.none)
                    ForEach(appState.availableOutputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                Link("Project on GitHub", destination: Self.projectURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 380)
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
