import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Entry point for `Tailscreen --picker-helper`. Presents the native
/// `SCContentSharingPicker`, extracts the primitives describing what the user
/// picked (`PickerSelection`), JSON-encodes onto stdout, and exits — a
/// separate subprocess since `SCContentSharingPicker` couples to
/// `replayd`/WindowServer, which the main process must stay clear of.
///
/// Primitives + JSON, not an archived `SCContentFilter`: it doesn't conform
/// to `NSCoding`, so IDs (display/window/bundle) cross instead and the
/// capture-helper reconstructs the filter via `SCShareableContent`.
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
        // Redirect FD 1 -> stderr, mirroring the capture helper's discipline,
        // so a stray print doesn't corrupt the framed payload.
        let savedStdout = dup(1)
        if savedStdout >= 0 {
            _ = dup2(2, 1)
        }
        let outFD: Int32 = savedStdout >= 0 ? savedStdout : 1

        // Real run loop needed to pump `SCContentSharingPicker.present()`'s UI
        // events. Accessory policy keeps the helper out of the Dock.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Test affordance: short-circuits the interactive picker with a
        // synthetic main-display selection. `CGMainDisplayID()` doesn't
        // register with replayd, so the downstream SCStream still comes up cleanly.
        if ProcessInfo.processInfo.environment["TAILSCREEN_AUTOSHARE_DISPLAY"] == "1" {
            let selection = PickerSelection(
                kind: .display,
                displayID: UInt32(CGMainDisplayID()),
                windowID: nil,
                bundleIDs: []
            )
            do {
                let payload = try JSONEncoder().encode(selection)
                writeFramedPayload(payload, to: outFD)
                usleep(30_000)  // flush window; mirrors PickerObserver.didUpdateWith
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("picker-helper: auto-share encode failed: \(error)\n".utf8))
                writeFramedPayload(Data(), to: outFD)
                usleep(30_000)
                exit(2)
            }
        }

        // Held for the process lifetime; the picker singleton retains it weakly.
        let observer = PickerObserver(outFD: outFD)
        Self.observer = observer
        let picker = SCContentSharingPicker.shared
        picker.add(observer)
        // Default of 1 makes multi-instance local testing impossible (a
        // second instance's picker silently no-ops); the cross-instance
        // `ShareLock` is the real serialization point against replayd -3805.
        picker.maximumStreamCount = 3
        picker.isActive = true  // required for present() to show UI on macOS 15
        picker.present()

        // NSApp.run never returns normally; the observer drives termination.
        app.run()
        exit(2)  // defensive, in case NSApp.run somehow returns
    }

    nonisolated(unsafe) private static var observer: PickerObserver?
}

/// Routes the picker's three callbacks into framed writes + process exit.
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
        // Fires multiple times for refinements; only the first is the commit.
        guard markFiredOnce() else { return }
        let selection = Self.extract(from: filter)
        do {
            let data = try JSONEncoder().encode(selection)
            writeFrame(data)
            usleep(30_000)  // flush window; else the parent sometimes sees EOF first
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("picker-helper: encode failed: \(error)\n".utf8))
            writeFrame(Data())
            usleep(30_000)
            exit(2)
        }
    }

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
            // Single-app and multi-app modes both resolve here; only
            // includedApplications' count differs.
            let bundleIDs = filter.includedApplications.map { $0.bundleIdentifier }
            return PickerSelection(
                kind: .application,
                displayID: filter.includedDisplays.first?.displayID,
                windowID: nil,
                bundleIDs: bundleIDs
            )
        case .none:
            // No concrete content; fall back to "main display".
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
        // Zero-length frame signals "cancelled".
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
        writeFramedPayload(payload, to: outFD)
    }
}

/// `[length:4 BE][JSON bytes:N]`, `length == 0` = cancelled. Shared between
/// `PickerObserver.writeFrame` and the `TAILSCREEN_AUTOSHARE_DISPLAY=1` test
/// short-circuit so both paths emit identical bytes. Internal so
/// `WireByteRegistryTests` can pin it against `PickerHelperClient.readFramed`.
enum PickerHelperFraming {
    static func writeFramedPayload(_ payload: Data, to fd: Int32) {
        var header = Data(count: 4)
        let len = UInt32(payload.count)
        header[0] = UInt8((len >> 24) & 0xFF)
        header[1] = UInt8((len >> 16) & 0xFF)
        header[2] = UInt8((len >> 8) & 0xFF)
        header[3] = UInt8(len & 0xFF)
        writeAllToFD(header, fd: fd)
        if !payload.isEmpty {
            writeAllToFD(payload, fd: fd)
        }
    }

    private static func writeAllToFD(_ data: Data, fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n <= 0 { return }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }
}

/// Free-function shim so the existing call sites in this file keep reading
/// naturally; the canonical implementation lives on `PickerHelperFraming`.
private func writeFramedPayload(_ payload: Data, to fd: Int32) {
    PickerHelperFraming.writeFramedPayload(payload, to: fd)
}
