import AppKit
import Foundation
import ScreenCaptureKit

/// Entry point for `Tailscreen --picker-helper`. A short-lived UI
/// subprocess that presents the macOS native `SCContentSharingPicker`,
/// extracts the primitives describing what the user picked
/// (`PickerSelection`), JSON-encodes them onto stdout, and exits.
///
/// Why a separate subprocess: `SCContentSharingPicker` is part of the
/// ScreenCaptureKit family of APIs that interact with `replayd` and the
/// WindowServer. CLAUDE.md is explicit that the main process must
/// stay clear of those couplings — the existing capture pipeline
/// already isolates `SCStream` in `--capture-helper` for the same
/// reason. Presenting the picker from a child process that exits
/// immediately on selection guarantees no live process in the main
/// app retains XPC state from the picker UI session.
///
/// Why primitives + JSON instead of an archived `SCContentFilter`:
/// `SCContentFilter` doesn't conform to `NSCoding`, so there's no
/// way to ship the live class instance across processes. Instead we
/// extract IDs (display, window, bundle) and let the capture-helper
/// reconstruct the filter via `SCShareableContent`.
///
/// Wire format on stdout (parent reads exactly this):
///
///     [length:4 bytes BE][JSON bytes:length bytes]
///
/// `length == 0` means the user cancelled. The exit code distinguishes
/// success (0), cancellation (1), and error (≥2).
enum PickerHelperMain {
    @MainActor
    static func run() -> Never {
        // Save FD 1 and redirect FD 1 → stderr, mirroring the capture
        // helper's discipline. Any stray `print` from inside Apple
        // frameworks then lands on stderr (inherited by the parent's
        // log) instead of corrupting the framed payload on stdout.
        let savedStdout = dup(1)
        if savedStdout >= 0 {
            _ = dup2(2, 1)
        }
        let outFD: Int32 = savedStdout >= 0 ? savedStdout : 1

        // We need a real run loop and `NSApplication.shared` because
        // `SCContentSharingPicker.present()` posts UI events that have
        // to be pumped. Accessory activation policy keeps the helper
        // out of the Dock — it's a transient picker, not a top-level
        // app window.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Hold the observer alive for the process lifetime; the picker
        // singleton retains it weakly.
        let observer = PickerObserver(outFD: outFD)
        Self.observer = observer
        let picker = SCContentSharingPicker.shared
        picker.add(observer)
        // `maximumStreamCount` is documented as a per-picker-session
        // limit, but observed behavior is that the picker singleton
        // refuses to `present()` once the bundle's running stream
        // count reaches this value. The default of 1 makes
        // multi-instance local testing (test-local.sh) impossible —
        // launching a second Tailscreen instance and clicking
        // "Choose what to share…" silently no-ops. 3 is enough for
        // typical multi-instance dev runs; the cross-instance
        // `ShareLock` is the real serialization point that prevents
        // replayd -3805 conflicts.
        picker.maximumStreamCount = 3
        // Activating the singleton is documented as required for
        // `present()` to actually show the picker UI on macOS 15.
        picker.isActive = true
        // No explicit configuration — `present()` without a config
        // defaults to allowing display / window / single-app /
        // multi-app selection, which is exactly what we want.
        picker.present()

        // Run until the observer calls `exit()`. NSApp.run never
        // returns normally; the observer drives termination.
        app.run()
        // Defensive: if NSApp.run somehow returns, treat as a generic
        // error so the parent doesn't hang.
        exit(2)
    }

    nonisolated(unsafe) private static var observer: PickerObserver?
}

/// `SCContentSharingPickerObserver` is a class-protocol; instances must
/// be NSObject subclasses. Owns the parent-bound output FD and routes
/// the picker's three callbacks (didUpdateWith, didCancelFor, error)
/// into framed writes + process exit.
private final class PickerObserver: NSObject, SCContentSharingPickerObserver {
    private let outFD: Int32
    private let lock = NSLock()
    private var didFire = false

    init(outFD: Int32) {
        self.outFD = outFD
        super.init()
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        // The picker can fire didUpdateWith multiple times for
        // refinements; only the first is the user's commit. After we
        // emit the selection and exit, the singleton tears down.
        guard markFiredOnce() else { return }
        let selection = Self.extract(from: filter)
        do {
            let data = try JSONEncoder().encode(selection)
            writeFrame(data)
            // Brief flush window. Without this the parent occasionally
            // sees EOF before the framed payload lands on the pipe.
            usleep(30_000)
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("picker-helper: encode failed: \(error)\n".utf8))
            writeFrame(Data())
            usleep(30_000)
            exit(2)
        }
    }

    /// Walk the filter the picker just produced and pull out the
    /// primitive identifiers we'll ship across processes. The picker
    /// always populates `includedDisplays` / `includedWindows` /
    /// `includedApplications` in the shape implied by `style`.
    static func extract(from filter: SCContentFilter) -> PickerSelection {
        switch filter.style {
        case .display:
            return PickerSelection(
                kind: .display,
                displayID: filter.includedDisplays.first?.displayID,
                windowID: nil,
                bundleIDs: []
            )
        case .window:
            return PickerSelection(
                kind: .window,
                displayID: nil,
                windowID: filter.includedWindows.first?.windowID,
                bundleIDs: []
            )
        case .application:
            // Both single-app and multi-app picker modes resolve to
            // `.application` here — the only difference is the count
            // of `includedApplications`. The capture-helper handles
            // either uniformly.
            let bundleIDs = filter.includedApplications.map { $0.bundleIdentifier }
            return PickerSelection(
                kind: .application,
                displayID: filter.includedDisplays.first?.displayID,
                windowID: nil,
                bundleIDs: bundleIDs
            )
        case .none:
            // Picker handed us a filter with no concrete content;
            // fall back to "main display" so the helper at least has
            // something to work with.
            return PickerSelection(
                kind: .display, displayID: nil, windowID: nil, bundleIDs: [])
        @unknown default:
            return PickerSelection(
                kind: .display, displayID: nil, windowID: nil, bundleIDs: [])
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        guard markFiredOnce() else { return }
        // Zero-length frame signals "user cancelled" to the parent.
        writeFrame(Data())
        usleep(30_000)
        exit(1)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        guard markFiredOnce() else { return }
        FileHandle.standardError.write(
            Data("picker-helper: start failed: \(error)\n".utf8))
        writeFrame(Data())
        usleep(30_000)
        exit(2)
    }

    private func markFiredOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didFire { return false }
        didFire = true
        return true
    }

    private func writeFrame(_ payload: Data) {
        var header = Data(count: 4)
        let len = UInt32(payload.count)
        header[0] = UInt8((len >> 24) & 0xFF)
        header[1] = UInt8((len >> 16) & 0xFF)
        header[2] = UInt8((len >> 8) & 0xFF)
        header[3] = UInt8(len & 0xFF)
        writeAll(header)
        if !payload.isEmpty {
            writeAll(payload)
        }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(outFD, ptr, remaining)
                if n <= 0 { return }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }
}
