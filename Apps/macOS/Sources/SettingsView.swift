import AppKit
import Carbon.HIToolbox
import CoreAudio
import SwiftUI

/// Native System-Settings-style preferences surface, presented in its own
/// window via ⌘, (`AppCommands`' "Settings…" item and the in-popover
/// "Settings…" row both route to `AppState.presentSettings()`).
///
/// The menubar module surfaces the same quick toggles inline — Control Center
/// style — but a Mac user reflexively reaches for ⌘, , so the preferences also
/// get a proper home here with room to grow. A grouped `Form` gives the
/// inset-rounded look of System Settings without hand-rolled chrome. The
/// window is resizable above a 440×480 floor (`presentSettings` sets the
/// AppKit side); the Form scrolls regardless, so nothing here needs a fixed
/// height.
struct SettingsView: View {
    @ObservedObject var appState: AppState

    private static let projectURL = URL(
        string: "https://github.com/middle-management/tailscreen")!

    var body: some View {
        Form {
            generalSection
            accountsSection
            keyboardShortcutsSection
            viewersSection
            remoteControlSection
            rememberedViewersSection
            cloakedAppsSection
            qualitySections
            audioSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 480)
        .onAppear { appState.refreshAudioDevices() }
    }

    // MARK: - General

    /// Launch at login via `SMAppService` (state + registration live on
    /// AppState). A dev build running as a bare executable has no bundle to
    /// register, so the toggle disables itself and says why instead of
    /// throwing on every flip.
    private var generalSection: some View {
        Section(L("General")) {
            Toggle(
                L("Launch at login"),
                isOn: Binding(
                    get: { appState.launchAtLoginEnabled },
                    set: { appState.setLaunchAtLogin($0) }
                )
            )
            .disabled(!appState.launchAtLoginAvailable)
            if !appState.launchAtLoginAvailable {
                Text(
                    L(
                        "Launch at login needs the packaged Tailscreen app — a development build running outside an app bundle can't register itself."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if appState.launchAtLoginRequiresApproval {
                Text(
                    L(
                        "Waiting for approval — allow Tailscreen under System Settings → General → Login Items."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Accounts

    /// Every saved profile with a visible per-row Remove button. This is
    /// the discoverable twin of the header's account NSMenu, where removal
    /// hides behind ⌥-clicking a non-active row — a trap nobody falls out
    /// of by accident. Rows re-render through AppState's forwarded
    /// `profileStore.objectWillChange` (see `AppState.init`).
    private var accountsSection: some View {
        Section(L("Accounts")) {
            ForEach(appState.profileStore.profiles) { profile in
                accountRow(profile)
            }
            Button(L("Add Account…")) {
                Task { await appState.addAccountAndSignIn() }
            }
            Text(
                L(
                    "Removing an account deletes its sign-in state from this Mac. To remove the account you're signed in to, switch to another account first."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func accountRow(_ profile: TailscreenProfile) -> some View {
        let isActive = profile.id == appState.profileStore.activeProfileID
        let rowTitle = profile.hasSignedIn ? profile.loginName : L("Not signed in yet")
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !profile.tailnetName.isEmpty {
                    Text(profile.tailnetName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if isActive {
                // A text badge, not a colored dot — status that reads as
                // color alone is banned (see the a11y rules).
                Text(L("Active"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                // `confirmRemoveProfile` runs the confirmation alert and
                // refuses the active/last profile — same path the header
                // menu's hidden alternate item uses.
                Button(L("Remove")) {
                    appState.confirmRemoveProfile(profile)
                }
                .controlSize(.small)
                .accessibilityLabel(L("Remove \(rowTitle)"))
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    /// The two global hotkeys, each with a recorder and a reset. The
    /// registration warnings surface what `RegisterEventHotKey` only
    /// reports as a return code: a chord another app already owns is
    /// silently refused, and an advertised-but-dead shortcut is worse than
    /// none (see `GlobalHotkey.isRegistered`).
    private var keyboardShortcutsSection: some View {
        Section(L("Keyboard Shortcuts")) {
            shortcutRow(
                title: L("Toggle Microphone"),
                chord: appState.micHotkeyChord,
                defaultChord: .defaultMicToggle,
                registered: appState.micHotkeyRegistered
            ) { appState.micHotkeyChord = $0 }
            shortcutRow(
                title: L("Stop Remote Control"),
                chord: appState.revokeHotkeyChord,
                defaultChord: .defaultRevokeControl,
                registered: appState.revokeHotkeyRegistered
            ) { appState.revokeHotkeyChord = $0 }
            if appState.micHotkeyChord == appState.revokeHotkeyChord {
                Label(
                    L(
                        "Both actions use the same shortcut, so only one of them will fire. Record a different combination for one of them."
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(
                L(
                    "These shortcuts work system-wide. Click one, then press a new combination that includes at least one of ⌃, ⌥, or ⌘ — Esc cancels recording."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// One shortcuts row: command name, the recorder (whose idle title is
    /// the current chord), and a reset affordance. `registered == false`
    /// appends the inline "in use elsewhere" warning — icon + text, never
    /// color alone.
    @ViewBuilder
    private func shortcutRow(
        title: String,
        chord: HotkeyChord,
        defaultChord: HotkeyChord,
        registered: Bool,
        onChange: @escaping (HotkeyChord) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            ShortcutRecorderButton(
                chordDisplay: chord.displayString,
                accessibilityLabel: L("Record a new shortcut for \(title)"),
                onRecord: onChange)
            Button(L("Reset")) {
                onChange(defaultChord)
            }
            .controlSize(.small)
            .disabled(chord == defaultChord)
            .help(L("Reset to Default"))
            .accessibilityLabel(L("Reset \(title) to default"))
        }
        if !registered {
            Label(
                L(
                    "This shortcut is already in use by another app, so it won't work here. Record a different one."
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Viewers

    private var viewersSection: some View {
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
    }

    // MARK: - Remote control

    private var remoteControlSection: some View {
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
    }

    // MARK: - Remembered viewers

    private var rememberedViewersSection: some View {
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
    }

    // MARK: - Cloaked Apps

    private var cloakedAppsSection: some View {
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
    }

    // MARK: - Quality + Color

    @ViewBuilder
    private var qualitySections: some View {
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
            encoderQualityRow
            Text(
                L(
                    "Frame rate, codec, and encoder quality changes apply the next time you start sharing."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section(L("Color")) {
            Toggle(L("10-bit color"), isOn: $appState.enable10BitCapture)
            Toggle(isOn: $appState.enableHDRCapture) {
                // Acronym, same unlocalized class as the codec names.
                Text(verbatim: "HDR")
            }
            Text(
                L(
                    "Applies the next time you start sharing. HDR needs a display with EDR headroom, and if a viewer can't decode 10-bit video the share falls back to 8-bit for everyone."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Encoder-quality slider (`kVTCompressionPropertyKey_Quality` via
    /// `QualitySettings.encoderQuality`). The named presets differentiate
    /// on this knob, so the slider only unlocks on Custom — otherwise it
    /// just *shows* the preset's effective value. The value label makes the
    /// 0.30–1.00 position readable at a glance; the slider itself carries
    /// the accessible value.
    private var encoderQualityRow: some View {
        HStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { appState.qualitySettings.encoderQuality },
                    set: { newValue in
                        // No `updating(encoderQuality:)` twin exists on the
                        // type; set the knob directly and re-normalize,
                        // which is exactly what those helpers do.
                        var updated = appState.qualitySettings
                        updated.encoderQuality = newValue
                        appState.qualitySettings = updated.normalized()
                    }
                ),
                in: QualitySettings.minEncoderQuality...QualitySettings.maxEncoderQuality
            ) {
                Text(L("Encoder quality"))
            }
            .disabled(appState.qualitySettings.preset != .custom)
            Text(String(format: "%.2f", appState.qualitySettings.encoderQuality))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
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
    }

    // MARK: - About

    private var aboutSection: some View {
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
    /// differs — matches `AboutPanel`'s logic (AppCommands.swift).
    private static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        if let build = info["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}

// MARK: - Shortcut recorder

/// AppKit-backed shortcut recorder. SwiftUI has no key-capture control:
/// recording must swallow the *next* keyDown chord regardless of focus,
/// which is a local `NSEvent` monitor's job. Click to arm, press a chord to
/// store it, Esc cancels; a chord is refused (with a beep) unless it
/// carries at least one of ⌃⌥⌘ and names a key the display vocabulary can
/// spell (`HotkeyChord.isValidUserChord`) — the same no-bare-keys rule
/// `GlobalHotkeyMapping` applies on the other platforms, because a bare key
/// registered system-wide is stolen from every other app on the machine.
private struct ShortcutRecorderButton: NSViewRepresentable {
    /// "⌃⌥M"-style rendering of the stored chord, or nil when the stored
    /// key is unmappable — the idle button then reads "Record Shortcut".
    let chordDisplay: String?
    let accessibilityLabel: String
    let onRecord: (HotkeyChord) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.toggleRecording(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        context.coordinator.button = button
        updateCoordinator(context.coordinator, button: button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        updateCoordinator(context.coordinator, button: button)
    }

    private func updateCoordinator(_ coordinator: Coordinator, button: NSButton) {
        button.setAccessibilityLabel(accessibilityLabel)
        coordinator.onRecord = onRecord
        coordinator.idleTitle = chordDisplay ?? L("Record Shortcut")
        coordinator.refreshTitle()
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.cancelRecording()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var button: NSButton?
        var onRecord: ((HotkeyChord) -> Void)?
        /// Title shown while not recording — the chord, or "Record Shortcut".
        var idleTitle = ""
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        /// The one coordinator currently recording, app-wide. Arming a
        /// second recorder cancels the first so two monitors can't both
        /// swallow one keystroke. Weak: a recorder being torn down must not
        /// be kept alive by it.
        private static weak var active: Coordinator?

        var isRecording: Bool { monitor != nil }

        @objc func toggleRecording(_ sender: Any?) {
            if isRecording {
                cancelRecording()
            } else {
                beginRecording()
            }
        }

        func refreshTitle() {
            guard !isRecording else { return }
            button?.title = idleTitle
        }

        private func beginRecording() {
            Coordinator.active?.cancelRecording()
            Coordinator.active = self
            button?.title = L("Type shortcut…")
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors fire on the main thread; `assumeIsolated`
                // bridges to our @MainActor state. Only Sendable scalars
                // cross the bridge (NSEvent isn't one), and the isolated
                // side answers just "was it handled" — everything a live
                // recorder sees is swallowed so no keystroke leaks through
                // to the menu equivalents underneath it.
                let keyCode = event.keyCode
                let carbonModifiers = HotkeyChord.carbonModifiers(from: event.modifierFlags)
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    self.handleKeyDown(keyCode: keyCode, carbonModifiers: carbonModifiers)
                    return true
                }
                return handled ? nil : event
            }
            // The Settings window is kept for the process lifetime, so
            // closing it never dismantles this view — without this, an
            // armed monitor would outlive the window and swallow keystrokes
            // app-wide. Losing key status (close, ⌘Tab, click elsewhere)
            // cancels the recording instead.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: button?.window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelRecording()
                }
            }
        }

        /// Act on a keystroke seen while armed: Esc cancels, a valid chord
        /// is stored, anything else beeps. The caller swallows the event in
        /// every case.
        private func handleKeyDown(keyCode: UInt16, carbonModifiers: UInt32) {
            if keyCode == UInt16(kVK_Escape) {
                cancelRecording()
                return
            }
            let chord = HotkeyChord(keyCode: UInt32(keyCode), modifiers: carbonModifiers)
            guard chord.isValidUserChord else {
                NSSound.beep()
                return
            }
            cancelRecording()
            onRecord?(chord)
        }

        func cancelRecording() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            if Coordinator.active === self {
                Coordinator.active = nil
            }
            refreshTitle()
        }
    }
}
