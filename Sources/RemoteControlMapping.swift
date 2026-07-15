import CoreGraphics

/// Coordinate mapping for the remote-control injector: a normalized `[0, 1]`
/// point in the shared video frame (origin top-left, matching ``Annotation``)
/// → a global Quartz display coordinate `CGEvent` can inject at.
///
/// The `globalPoint` transform is pure (no display hardware) so it's unit
/// testable; `captureRect(for:)` is the thin side-effecting resolver that
/// looks up the live rect of whatever the sharer picked.
enum RemoteControlMapping {
    /// Map a normalized point onto `captureRect`. `captureRect` is in Quartz
    /// global coordinates (top-left origin) — the same space `CGEvent` mouse
    /// coordinates use — so no Cocoa flip is needed. The normalized inputs are
    /// clamped to `[0, 1]` so a malformed or out-of-range event can't inject
    /// outside the shared region.
    static func globalPoint(nx: Double, ny: Double, captureRect: CGRect) -> CGPoint {
        let cx = min(max(nx, 0), 1)
        let cy = min(max(ny, 0), 1)
        return CGPoint(
            x: captureRect.origin.x + cx * captureRect.width,
            y: captureRect.origin.y + cy * captureRect.height
        )
    }

    /// Live global-Quartz rect of the captured region for `selection`, or
    /// `nil` when it can't be resolved right now (e.g. a shared window that
    /// isn't on-screen — the caller drops the event). Re-resolved per event so
    /// a moved/resized window is followed automatically.
    ///
    ///   - `.display`: the whole display's `CGDisplayBounds`.
    ///   - `.window`: the window's current on-screen bounds via
    ///     `CGWindowListCopyWindowInfo` (same primitive the sharer overlay
    ///     tracks with).
    ///   - `.application`: the display the app share is hosted on — the
    ///     capture region is the full display filtered to the app's windows,
    ///     so events map onto the display rect (matches the overlay's
    ///     application-mode behavior).
    static func captureRect(for selection: PickerSelection) -> CGRect? {
        switch selection.kind {
        case .display:
            return displayBounds(selection.displayID)
        case .window:
            guard let windowID = selection.windowID else { return nil }
            return windowQuartzBounds(windowID: windowID)
        case .application:
            return displayBounds(selection.displayID)
        }
    }

    /// Quartz bounds of a display, falling back to the main display when the
    /// ID is nil or unresolved (mirrors the overlay's `NSScreen.main`
    /// fallback so the two surfaces agree on where a display-mode share lands).
    private static func displayBounds(_ displayID: UInt32?) -> CGRect {
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
}
