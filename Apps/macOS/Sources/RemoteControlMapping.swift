import AppKit
import CoreGraphics

/// Coordinate mapping for the remote-control injector: a normalized `[0, 1]`
/// point in the shared video frame (origin top-left, matching ``Annotation``)
/// → a global Quartz display coordinate `CGEvent` can inject at.
///
/// The `globalPoint` transform and the `boundingRect` union are pure (no
/// display hardware) so they're unit testable; `captureRect(for:)` takes
/// injectable resolvers whose defaults do the side-effecting lookups.
enum RemoteControlMapping {
    /// `captureRect` is in Quartz global coordinates (top-left origin, same as
    /// `CGEvent`), so no Cocoa flip is needed. Inputs clamped to `[0, 1]`.
    ///
    /// Non-finite input maps to 0 — Swift's `min`/`max` propagate NaN, so a
    /// plain clamp would produce a NaN `CGPoint`. The JSON decoder already
    /// rejects non-conforming floats, but this clamp can't depend on that.
    static func globalPoint(nx: Double, ny: Double, captureRect: CGRect) -> CGPoint {
        let fx = nx.isFinite ? nx : 0
        let fy = ny.isFinite ? ny : 0
        let cx = min(max(fx, 0), 1)
        let cy = min(max(fy, 0), 1)
        return CGPoint(
            x: captureRect.origin.x + cx * captureRect.width,
            y: captureRect.origin.y + cy * captureRect.height
        )
    }

    /// `nil` when the set is empty — the caller drops the event.
    static func boundingRect(of rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// `nil` when unresolvable (window off-screen, app share with no visible
    /// windows) — the caller drops the event. Re-resolved per event so a
    /// moved/resized window is followed.
    ///
    /// `.application` is the union of the shared app's on-screen window
    /// rects, NOT the whole display — a granted viewer must be confined to
    /// those windows, not the menu bar/Dock/other apps.
    ///
    /// Resolvers are injectable so branch selection is unit-testable without
    /// display hardware.
    static func captureRect(
        for selection: PickerSelection,
        displayBounds: (UInt32?) -> CGRect = RemoteControlMapping.defaultDisplayBounds,
        windowBounds: (UInt32) -> CGRect? = RemoteControlMapping.windowQuartzBounds,
        appWindowBounds: ([String], UInt32?) -> [CGRect] = RemoteControlMapping.defaultAppWindowBounds
    ) -> CGRect? {
        switch selection.kind {
        case .display:
            return displayBounds(selection.displayID)
        case .window:
            guard let windowID = selection.windowID else { return nil }
            return windowBounds(windowID)
        case .application:
            return boundingRect(of: appWindowBounds(selection.bundleIDs, selection.displayID))
        }
    }

    /// Falls back to the main display, mirroring the overlay's `NSScreen.main`
    /// fallback so the two surfaces agree.
    static func defaultDisplayBounds(_ displayID: UInt32?) -> CGRect {
        if let displayID {
            let bounds = CGDisplayBounds(displayID)
            if !bounds.isEmpty { return bounds }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    /// Filters the on-screen window list by `kCGWindowNumber` — the reliable
    /// path, since `kCGWindowListOptionIncludingWindow` alone returns the
    /// whole list. Thread-safe (no `NSScreen`), callable from the injector's queue.
    static func windowQuartzBounds(windowID: UInt32) -> CGRect? {
        let options: CGWindowListOption = .optionOnScreenOnly
        guard
            let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
            let info = infos.first(where: {
                ($0[kCGWindowNumber as String] as? UInt32) == windowID
            }),
            let dict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }
        return bounds
    }

    /// Empty when none are visible — the event is dropped rather than leaking
    /// onto the rest of the display. Thread-safe.
    static func defaultAppWindowBounds(_ bundleIDs: [String], _ displayID: UInt32?) -> [CGRect] {
        var pids: Set<Int> = []
        for bundleID in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                pids.insert(Int(app.processIdentifier))
            }
        }
        guard !pids.isEmpty else { return [] }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var rects: [CGRect] = []
        for info in infos {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pids.contains(pid) else { continue }
            // Normal application windows sit at layer 0; skip menu bar / Dock /
            // status items (non-zero layers) so they can't widen the region.
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard
                let dict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                bounds.width > 0, bounds.height > 0
            else { continue }
            rects.append(bounds)
        }
        return rects
    }
}
