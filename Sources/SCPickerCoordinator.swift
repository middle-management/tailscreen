import Foundation
import ScreenCaptureKit

/// Bridges Apple's `SCContentSharingPicker` (macOS 14+) to a single
/// completion-style callback for the rest of Tailscreen.
///
/// Apple's design: install one persistent observer on the singleton
/// `SCContentSharingPicker.shared`, then activate the picker via
/// `present(...)` whenever you want the user to choose what to share.
/// The observer's `contentSharingPicker(_:didUpdateWith:for:)` fires
/// with the chosen `SCContentFilter`. We collapse that into a one-shot
/// `pickFilter()` async function that returns the filter (or nil if
/// the user cancels).
///
/// Why this matters: when you build an `SCContentFilter` manually (the
/// pre-picker path), `replayd` intermittently refuses to deliver
/// frames — `startCapture` acks but no samples arrive. The picker
/// route gets the user-consent gate properly opened in `replayd`'s
/// state machine, dramatically reducing those failures.
@MainActor
final class SCPickerCoordinator: NSObject {
    static let shared = SCPickerCoordinator()

    /// The pending caller awaiting a selection. Picker callbacks
    /// arrive on the main thread; we route them here.
    private var pendingContinuation: CheckedContinuation<SCContentFilter?, Never>?

    /// Whether we've installed the observer. Apple's picker is a
    /// process-wide singleton; we want exactly one observer for our
    /// lifecycle.
    private var observerInstalled = false

    /// Activate the picker and await the user's choice. Returns the
    /// chosen filter, or `nil` if the user cancelled.
    ///
    /// `contentStyle` is the initial tab the picker opens on
    /// (`.display`, `.window`, or `.application`). The user can
    /// switch within the picker.
    func pickFilter(contentStyle: SCContentSharingPickerMode = .singleDisplay) async -> SCContentFilter? {
        installObserverIfNeeded()
        // Cancel any in-flight pick — the new one supersedes it.
        if let stale = pendingContinuation {
            pendingContinuation = nil
            stale.resume(returning: nil)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<SCContentFilter?, Never>) in
            pendingContinuation = cont
            let picker = SCContentSharingPicker.shared
            var config = SCContentSharingPickerConfiguration()
            config.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
            picker.defaultConfiguration = config
            picker.isActive = true
            picker.present()
        }
    }

    private func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        SCContentSharingPicker.shared.add(self)
        observerInstalled = true
    }

    /// Call after our SCStream has fully stopped. Sets the picker
    /// inactive so macOS clears any "ready to share" UI it may be
    /// showing on top of the recording badge. Safe to call multiple
    /// times; cheap.
    func reset() {
        SCContentSharingPicker.shared.isActive = false
    }
}

/// Wraps `SCContentFilter` for safe transit across an isolation
/// boundary. The underlying type isn't `Sendable` but it's a
/// reference-typed value object Apple hands us once and we hand on
/// once — there's no concurrent mutation. Re-exported (non-private)
/// so callers can pass filters into non-`@MainActor` server APIs
/// without Swift 6 yelling about data races.
struct SendableFilter: @unchecked Sendable {
    let value: SCContentFilter
    init(_ value: SCContentFilter) { self.value = value }
}

private typealias FilterBox = SendableFilter

extension SCPickerCoordinator: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let boxed = FilterBox(filter)
        Task { @MainActor in
            guard let cont = self.pendingContinuation else { return }
            self.pendingContinuation = nil
            SCContentSharingPicker.shared.isActive = false
            cont.resume(returning: boxed.value)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            guard let cont = self.pendingContinuation else { return }
            self.pendingContinuation = nil
            SCContentSharingPicker.shared.isActive = false
            cont.resume(returning: nil)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            print("SCContentSharingPicker: start failed with \(error)")
            guard let cont = self.pendingContinuation else { return }
            self.pendingContinuation = nil
            cont.resume(returning: nil)
        }
    }
}
