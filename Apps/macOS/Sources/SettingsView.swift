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

            Section(L("Remote control")) {
                Toggle(
                    L("Allow control requests"),
                    isOn: $appState.allowControlRequests)
                Text(
                    L(
                        "Viewers can ask to control your Mac while you share; you still approve each request. Turn off to decline requests automatically and silence their notifications."
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
            Section(L("Cloaked Apps")) {
                Toggle(
                    L("Hide cloaked apps while sharing"),
                    isOn: Binding(
                        get: { appState.appCloak.isEnabled },
                        set: { appState.appCloak.isEnabled = $0 }
                    ))
                if appState.appCloak.entries.isEmpty {
                    Text(
                        L(
                            "Cloaked apps are hidden from viewers whenever you share a whole display — no need to clean up your screen before sharing."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.appCloak.entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button(L("Remove")) {
                                appState.appCloak.remove(bundleID: entry.bundleID)
                            }
                            .controlSize(.small)
                            .accessibilityLabel(L("Remove \(entry.displayName)"))
                        }
                    }
                }
                Menu(L("Add App…")) {
                    let candidates = cloakableRunningApps()
                    if candidates.isEmpty {
                        Text(L("No other running apps"))
                    } else {
                        ForEach(candidates, id: \.bundleID) { app in
                            Button(app.name) {
                                appState.appCloak.add(
                                    bundleID: app.bundleID, displayName: app.name)
                            }
                        }
                    }
                }
                Text(
                    L(
                        "Applies when you share a whole display. Sharing a single window or app already limits what viewers see, and an app you explicitly pick to share is never cloaked."
                    )
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
                    // (see CLAUDE.md's Localization section). HEVC here is
                    // the *explicit* choice: unlike Automatic (HEVC with
                    // H.264 fallback) it never downgrades, so H.264-only
                    // viewers can't watch — the caption below says so.
                    Text(L("Automatic")).tag(QualitySettings.CodecPreference.auto)
                    Text(verbatim: "HEVC").tag(QualitySettings.CodecPreference.hevc)
                    Text(verbatim: "H.264").tag(QualitySettings.CodecPreference.h264)
                }
                if appState.qualitySettings.codecPreference == .hevc {
                    Text(
                        L(
                            "HEVC never falls back to H.264 — viewers that can only decode H.264 won't be able to watch. Choose Automatic to fall back when needed."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                // The build/environment line the GTK and Windows apps show in
                // their window footer. macOS has a Settings scene, so it lives
                // here rather than under the peer list — diagnostics belong
                // behind ⌘, on this platform, not in the hub chrome.
                //
                // Selectable on purpose: the entire point of the line is
                // pasting it into a bug report, and a diagnostic you can't
                // copy is half a diagnostic.
                LabeledContent(L("Build")) {
                    Text(environmentLine)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link(L("Project on GitHub"), destination: Self.projectURL)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 600)
        .onAppear { appState.refreshAudioDevices() }
    }

    /// Running apps the user could add to the Cloaked Apps list: ordinary
    /// (Dock-visible) apps, minus Tailscreen itself and anything already
    /// cloaked. `NSWorkspace` is legal here — it's AppKit, not the
    /// ScreenCaptureKit family CLAUDE.md bans from the main process — and
    /// enumerating *running* apps mirrors Tuple's "Add…" flow without
    /// needing a full /Applications scan.
    @MainActor
    private func cloakableRunningApps() -> [(name: String, bundleID: String)] {
        let cloaked = Set(appState.appCloak.entries.map(\.bundleID))
        let selfID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let bundleID = app.bundleIdentifier,
                    bundleID != selfID,
                    !cloaked.contains(bundleID),
                    seen.insert(bundleID).inserted
                else { return nil }
                return (name: app.localizedName ?? bundleID, bundleID: bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Build stamp + running architecture + the quality knobs actually in
    /// force — the macOS counterpart of `AppUIState.environmentLine` in the
    /// Windows and GTK apps. The stamp leads because every other number on
    /// screen depends on it being right.
    ///
    /// Reads `appState.qualitySettings`, not `QualitySettings.default` as the
    /// footer-only hosts do: this app has the Quality pickers directly above,
    /// so the line must name what this Mac will actually encode with —
    /// including a Custom preset — or it would contradict the control that
    /// set it.
    private var environmentLine: String {
        let quality = appState.qualitySettings
        let build = BuildInfo.summary
        let arch = BuildInfo.architecture
        let codec = quality.codecPreference.rawValue
        return L("\(build) · \(arch) · fps cap \(quality.fpsCap) · codec \(codec)")
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
