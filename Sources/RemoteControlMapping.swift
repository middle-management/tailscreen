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
    /// Map a normalized point onto `captureRect`. `captureRect` is in Quartz
    /// global coordinates (top-left origin) — the same space `CGEvent` mouse
    /// coordinates use — so no Cocoa flip is needed. The normalized inputs are
    /// clamped to `[0, 1]` so a malformed or out-of-range event can't inject
    /// outside the shared region.
    ///
    /// Non-finite input (NaN / ±infinity) maps as 0 — Swift's `min`/`max`
    /// *propagate* NaN (they return the NaN operand when the comparison is
    /// false), so a plain clamp would produce a NaN `CGPoint`. The JSON
    /// decoder two layers away already rejects non-conforming floats (see
    /// `decodeInputEvent`), but the clamp must not depend on a decoder
    /// default it can't see. Same policy as `RemoteControlInjector`'s
    /// `clampToInt32`.
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

    /// Union of a set of window rects → the single bounding rect to clamp
    /// injection to, or `nil` when the set is empty (nothing on-screen to
    /// control → the caller drops the event). Pure.
    static func boundingRect(of rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Live global-Quartz rect of the captured region for `selection`, or
    /// `nil` when it can't be resolved right now (a shared window that isn't
    /// on-screen, or an app share with no visible windows — the caller drops
    /// the event). Re-resolved per event so a moved/resized window is followed.
    ///
    ///   - `.display`: the whole display's `CGDisplayBounds`.
    ///   - `.window`: the window's current on-screen bounds.
    ///   - `.application`: the **union of the shared app's on-screen window
    ///     rects** — NOT the whole display. A viewer granted control of an
    ///     application-only share must be confined to that app's windows, not
    ///     able to click the menu bar, Dock, or other apps.
    ///
    /// Resolvers are injectable so the display/window/app branch selection is
    /// unit-testable without display hardware.
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

    /// Quartz bounds of a display, falling back to the main display when the
    /// ID is nil or unresolved (mirrors the overlay's `NSScreen.main`
    /// fallback so the two surfaces agree on where a display-mode share lands).
    static func defaultDisplayBounds(_ displayID: UInt32?) -> CGRect {
        if let displayID {
            let bounds = CGDisplayBounds(displayID)
            if !bounds.isEmpty { return bounds }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    /// On-screen Quartz bounds (top-left origin) of the window with `windowID`,
    /// or nil if it isn't currently visible. Filters the on-screen window list
    /// by `kCGWindowNumber` — the reliable path, since
    /// `kCGWindowListOptionIncludingWindow` standalone returns the whole list.
    /// Thread-safe (no `NSScreen`), so it's callable from the injector's queue.
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

    /// On-screen Quartz bounds of every normal window owned by any of
    /// `bundleIDs`' running processes. Empty when none are visible (→ the app
    /// share has nothing to control right now, and the event is dropped rather
    /// than leaking onto the rest of the display). Thread-safe.
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
